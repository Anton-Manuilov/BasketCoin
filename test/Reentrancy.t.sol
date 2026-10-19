// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {HookStable, IHookReceiver} from "./mocks/Mocks.sol";

/// Злоумышленник: при переводе hook-токена пытается повторно войти в Vault.
contract Attacker is IHookReceiver {
    enum Action {
        None,
        Mint,
        Redeem,
        TopUp,
        Poke
    }

    BasketVault public vault;
    HookStable public token;
    Action public action;
    bool public bubble; // true — пробросить revert наружу, false — поймать и записать
    bytes4 public caughtError;
    uint256 public hookCalls;
    // наблюдения read-only во время хука
    uint256 public seenReserve;
    uint256 public seenSupply;
    uint256 public seenCoverage;

    constructor(BasketVault v, HookStable t) {
        vault = v;
        token = t;
        t.approve(address(v), type(uint256).max);
    }

    function configure(Action a, bool b) external {
        action = a;
        bubble = b;
        caughtError = bytes4(0);
    }

    function doMint(uint256 amount) external returns (uint256) {
        return vault.mint(1, address(token), amount, 0);
    }

    function doRedeem(uint256 amount) external returns (uint256) {
        return vault.redeem(1, address(token), amount, 0);
    }

    function doTopUp(uint256 amount) external {
        vault.topUpReserve(1, address(token), amount);
    }

    function onTokenHook(address, address, uint256) external {
        hookCalls++;
        seenReserve = vault.reserves(1, address(token));
        (BasketVaultTokenView tkn,,,,,) = _basketToken();
        seenSupply = tkn.totalSupply();
        seenCoverage = vault.collateralRatioBps(1);
        if (action == Action.None) return;
        bytes memory data;
        if (action == Action.Mint) data = abi.encodeCall(BasketVault.mint, (1, address(token), 100e6, 0));
        if (action == Action.Redeem) data = abi.encodeCall(BasketVault.redeem, (1, address(token), 1e18, 0));
        if (action == Action.TopUp) data = abi.encodeCall(BasketVault.topUpReserve, (1, address(token), 1e6));
        if (action == Action.Poke) data = abi.encodeCall(BasketVault.pokeTier, (1));
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (ok) {
            caughtError = 0xffffffff; // повторный вход удался — тест должен упасть
            return;
        }
        if (bubble) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        caughtError = bytes4(ret);
    }

    function _basketToken() internal view returns (BasketVaultTokenView, uint256, uint256, uint256, uint64, bool) {
        (address t, uint256 a, uint256 b, uint256 c, uint64 d, bool e) = IBaskets(address(vault)).baskets(1);
        return (BasketVaultTokenView(t), a, b, c, d, e);
    }
}

interface BasketVaultTokenView {
    function totalSupply() external view returns (uint256);
}

interface IBaskets {
    function baskets(uint256) external view returns (address, uint256, uint256, uint256, uint64, bool);
}

