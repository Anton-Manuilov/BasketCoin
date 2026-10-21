// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockStable, MockFeed} from "../mocks/Mocks.sol";

/// Границы покрытия 115% / 140% (±1 bps, ±1 wei) и переходы уровней от каждого источника в обе стороны.
contract BoundariesTest is BaseTest {
    BasketVault.RedeemTier constant SUS = BasketVault.RedeemTier.Suspended;
    BasketVault.RedeemTier constant STD = BasketVault.RedeemTier.Standard;
    BasketVault.RedeemTier constant FULL = BasketVault.RedeemTier.Full;

    MockStable dai; // 18 знаков — для точности ±1 wei

    function setUp() public override {
        super.setUp();
        dai = new MockStable("Dai", "DAI", 18);
        _addStableViaTimelock(address(dai));
        _fund(address(dai));
    }

    function _assertTier(BasketVault.RedeemTier t) internal view {
        assertEq(uint256(_tier()), uint256(t), "tier");
        assertEq(uint256(vault.lastTier(BASKET)), uint256(t), "lastTier synced");
    }

    // ------------------------------------------------ 140%: ±1 bps и ±1 wei
    function test_140_MinusOneBps_PlusOneBps() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(13_999, address(usdc));
        assertEq(_cov(), 13_999);
        _assertTier(STD);
        _topUpTo(14_000, address(usdc));
        assertEq(_cov(), 14_000);
        _assertTier(FULL);
        _topUpTo(14_001, address(usdc));
        assertEq(_cov(), 14_001);
        _assertTier(FULL);
        assertEq(_redeem(alice, address(usdt), t), ((t * 12_000 / 10_000) / 1e12) - _ceilFee((t * 12_000 / 10_000) / 1e12));
    }

    function test_140_OneWeiBelowAndExact() public {
        _mint(alice, address(usdt), 1_000e6);
        uint256 extra = _minExtraFor(14_000, address(dai));
        _topUp(address(dai), extra - 1); // на 1 wei меньше нужного
        assertEq(_cov(), 13_999);
        _assertTier(STD);
        _expectTier(BASKET, STD, FULL);
        _topUp(address(dai), 1); // +1 wei
        assertEq(_cov(), 14_000);
        _assertTier(FULL);
    }

    // ------------------------------------------------ 115%: ±1 bps и ±1 wei
    function test_115_MinusOneBps_Exact_PlusOneBps() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        // 100%: индекс 1,2 — с v0.4 за два месяца (1 → 1,11 → 1,2), каждый шаг ≤ 11%
        assertEq(_setIndexStepwise(BASKET, 1.2e18), 2);
        assertEq(_cov(), 10_000);
        _assertTier(SUS);
        _topUpTo(11_499, address(usdc));
        assertEq(_cov(), 11_499);
        _assertTier(SUS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.RedemptionSuspended.selector, BASKET, 11_499, 11_500));
        vault.redeem(BASKET, address(usdt), t / 10, 0);

        _topUpTo(11_500, address(usdc));
        assertEq(_cov(), 11_500);
        _assertTier(STD);
        _topUpTo(11_501, address(usdc));
        assertEq(_cov(), 11_501);
        _redeem(alice, address(usdt), t / 10);
    }

    function test_115_OneWeiBelowAndExact() public {
        _mint(alice, address(usdt), 1_000e6);
        assertEq(_setIndexStepwise(BASKET, 1.2e18), 2); // 100%
        uint256 extra = _minExtraFor(11_500, address(dai));
        _topUp(address(dai), extra - 1);
        assertEq(_cov(), 11_499);
        _assertTier(SUS);
        _expectTier(BASKET, SUS, STD);
        _topUp(address(dai), 1);
        assertEq(_cov(), 11_500);
        _assertTier(STD);
    }

    // ------------------------------------------------ источник: mint
    function test_Source_Mint_FullToStandard() public {
        _mint(alice, address(usdt), 1_000e6);
        _topUpTo(15_000, address(usdc));
        _assertTier(FULL);
        _expectTier(BASKET, FULL, STD);
        _mint(bob, address(usdt), 10_000e6); // разбавляет к 120%
        _assertTier(STD);
    }

    function test_Source_Mint_SuspendedToStandard() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.05e18); // ≈114.3%
        _assertTier(SUS);
        _expectTier(BASKET, SUS, STD);
        _mint(bob, address(usdt), 1_000e6); // новые токены обеспечены 120% → среднее > 115%
        _assertTier(STD);
    }

    function test_Source_Mint_FromZeroSupply_FullToStandard() public {
        _assertTier(FULL);
        _expectTier(BASKET, FULL, STD);
        _mint(alice, address(usdt), 1_000e6);
    }

    function test_Source_Mint_CannotRaiseToFull() public {
        _mint(alice, address(usdt), 1_000e6);
        uint256 before = _cov();
        _mint(bob, address(usdt), 1_000_000e6);
        assertLe(_cov(), 12_000);
        assertGe(_cov(), before < 12_000 ? before : 12_000 - 1);
        _assertTier(STD);
    }

    // ------------------------------------------------ источник: redeem
    function test_Source_Redeem_StandardToFull() public {
        uint256 ta = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(13_000, address(usdc));
        _expectTier(BASKET, STD, FULL);
        _redeem(alice, address(usdt), ta); // уходит 100% при покрытии 130% → растёт
        _assertTier(FULL);
    }

    function test_Source_Redeem_LastHolder_ToFullZeroSupply() public {
        uint256 ta = _mint(alice, address(usdt), 1_000e6);
        _expectTier(BASKET, STD, FULL);
        _redeem(alice, address(usdt), ta);
        assertEq(coin.totalSupply(), 0);
        assertEq(_cov(), type(uint256).max);
    }

    function test_Source_Redeem_NeverLowersTier() public {
        uint256 ta = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(14_000, address(usdc));
        uint256 before = _cov();
        _redeem(alice, address(usdt), ta / 3);
        assertGe(_cov(), before);
        _assertTier(FULL);
    }

    // ------------------------------------------------ источник: topUp
    function test_Source_TopUp_SuspendedToFull_OneStep() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.1e18);
        _assertTier(SUS);
        _expectTier(BASKET, SUS, FULL);
        _topUpTo(14_000, address(usdc));
        _assertTier(FULL);
    }

    function test_Source_TopUp_StandardToFull() public {
        _mint(alice, address(usdt), 1_000e6);
        _expectTier(BASKET, STD, FULL);
        _topUpTo(14_000, address(usdc));
    }

    // ------------------------------------------------ источник: setIndex (обе стороны)
    /// С v0.4 индекс меняется не более чем на ±11% за месяц, поэтому каждый переход — отдельным шагом.
    /// Покрытие 120% при индексе 1 (12 000 bps); cov = 12 000 / индекс.
    function test_Source_SetIndex_AllDirections() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.startPrank(owner);
        vm.warp(T_OCT28);
        vault.setIndex(BASKET, 0.89e18); // −11%: 134,8% — всё ещё STANDARD
        _assertTier(STD);
        vm.warp(T_NOV28);
        _expectTier(BASKET, STD, FULL);
        vault.setIndex(BASKET, 0.85e18); // 141,2%
        vm.warp(T_DEC28_NOON);
        _expectTier(BASKET, FULL, STD);
        vault.setIndex(BASKET, 0.9435e18); // +11% ровно: 127,2%
        vm.warp(T_JAN28_2027);
        _expectTier(BASKET, STD, SUS);
        vault.setIndex(BASKET, 1.0472e18); // +10,99%: 114,6%
        vm.warp(T_FEB28_2027);
        _expectTier(BASKET, SUS, STD);
        vault.setIndex(BASKET, 1e18); // 120%
        vm.stopPrank();
        assertEq(_cov(), 12_000);
    }

    /// FULL ↔ SUSPENDED одним setIndex невозможны: 140/115 ≈ 1,217 > 1,11 и 115/140 ≈ 0,821 < 0,89.
    function test_SetIndex_CannotJumpBetweenFullAndSuspendedInOneStep() public {
        _mint(alice, address(usdt), 1_000e6);
        _topUpTo(14_000, address(usdc));
        _assertTier(FULL);
        _warpToNextIndexDay(BASKET);
        (, uint256 hi) = vault.indexBounds(BASKET);
        vm.prank(owner);
        vault.setIndex(BASKET, hi); // максимальный рост +11%
        _assertTier(STD); // 14 000 / 1,11 ≈ 12 612 — не ниже 115%
        assertGe(_cov(), 11_500);

        // SUSPENDED → максимальное падение −11% не даёт FULL
        _setIndexStepwise(BASKET, 1.3e18);
        _assertTier(SUS);
        _warpToNextIndexDay(BASKET);
        (uint256 lo,) = vault.indexBounds(BASKET);
        vm.prank(owner);
        vault.setIndex(BASKET, lo);
        assertLt(_cov(), 14_000);
    }

    // ------------------------------------------------ источник: setWorkingPrice (обе стороны)
    function test_Source_WorkingPrice_FullStandardBothWays() public {
        _mint(alice, address(usdt), 1_000e6);
        _topUpTo(14_100, address(usdc));
        _expectTier(BASKET, FULL, STD);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.01e18);
        _expectTier(BASKET, STD, FULL);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1e18);
    }

    function test_Source_WorkingPrice_StandardSuspendedBothWays() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.03e18); // 116.5%
        _assertTier(STD);
        _expectTier(BASKET, STD, SUS);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.0609e18); // +3% → 113.1%
        _expectTier(BASKET, SUS, STD);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.03e18);
    }

    // ------------------------------------------------ источник: ручная цена стейбла
    function test_Source_ManualPrice_BothWays() public {
        _mint(alice, address(usdt), 1_000e6);
        _expectTier(BASKET, STD, SUS);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.955e18); // 114.6%
        _expectTier(BASKET, SUS, STD);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 1e18);
        _topUpTo(14_200, address(usdc));
        _expectTier(BASKET, FULL, STD);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.96e18);
        _expectTier(BASKET, STD, FULL);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 1.04e18); // выше $1 — в покрытии всё равно $1
    }

    // ------------------------------------------------ источник: фид (через setStableFeed и pokeTier)
    function test_Source_Feed_BothWaysViaPoke() public {
        _mint(alice, address(usdt), 1_000e6);
        MockFeed feed = new MockFeed(8, 0.955e8);
        _expectTier(BASKET, STD, SUS);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 hours); // смена фида синхронизирует
        feed.set(1e8, block.timestamp);
        _expectTier(BASKET, SUS, STD);
        vault.pokeTier(BASKET);
        feed.set(0.955e8, block.timestamp);
        _expectTier(BASKET, STD, SUS);
        vault.pokeTier(BASKET);
        // фид устарел → ручная цена $1 → STANDARD
        vm.warp(block.timestamp + 1 hours + 1);
        _expectTier(BASKET, SUS, STD);
        vault.pokeTier(BASKET);
    }

    function test_PokeTier_NoEventWhenUnchanged_AndUnknownBasket() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.recordLogs();
        vault.pokeTier(BASKET);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 42));
        vault.pokeTier(42);
    }

    function test_TierEvent_CarriesCoverage() public {
        _mint(alice, address(usdt), 1_000e6);
        uint256 extra = _minExtraFor(14_000, address(usdc));
        vm.expectEmit(true, true, true, true, address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, FULL, 14_000);
        _topUp(address(usdc), extra);
    }
}
