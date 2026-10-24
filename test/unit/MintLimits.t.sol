// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {V4Mode} from "../utils/V4Mode.sol";
import {BasketVault} from "../../src/BasketVault.sol";

/// v5: ограничитель минта — пол покрытия 150%, сужение 160%→150%, 10%/ч и 5%/блок резерва, таймлок параметров.
contract MintLimitsTest is BaseTest {
    function _v4RegressionMode() internal pure override returns (bool) {
        return false;
    }

    // ------------------------------------------------------------ helpers
    function _covNow() internal view returns (uint256) {
        return vault.collateralRatioBps(BASKET);
    }

    function _reserveUsd() internal view returns (uint256) {
        // USDT/USDC по $1, 6 знаков -> 18
        return (vault.reserves(BASKET, address(usdt)) + vault.reserves(BASKET, address(usdc))) * 1e12;
    }

    /// Пустая корзина: пополнение и первый минт $1M так, чтобы покрытие было ~tgt.
    function _genesis(uint256 tgtBps) internal {
        uint256 x = 1_000_000e6;
        uint256 net = x - (x * 30 + 9_999) / 10_000;
        uint256 t = net * (tgtBps - 12_000) / 12_000 + 1e6;
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdt), t);
        _mint(alice, address(usdt), x);
        assertApproxEqAbs(_covNow(), tgtBps, 2);
    }

    function _schedule(uint256 f, uint256 t, uint256 h, uint256 b) internal returns (bytes memory data) {
        data = abi.encodeCall(vault.setMintLimits, (f, t, h, b));
        vm.prank(owner);
        vault.scheduleOp(data, bytes32(0));
        vm.warp(block.timestamp + vault.PARAM_DELAY());
    }

    function _setLimits(uint256 f, uint256 t, uint256 h, uint256 b) internal {
        bytes memory data = _schedule(f, t, h, b);
        vm.prank(owner);
        vault.executeOp(data, bytes32(0));
    }

    function _next() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
    }

    // ------------------------------------------------------------ параметры
    function test_Defaults() public view {
        (uint32 f, uint32 t, uint32 h, uint32 b) = vault.mintLimits();
        assertEq(f, 15_000);
        assertEq(t, 16_000);
        assertEq(h, 1_000);
        assertEq(b, 500);
        // слот, который использует V4Mode в регрессионных тестах v4
        uint256 packed = uint256(vm.load(address(vault), bytes32(V4Mode.MINT_LIMITS_SLOT)));
        assertEq(packed, 15_000 | (16_000 << 32) | (1_000 << 64) | (500 << 96));
    }

    function test_SetMintLimits_OnlyViaTimelock() public {
        vm.prank(owner);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setMintLimits(15_000, 16_000, 1_000, 500);
        assertEq(vault.opDelay(vault.setMintLimits.selector), 2 days);
    }

    function test_SetMintLimits_TimelockFlow_EmitsEvent() public {
        bytes memory data = abi.encodeCall(vault.setMintLimits, (16_000, 18_000, 2_000, 300));
        vm.prank(owner);
        vault.scheduleOp(data, bytes32(0));
        bytes32 id = vault.opId(data, bytes32(0));
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotReady.selector, id, block.timestamp + 1));
        vault.executeOp(data, bytes32(0));
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(vault));
        emit BasketVault.MintLimitsUpdated(16_000, 18_000, 2_000, 300);
        vm.prank(owner);
        vault.executeOp(data, bytes32(0));
        (uint32 f, uint32 t, uint32 h, uint32 b) = vault.mintLimits();
        assertEq(f, 16_000);
        assertEq(t, 18_000);
        assertEq(h, 2_000);
        assertEq(b, 300);
    }

    function test_SetMintLimits_NotOwnerCannotSchedule() public {
        bytes memory data = abi.encodeCall(vault.setMintLimits, (15_000, 16_000, 1_000, 500));
        vm.prank(alice);
        vm.expectRevert();
        vault.scheduleOp(data, bytes32(0));
    }

    function _expectOutOfRange(uint256 f, uint256 t, uint256 h, uint256 b) internal {
        bytes memory data = _schedule(f, t, h, b);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MintLimitsOutOfRange.selector, f, t, h, b));
        vault.executeOp(data, bytes32(0));
    }

    function test_SetMintLimits_Bounds() public {
        _expectOutOfRange(13_999, 16_000, 1_000, 500); // пол ниже 140%
        _expectOutOfRange(20_001, 20_001, 1_000, 500); // пол выше 200%
        _expectOutOfRange(15_000, 14_999, 1_000, 500); // taper < floor
        _expectOutOfRange(15_000, 18_001, 1_000, 500); // зона сужения шире 30%
        _expectOutOfRange(15_000, 16_000, 99, 50); // час < 1%
        _expectOutOfRange(15_000, 16_000, 5_001, 500); // час > 50%
        _expectOutOfRange(15_000, 16_000, 1_000, 9); // блок < 0,1%
        _expectOutOfRange(15_000, 16_000, 1_000, 1_001); // блок > часа
        _setLimits(14_000, 14_000, 100, 10); // нижние границы включительно
        _setLimits(20_000, 23_000, 5_000, 5_000); // верхние границы включительно
    }

    function testFuzz_SetMintLimits_BoundsRespected(uint256 f, uint256 t, uint256 h, uint256 b) public {
        f = bound(f, 0, 30_000);
        t = bound(t, 0, 40_000);
        h = bound(h, 0, 10_000);
        b = bound(b, 0, 10_000);
        bool ok = f >= 14_000 && f <= 20_000 && t >= f && t <= f + 3_000 && h >= 100 && h <= 5_000 && b >= 10 && b <= h;
        bytes memory data = _schedule(f, t, h, b);
        vm.prank(owner);
        if (!ok) vm.expectRevert(abi.encodeWithSelector(BasketVault.MintLimitsOutOfRange.selector, f, t, h, b));
        vault.executeOp(data, bytes32(0));
    }

    // ------------------------------------------------------------ genesis
    function test_Genesis_WithoutTopUp_RevertsFloor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MintCoverageFloor.selector, BASKET, 12_000, 15_000));
        vault.mint(BASKET, address(usdt), 1_000e6, 0);
    }

    function test_Genesis_WithTopUp_NoRateCap() public {
        // первый минт ($1M) больше любого лимита скорости, но supply == 0 — лимиты окна/блока не применяются
        _genesis(19_500);
        (uint256 w, uint256 b) = vault.mintCapacity(BASKET);
        assertApproxEqRel(w, _reserveUsd() / 10, 1e14);
        assertApproxEqRel(b, _reserveUsd() / 20, 1e14);
    }

    // ------------------------------------------------------------ блок и окно
    function test_BlockCap() public {
        _genesis(19_500);
        _next();
        uint256 r = _reserveUsd();
        uint256 chunk = r / 1e12 * 4 / 100; // 4% резерва
        _mint(bob, address(usdt), chunk);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintBlockCapExceeded.selector);
        vault.mint(BASKET, address(usdt), chunk, 0);
        _next();
        _mint(bob, address(usdt), chunk); // в следующем блоке снова можно
    }

    function test_WindowCap_ResetsNextWindow() public {
        _genesis(19_500);
        vm.warp((block.timestamp / 3600 + 1) * 3600); // начало окна
        _next();
        uint256 chunk = _reserveUsd() / 1e12 * 3 / 100; // 3% резерва (до минтов)
        _mint(bob, address(usdt), chunk);
        _next();
        _mint(bob, address(usdt), chunk);
        _next();
        _mint(bob, address(usdt), chunk); // ~8,97% нетто от исходного резерва; резерв вырос — лимит тоже
        _next();
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintWindowCapExceeded.selector);
        vault.mint(BASKET, address(usdt), chunk, 0);
        vm.warp((block.timestamp / 3600 + 1) * 3600);
        _next();
        _mint(bob, address(usdt), chunk);
    }

    function test_Capacity_MatchesActualLimit() public {
        _genesis(18_000);
        _next();
        (uint256 w, uint256 b) = vault.mintCapacity(BASKET);
        uint256 lim = w < b ? w : b;
        // нетто = gross * 0,997; максимальный gross, проходящий по лимиту блока
        uint256 grossOk = lim * 10_000 / 9_970 / 1e12 - 1;
        _mint(bob, address(usdt), grossOk);
        // лимит пересчитывается от текущего резерва: после минта остаток ~5% от нетто-взноса
        uint256 net = (grossOk - (grossOk * 30 + 9_999) / 10_000) * 1e12;
        (, uint256 b2) = vault.mintCapacity(BASKET);
        assertLe(b2, net * 5 / 100 + 1e18);
        uint256 over = b2 * 10_000 / 9_970 / 1e12 + 10;
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintBlockCapExceeded.selector);
        vault.mint(BASKET, address(usdt), over, 0);
    }

    // ------------------------------------------------------------ сужение и пол
    function test_Taper_HalfAt155() public {
        _genesis(15_500);
        (uint256 w, uint256 b) = vault.mintCapacity(BASKET);
        uint256 r = _reserveUsd();
        assertApproxEqRel(w, r * 5 / 100, 5e15); // 10% * 0,5
        assertApproxEqRel(b, r * 25 / 1000, 5e15); // 5% * 0,5
    }

    function test_Taper_ZeroAtFloor_MintBlocked_RedeemAndTopUpWork() public {
        _genesis(15_000);
        _next();
        (uint256 w,) = vault.mintCapacity(BASKET);
        assertEq(w, 0);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintWindowCapExceeded.selector);
        vault.mint(BASKET, address(usdt), 100e6, 0);
        // выкуп и пополнение лимитами не затронуты
        _redeem(alice, address(usdt), 1_000e18);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdc), 200_000e6);
        assertGt(_covNow(), 15_000);
        (w,) = vault.mintCapacity(BASKET);
        assertGt(w, 0);
        _mint(bob, address(usdt), 1_000e6);
    }

    function test_Floor_RevertsWhenNoTaper() public {
        _genesis(15_200);
        _setLimits(15_000, 15_000, 5_000, 5_000); // без сужения, крупные лимиты: остаётся только пол
        _next();
        uint256 big = _reserveUsd() / 1e12 * 10 / 100;
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintCoverageFloor.selector);
        vault.mint(BASKET, address(usdt), big, 0);
        _mint(bob, address(usdt), 1_000e6); // небольшой минт проходит
        assertGe(_covNow(), 15_000);
    }

    function test_SetIndexDoesNotTouchLimits_ButTaperReacts() public {
        _genesis(16_300);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.03e18); // покрытие падает ~3%
        assertLt(_covNow(), 16_000);
        (uint256 w,) = vault.mintCapacity(BASKET);
        assertLt(w, _reserveUsd() / 10);
    }

    // ------------------------------------------------------------ fuzz
    /// Любой успешный минт оставляет покрытие >= пола, а расход окна <= лимита по резерву до минта.
    function testFuzz_Mint_RespectsFloorAndCaps(uint256 tgt, uint256 amt, uint256 n) public {
        tgt = bound(tgt, 15_000, 25_000);
        _genesis(tgt);
        n = bound(n, 1, 8);
        vm.warp((block.timestamp / 3600 + 1) * 3600);
        uint256 r0 = _reserveUsd();
        uint256 used;
        for (uint256 i; i < n; ++i) {
            _next();
            amt = bound(uint256(keccak256(abi.encode(amt, i))), 50e6, 400_000e6);
            uint256 cb = _covNow();
            (uint256 wCap,) = vault.mintCapacity(BASKET);
            vm.prank(bob);
            try vault.mint(BASKET, address(usdt), amt, 0) {
                assertGe(_covNow(), 15_000, "floor");
                uint256 net = (amt - (amt * 30 + 9_999) / 10_000) * 1e12;
                assertLe(net, wCap, "window cap");
                used += net;
                cb;
            } catch (bytes memory err) {
                bytes4 s = bytes4(err);
                assertTrue(
                    s == BasketVault.MintWindowCapExceeded.selector || s == BasketVault.MintBlockCapExceeded.selector
                        || s == BasketVault.MintCoverageFloor.selector,
                    "unexpected revert"
                );
            }
        }
        // за одно окно — не больше 10% максимального резерва в окне
        assertLe(used, _reserveUsd() / 10 + 1e18);
        assertLe(used, r0 * 2);
    }
}