contract ReentrancyTest is BaseTest {
    HookStable hook;
    Attacker attacker;

    function setUp() public override {
        super.setUp();
        hook = new HookStable();
        _addStableViaTimelock(address(hook)); // злонамеренный стейбл прошёл таймлок
        attacker = new Attacker(vault, hook);
        hook.mint(address(attacker), 1_000_000e6);
        hook.mint(alice, 1_000_000e6);
        vm.prank(alice);
        hook.approve(address(vault), type(uint256).max);
        vm.prank(address(attacker));
        coin.approve(address(vault), type(uint256).max);
        hook.setHooked(address(attacker), true);
    }

    bytes4 constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function _actions() internal pure returns (Attacker.Action[4] memory a) {
        a = [Attacker.Action.Mint, Attacker.Action.Redeem, Attacker.Action.TopUp, Attacker.Action.Poke];
    }

    /// Повторный вход из хука при mint (перевод attacker → vault) во все 4 функции.
    function test_Reenter_DuringMint_AllFunctionsBlocked() public {
        Attacker.Action[4] memory acts = _actions();
        for (uint256 i; i < acts.length; ++i) {
            attacker.configure(acts[i], true);
            vm.expectRevert(REENTRANT);
            attacker.doMint(1_000e6);
            attacker.configure(acts[i], false);
            attacker.doMint(1_000e6);
            assertEq(attacker.caughtError(), REENTRANT);
        }
    }

    /// Повторный вход из хука при redeem (перевод vault → attacker).
    function test_Reenter_DuringRedeem_AllFunctionsBlocked() public {
        attacker.configure(Attacker.Action.None, false);
        uint256 t = attacker.doMint(100_000e6);
        Attacker.Action[4] memory acts = _actions();
        for (uint256 i; i < acts.length; ++i) {
            attacker.configure(acts[i], true);
            vm.expectRevert(REENTRANT);
            attacker.doRedeem(t / 10);
            attacker.configure(acts[i], false);
            attacker.doRedeem(t / 10);
            assertEq(attacker.caughtError(), REENTRANT);
        }
    }

    /// Повторный вход из хука при topUp.
    function test_Reenter_DuringTopUp_AllFunctionsBlocked() public {
        Attacker.Action[4] memory acts = _actions();
        for (uint256 i; i < acts.length; ++i) {
            attacker.configure(acts[i], true);
            vm.expectRevert(REENTRANT);
            attacker.doTopUp(10e6);
            attacker.configure(acts[i], false);
            attacker.doTopUp(10e6);
            assertEq(attacker.caughtError(), REENTRANT);
        }
    }

    /// Хук у казны (получатель комиссии) тоже не может войти повторно.
    function test_Reenter_FromFeeRecipientHook() public {
        vm.prank(owner);
        vault.setFeeRecipient(address(attacker));
        attacker.configure(Attacker.Action.Mint, true);
        vm.prank(alice);
        vm.expectRevert(REENTRANT);
        vault.mint(BASKET, address(hook), 1_000e6, 0);
    }

    /// CEI в redeem: во время внешнего перевода резерв уже уменьшен, токены сожжены —
    /// view-функции видят финальное состояние (нет read-only reentrancy).
    function test_CEI_Redeem_StateFinalBeforeTransfer() public {
        attacker.configure(Attacker.Action.None, false);
        uint256 t = attacker.doMint(100_000e6);
        attacker.doRedeem(t / 2);
        assertEq(attacker.seenReserve(), vault.reserves(BASKET, address(hook)), "reserve already reduced");
        assertEq(attacker.seenSupply(), coin.totalSupply(), "tokens already burned");
        assertEq(attacker.seenCoverage(), _cov(), "coverage view consistent");
    }

    /// mint: внешний перевод внутрь делается ДО эффектов (нужен для учёта fee-on-transfer).
    /// Во время хука состояние Vault — полностью «до» минта (резерв и supply не изменены),
    /// т.е. view-функции согласованы, а повторный вход заблокирован nonReentrant.
    function test_CEI_Mint_ViewSeesPreState() public {
        attacker.configure(Attacker.Action.None, false);
        attacker.doMint(1_000e6);
        uint256 rBefore = vault.reserves(BASKET, address(hook));
        uint256 sBefore = coin.totalSupply();
        uint256 cBefore = _cov();
        attacker.doMint(1_000e6);
        assertEq(attacker.seenReserve(), rBefore);
        assertEq(attacker.seenSupply(), sBefore);
        assertEq(attacker.seenCoverage(), cBefore);
    }

    /// Регрессия F-07: pokeTier теперь под nonReentrant (раньше мог вызываться из хука).
    function test_Regression_F07_PokeTierNonReentrant() public {
        attacker.configure(Attacker.Action.Poke, false);
        attacker.doMint(1_000e6);
        assertEq(attacker.caughtError(), REENTRANT);
    }
}
