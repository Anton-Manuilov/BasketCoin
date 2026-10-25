// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {MockStable} from "../mocks/Mocks.sol";

/// v5: handler с включённым ограничителем минта. Считает нарушения в ghost-переменных.
contract MintLimitHandler is Test {
    /// v5.2 (AA-3): тесты v4/v5 двигают рабочую цену большими шагами. Хелпер (только vm.load/vm.store — не
    /// расходует vm.prank) снимает кулдаун и, если цена в коридоре ±3% индекса, но дальше шага 0,5%, ставит
    /// рабочую цену сразу в целевую. Шаг и кулдаун проверяются отдельно в test/unit/V52.t.sol.
    function _wpu(uint256 id, uint256 price) internal returns (uint256) {
        vm.store(address(vault), keccak256(abi.encode(id, uint256(22))), bytes32(0));
        uint256 base = uint256(keccak256(abi.encode(id, uint256(3))));
        uint256 idx = uint256(vm.load(address(vault), bytes32(base + 1)));
        uint256 wp = uint256(vm.load(address(vault), bytes32(base + 2)));
        uint256 band = idx * 300 / 10_000;
        uint256 step = wp * 50 / 10_000;
        if (price >= idx - band && price <= idx + band && (price + step < wp || price > wp + step)) {
            vm.store(address(vault), bytes32(base + 2), bytes32(price));
        }
        return id;
    }

    BasketVault public vault;
    BasketToken public coin;
    MockStable public usdt;
    address public owner;
    address[3] public actors;

    uint256 public vBelowFloor; // успешный минт оставил покрытие < пола
    uint256 public vWindowOverCap; // за окно заминчено больше hourCap от максимального резерва в окне
    uint256 public vBlockOverCap;
    uint256 public vUnexpectedMintRevert;
    uint256 public mintsOk;
    uint256 public mintsLimited;
    uint256 public vMintDuringFreeze; // v5.1: успешный минт в окне заморозки перед 28-м
    uint256 public mintsFrozen;

    uint256 internal curWindow;
    uint256 internal windowUsed;
    uint256 internal windowMaxReserve;
    uint256 internal curBlock;
    uint256 internal blockUsed;
    uint256 internal blockMaxReserve;

    constructor(BasketVault v, BasketToken c, MockStable s, address o, address[3] memory a) {
        vault = v;
        coin = c;
        usdt = s;
        owner = o;
        actors = a;
    }

    function _reserve() internal view returns (uint256) {
        return vault.reserves(1, address(usdt)) * 1e12;
    }

    function mint(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        amt = bound(amt, 50e6, 300_000e6);
        uint256 r = _reserve();
        uint256 w = block.timestamp / 3600;
        if (w != curWindow) (curWindow, windowUsed, windowMaxReserve) = (w, 0, 0);
        if (block.number != curBlock) (curBlock, blockUsed, blockMaxReserve) = (block.number, 0, 0);
        if (r > windowMaxReserve) windowMaxReserve = r;
        if (r > blockMaxReserve) blockMaxReserve = r;
        bool frozen = vault.isMintFrozen(1);
        vm.prank(a);
        try vault.mint(1, address(usdt), amt, 0) {
            mintsOk++;
            if (frozen) vMintDuringFreeze++;
            if (vault.collateralRatioBps(1) < 15_000) vBelowFloor++;
            uint256 net = (amt - (amt * 30 + 9_999) / 10_000) * 1e12;
            windowUsed += net;
            blockUsed += net;
            if (windowUsed > windowMaxReserve / 10 + 1e12) vWindowOverCap++;
            if (blockUsed > blockMaxReserve / 20 + 1e12) vBlockOverCap++;
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            if (
                s == BasketVault.MintWindowCapExceeded.selector || s == BasketVault.MintBlockCapExceeded.selector
                    || s == BasketVault.MintCoverageFloor.selector
            ) mintsLimited++;
            else if (s == BasketVault.MintFrozenBeforeIndex.selector && frozen) mintsFrozen++;
            else vUnexpectedMintRevert++;
        }
    }

    function redeem(uint256 who, uint256 frac) external {
        address a = actors[who % 3];
        uint256 bal = coin.balanceOf(a);
        if (bal == 0) return;
        uint256 amt = bal * bound(frac, 1, 100) / 100;
        vm.prank(a);
        try vault.redeem(1, address(usdt), amt, 0) {} catch {}
    }

    function topUp(uint256 amt) external {
        amt = bound(amt, 1e6, 200_000e6);
        vm.prank(owner);
        vault.topUpReserve(1, address(usdt), amt);
    }

    function moveWorkingPrice(uint256 bps) external {
        bps = bound(bps, 9_700, 10_300);
        vm.prank(owner);
        try vault.setWorkingPrice(_wpu(1, 1e18 * bps / 10_000), 1e18 * bps / 10_000) {} catch {}
    }

    /// v5.1: фиксация индекса 28-го (±1%), снимает заморозку месяца
    function setIndex(uint256 bps) external {
        bps = bound(bps, 9_900, 10_100);
        (, uint256 idx,,,,) = vault.baskets(1);
        vm.prank(owner);
        try vault.setIndex(1, idx * bps / 10_000) {} catch {}
    }

    function advance(uint256 secs) external {
        secs = bound(secs, 1, 2 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1 + secs / 2);
    }
}

contract MintLimitsInvariantTest is Test {
    BasketVault vault;
    BasketToken coin;
    MockStable usdt;
    MintLimitHandler h;
    address owner = makeAddr("anton");

    function setUp() public {
        vm.warp(1792368000);
        usdt = new MockStable("Tether USD", "USDT", 6);
        MockStable usdc = new MockStable("USD Coin", "USDC", 6);
        vault = new BasketVault(
            owner,
            makeAddr("treasury"),
            address(usdt),
            address(usdc),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        coin = new BasketToken("BasketCoin", "BKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(1, coin, 1e18);
        vm.stopPrank();
        address[3] memory a = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 3; ++i) {
            usdt.mint(a[i], 1e12 * 1e6);
            vm.prank(a[i]);
            usdt.approve(address(vault), type(uint256).max);
        }
        usdt.mint(owner, 1e12 * 1e6);
        vm.startPrank(owner);
        usdt.approve(address(vault), type(uint256).max);
        vault.topUpReserve(1, address(usdt), 300_000e6);
        vault.mint(1, address(usdt), 1_000_000e6, 0); // genesis ~156%
        vm.stopPrank();
        h = new MintLimitHandler(vault, coin, usdt, owner, a);
        targetContract(address(h));
    }

    function invariant_MintNeverBelowFloor() public view {
        assertEq(h.vBelowFloor(), 0);
    }

    function invariant_WindowAndBlockCaps() public view {
        assertEq(h.vWindowOverCap(), 0);
        assertEq(h.vBlockOverCap(), 0);
    }

    function invariant_NoMintDuringFreeze() public view {
        assertEq(h.vMintDuringFreeze(), 0);
    }

    function invariant_OnlyLimitReverts() public view {
        assertEq(h.vUnexpectedMintRevert(), 0);
    }

    function invariant_SolventVsLiabilityAtP() public view {
        // резерв >= supply * P * min(cov) — мягкая проверка: покрытие не ниже 115% порога выкупа при минтах
        if (coin.totalSupply() == 0) return;
        assertGe(vault.collateralRatioBps(1), 11_500);
    }
}
