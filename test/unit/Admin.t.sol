// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockStable, MockFeed} from "../mocks/Mocks.sol";

/// Таймлок стейблов, роли и доступ ко всем функциям, события и ошибки с аргументами.
contract AdminTest is BaseTest {
    MockStable dai;

    function setUp() public override {
        super.setUp();
        dai = new MockStable("Dai", "DAI", 18);
    }

    // ------------------------------------------------ таймлок
    function test_Timelock_ProposeEmitsAndStores() public {
        MockFeed f = new MockFeed(8, 1e8);
        vm.expectEmit(address(vault));
        emit BasketVault.StableProposed(address(dai), 18, address(f), 3600, block.timestamp + 9 days, 0);
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(f)), 3600);
        (uint64 ea, IAggregatorV3 pf, uint256 st) = vault.pendingStables(address(dai));
        assertEq(ea, block.timestamp + 9 days);
        assertEq(address(pf), address(f));
        assertEq(st, 3600);
    }

    function test_Timelock_ExecuteExactBoundaryAndEvent() public {
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        uint256 ea = block.timestamp + 9 days;
        vm.warp(ea - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TimelockNotExpired.selector, ea));
        vault.executeStable(address(dai));
        vm.warp(ea);
        vm.expectEmit(address(vault));
        emit BasketVault.StableAdded(address(dai), 18, address(0), 0, true);
        vm.prank(owner);
        vault.executeStable(address(dai));
        (bool en, uint8 d,, uint256 mp,) = vault.stables(address(dai));
        assertTrue(en);
        assertEq(d, 18);
        assertEq(mp, 1e18);
        assertEq(vault.stableList(2), address(dai));
    }

    function test_Timelock_ReproposeResetsTimer() public {
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        uint256 first = block.timestamp + 9 days;
        vm.warp(block.timestamp + 5 days);
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0); // перезапуск
        uint256 second = block.timestamp + 9 days;
        vm.warp(first);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TimelockNotExpired.selector, second));
        vault.executeStable(address(dai));
        vm.warp(second);
        vm.prank(owner);
        vault.executeStable(address(dai));
    }

    function test_Timelock_DuplicateExecuteTwiceCancel() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableAlreadyEnabled.selector, address(usdt)));
        vault.proposeStable(address(usdt), IAggregatorV3(address(0)), 0);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        vm.warp(block.timestamp + 9 days);
        vault.executeStable(address(dai));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NoPendingStable.selector, address(dai)));
        vault.executeStable(address(dai)); // второй раз
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableAlreadyEnabled.selector, address(dai)));
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0); // уже включён

        MockStable x = new MockStable("X", "X", 6);
        vault.proposeStable(address(x), IAggregatorV3(address(0)), 0);
        vm.expectEmit(address(vault));
        emit BasketVault.StableProposalCancelled(address(x), block.timestamp + 9 days);
        vault.cancelStable(address(x));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NoPendingStable.selector, address(x)));
        vault.cancelStable(address(x));
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NoPendingStable.selector, address(x)));
        vault.executeStable(address(x));
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        vault.proposeStable(address(0), IAggregatorV3(address(0)), 0);
        vm.stopPrank();
    }

    function test_Timelock_OwnershipChangeDuringWait() public {
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        vm.warp(block.timestamp + 9 days);
        vm.prank(owner); // старый владелец больше не может
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.executeStable(address(dai));
        vm.prank(bob); // новый владелец исполняет заявку, сделанную до передачи
        vault.executeStable(address(dai));
    }

    function test_Regression_F08_ProposeValidatesTokenEarly() public {
        vm.startPrank(owner);
        vm.expectRevert(); // нет кода → decimals() не декодируется
        vault.proposeStable(makeAddr("not-a-token"), IAggregatorV3(address(0)), 0);
        MockStable s19 = new MockStable("S19", "S19", 19);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnsupportedDecimals.selector, 19));
        vault.proposeStable(address(s19), IAggregatorV3(address(0)), 0);
        vm.stopPrank();
    }

    // ------------------------------------------------ корзины
    function test_Regression_F01_SameTokenTwoBaskets() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TokenAlreadyRegistered.selector, address(coin)));
        vault.addBasket(2, coin, 1e18);
        vm.stopPrank();
        assertTrue(vault.tokenRegistered(address(coin)));
    }

    function test_AddBasket_ErrorsAndEvent() public {
        BasketToken t2 = new BasketToken("T2", "T2", owner);
        vm.startPrank(owner);
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        vault.addBasket(2, BasketToken(address(0)), 1e18);
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.addBasket(2, t2, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BasketExists.selector, BASKET));
        vault.addBasket(BASKET, t2, 1e18);
        vm.expectEmit(address(vault));
        emit BasketVault.BasketAdded(2, address(t2), 2e18, BasketVault.RedeemTier.Full);
        vault.addBasket(2, t2, 2e18);
        vm.stopPrank();
        assertEq(vault.basketCount(), 2);
        assertEq(vault.basketIds(1), 2);
        assertEq(uint256(vault.lastTier(2)), uint256(BasketVault.RedeemTier.Full));
    }

    function test_Regression_F05_PriceUpperBound() public {
        vm.startPrank(owner);
        BasketToken t2 = new BasketToken("T2", "T2", owner);
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.addBasket(2, t2, 1e36 + 1);
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.setManualPrice(address(usdt), 1e36 + 1);
        vm.startPrank(owner);
        vm.stopPrank();
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 1e36); // граница допустима (депег)
        vm.startPrank(owner);
        vm.warp(T_OCT28);
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.setIndex(BASKET, 1e36 + 1);
        // v0.4: индекс 1e36 достижим только как стартовый (setIndex ограничен ±11%)
        vault.addBasket(2, t2, 1e36);
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.setIndex(2, 1e36 + 1); // InvalidPrice проверяется раньше лимита
        vault.setIndex(2, 1e36);
        vm.stopPrank();
        // view-функции не паникуют на границах
        vault.quoteRedeem(2, address(usdt), type(uint128).max);
        vault.quoteRedeem(2, address(usdc), type(uint128).max);
        vault.collateralRatioBps(2);
        vault.indexBounds(2);
    }

    // ------------------------------------------------ казна
    function test_Regression_F06_FeeRecipientCannotBeVault() public {
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.InvalidFeeRecipient.selector, address(vault)));
        vault.setFeeRecipient(address(vault));
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        new BasketVault(
            owner,
            address(0),
            address(usdt),
            address(usdc),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
    }

    function test_FeeRecipient_EventAndZero() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit BasketVault.FeeRecipientUpdated(treasury, carol);
        vm.prank(address(vault));
        vault.setFeeRecipient(carol);
        assertEq(vault.feeRecipient(), carol);
        vm.prank(address(vault));
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_Constructor_ZeroAndDuplicateStables() public {
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        new BasketVault(
            owner,
            treasury,
            address(0),
            address(usdc),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableAlreadyEnabled.selector, address(usdt)));
        new BasketVault(
            owner,
            treasury,
            address(usdt),
            address(usdt),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BasketVault(
            address(0),
            treasury,
            address(usdt),
            address(usdc),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
    }

    // ------------------------------------------------ доступ: все owner-функции
    function _assertAllOwnerOnly(address caller) internal {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(err);
        vault.addBasket(7, coin, 1e18);
        vm.expectRevert(err);
        vault.setIndex(BASKET, 1e18);
        vm.expectRevert(err);
        vault.setWorkingPrice(BASKET, 1e18);
        vm.expectRevert(err);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        vm.expectRevert(err);
        vault.executeStable(address(dai));
        vm.expectRevert(err);
        vault.cancelStable(address(dai));
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setManualPrice(address(usdt), 1e18);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(0)), 0);
        vm.expectRevert(err);
        vault.setMinMintUsd(100e18);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setFeeRecipient(caller);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotOwnerOrGuardian.selector, caller));
        vault.pause();
        vm.expectRevert(err);
        vault.unpause();
        vm.expectRevert(err);
        vault.renounceOwnership();
        vm.expectRevert(err);
        vault.transferOwnership(caller);
        vm.stopPrank();
    }

    function test_Access_StrangerPendingOwnerAndOldOwner() public {
        _assertAllOwnerOnly(alice);
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.pendingOwner(), bob);
        _assertAllOwnerOnly(bob); // pending owner ещё не владелец
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();
        vm.prank(bob);
        vault.acceptOwnership();
        _assertAllOwnerOnly(owner); // бывший владелец
    }

    function test_Access_PublicFunctionsOpen() public {
        // mint/redeem/topUp/pokeTier доступны любому
        uint256 t = _mint(carol, address(usdt), 100e6);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdt), 1e6);
        vm.prank(carol);
        vault.pokeTier(BASKET);
        _redeem(carol, address(usdt), t);
    }

    function test_Renounce_Disabled() public {
        vm.prank(owner);
        vm.expectRevert(BasketVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);
    }

    function test_Token_Roles() public {
        bytes32 minter = coin.MINTER_ROLE();
        bytes32 admin = coin.DEFAULT_ADMIN_ROLE();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minter));
        coin.mint(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minter));
        coin.burn(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, admin));
        coin.grantRole(minter, alice);
        vm.stopPrank();
        // владелец токена (admin) не может минтить без роли
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, minter));
        coin.mint(owner, 1);
        assertTrue(coin.hasRole(minter, address(vault)));
        assertTrue(coin.hasRole(admin, owner));
        vm.expectRevert(bytes("admin=0"));
        new BasketToken("Z", "Z", address(0));
    }

    // ------------------------------------------------ события с аргументами
    function test_Events_ConfigWithArgs() public {
        vm.startPrank(owner);
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.ManualPriceUpdated(address(usdt), 1e18, 0.99e18);
        vault.setManualPrice(address(usdt), 0.99e18);
        vm.startPrank(owner);
        MockFeed f = new MockFeed(8, 1e8);
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.StableFeedUpdated(address(usdt), address(0), address(f), 0, 123);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(f)), 123);
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit BasketVault.MinMintUpdated(50e18, 75e18);
        vault.setMinMintUsd(75e18);
        vm.stopPrank();
    }

    // Полные проверки Minted/Redeemed/ReserveToppedUp — в test/unit/Events.t.sol.

    function test_Errors_StableNotEnabledEverywhere() public {
        address x = address(0xabc);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.mint(BASKET, x, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.redeem(BASKET, x, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.topUpReserve(BASKET, x, 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.stablePrice(x);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.isDepegged(x);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.previewMint(BASKET, x, 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.quoteRedeem(BASKET, x, 1);
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, x));
        vault.setStableFeed(x, IAggregatorV3(address(0)), 0);
    }

    function test_Errors_UnknownBasketEverywhere() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.mint(77, address(usdt), 100e6, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.redeem(77, address(usdt), 1, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.topUpReserve(77, address(usdt), 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.previewMint(77, address(usdt), 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.quoteRedeem(77, address(usdt), 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.collateralRatioBps(77);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 77));
        vault.redeemTier(77);
        vm.stopPrank();
    }

    function test_Errors_InsufficientReserveArgs() public {
        _mint(alice, address(usdt), 100e6); // резерв USDT 99,7
        uint256 t = _mint(bob, address(usdc), 10_000e6);
        (uint256 out, uint256 fee) = vault.previewRedeem(BASKET, address(usdt), t);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.InsufficientReserve.selector, out + fee, 99_700_000));
        vault.redeem(BASKET, address(usdt), t, 0);
    }
}
