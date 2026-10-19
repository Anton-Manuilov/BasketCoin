// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockFeed, ShortReturnFeed, ReturnBombFeed, GasGuzzlerFeed} from "../mocks/Mocks.sol";

/// Цены стейблов (фид/ручная), депег, правило 28-го числа, рабочая цена ±3%.
contract OracleTest is BaseTest {
    MockFeed feed;

    function _useFeed(uint8 dec, int256 answer) internal {
        feed = new MockFeed(dec, answer);
        vm.prank(owner);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 days);
    }

    // ------------------------------------------------ депег на границах с decimals фида 6/8/18
    function _checkDepegBounds(uint8 dec) internal {
        int256 one = int256(10 ** dec);
        _useFeed(dec, (one * 95) / 100); // ровно 0,95
        assertEq(vault.stablePrice(address(usdt)), 0.95e18);
        assertFalse(vault.isDepegged(address(usdt)));
        _mint(alice, address(usdt), 100e6);

        feed.set((one * 95) / 100 - 1, block.timestamp); // на 1 единицу фида ниже
        assertTrue(vault.isDepegged(address(usdt)));
        uint256 p = vault.stablePrice(address(usdt));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableDepegged.selector, address(usdt), p));
        vault.mint(BASKET, address(usdt), 100e6, 0);

        feed.set((one * 105) / 100, block.timestamp); // ровно 1,05
        assertFalse(vault.isDepegged(address(usdt)));
        feed.set((one * 105) / 100 + 1, block.timestamp); // чуть выше
        assertTrue(vault.isDepegged(address(usdt)));
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(BASKET, address(usdt), 1e18, 0);
        // USDC не затронут
        _mint(alice, address(usdc), 100e6);
    }

    function test_DepegBounds_FeedDecimals6() public {
        _checkDepegBounds(6);
    }

    function test_DepegBounds_FeedDecimals8() public {
        _checkDepegBounds(8);
    }

    function test_DepegBounds_FeedDecimals18() public {
        _checkDepegBounds(18);
    }

    function test_DepegBounds_Manual_OneWei() public {
        vm.startPrank(owner);
        vault.setManualPrice(address(usdt), 0.95e18);
        assertFalse(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 0.95e18 - 1);
        assertTrue(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 1.05e18);
        assertFalse(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 1.05e18 + 1);
        assertTrue(vault.isDepegged(address(usdt)));
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.setManualPrice(address(usdt), 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, address(0x99)));
        vault.setManualPrice(address(0x99), 1e18);
        vm.stopPrank();
    }

    // ------------------------------------------------ устаревший / неполный / невалидный раунд
    function test_Feed_StalenessBoundary() public {
        _useFeed(8, 0.97e8);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days); // ровно maxStaleness — ещё свежий
        assertEq(vault.stablePrice(address(usdt)), 0.97e18);
        vm.warp(t0 + 1 days + 1); // на 1 с старше — fallback на ручную цену
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Feed_ZeroStalenessOnlySameBlock() public {
        feed = new MockFeed(8, 0.97e8);
        vm.prank(owner);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 0);
        assertEq(vault.stablePrice(address(usdt)), 0.97e18);
        vm.warp(block.timestamp + 1);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Feed_IncompleteRound_Fallback() public {
        _useFeed(8, 0.97e8);
        feed.setRounds(5, 4); // answeredInRound < roundId
        assertEq(vault.stablePrice(address(usdt)), 1e18);
        feed.setRounds(5, 5);
        assertEq(vault.stablePrice(address(usdt)), 0.97e18);
    }

    function test_Feed_UpdatedAtZeroOrFuture_Fallback() public {
        _useFeed(8, 0.97e8);
        feed.set(0.97e8, 0);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
        feed.set(0.97e8, block.timestamp + 1);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Feed_NonPositiveAnswer_Fallback() public {
        _useFeed(8, 0);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
        feed.set(-5e7, block.timestamp);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Feed_DecimalsAbove18_Fallback() public {
        _useFeed(19, 1e19);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Feed_Broken_FallbackAndManualDepegStillWorks() public {
        _useFeed(8, 1e8);
        feed.setBroken(true);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
        vm.prank(owner);
        vault.setManualPrice(address(usdt), 0.9e18); // ручной депег действует при упавшем фиде
        assertTrue(vault.isDepegged(address(usdt)));
    }

    function test_Feed_Disable() public {
        _useFeed(8, 0.97e8);
        vm.prank(owner);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(0)), 0);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    // ------------------------------------------------ правило 28-го числа
    function test_SetIndex_DayBoundaries() public {
        vm.startPrank(owner);
        vm.warp(T_OCT27_END);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotIndexDay.selector, 27));
        vault.setIndex(BASKET, 1.01e18);
        vm.warp(T_OCT28_END); // 23:59:59 28-го — ещё можно
        vm.expectEmit(true, false, false, true, address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1e18, 1.01e18, 1e18, 2026, 10, T_OCT28_END);
        vault.setIndex(BASKET, 1.01e18);
        vm.warp(T_OCT29);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotIndexDay.selector, 29));
        vault.setIndex(BASKET, 1.02e18);
        vm.stopPrank();
    }

    function test_SetIndex_TwicePerMonthAndSameDay() public {
        vm.startPrank(owner);
        vm.warp(T_OCT28);
        vault.setIndex(BASKET, 1.01e18);
        vm.expectRevert(BasketVault.IndexAlreadyUpdatedThisMonth.selector);
        vault.setIndex(BASKET, 1.02e18);
        vm.warp(T_OCT28_END);
        vm.expectRevert(BasketVault.IndexAlreadyUpdatedThisMonth.selector);
        vault.setIndex(BASKET, 1.02e18);
        vm.stopPrank();
    }

    function test_SetIndex_YearChange_February_LeapYear_SkippedMonth() public {
        vm.startPrank(owner);
        vm.warp(T_DEC28_NOON);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1e18, 1.01e18, 1e18, 2026, 12, T_DEC28_NOON);
        vault.setIndex(BASKET, 1.01e18);
        vm.warp(T_JAN28_2027); // смена года
        vm.expectEmit(true, false, false, true, address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1.01e18, 1.02e18, 1.01e18, 2027, 1, T_JAN28_2027);
        vault.setIndex(BASKET, 1.02e18);
        vm.warp(T_FEB28_2027); // февраль невисокосного года
        vault.setIndex(BASKET, 1.03e18);
        vm.warp(T_FEB28_2028); // високосный: 28-е можно
        vault.setIndex(BASKET, 1.04e18);
        vm.warp(T_FEB29_2028); // 29 февраля — нельзя
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotIndexDay.selector, 29));
        vault.setIndex(BASKET, 1.05e18);
        vm.warp(T_MAR28_2028);
        vault.setIndex(BASKET, 1.05e18);
        vm.stopPrank();
        assertEq(_idx(BASKET), 1.05e18);
    }

    function test_SetIndex_SameMonthNextYearAllowed() public {
        vm.startPrank(owner);
        vm.warp(T_OCT28);
        vault.setIndex(BASKET, 1.01e18);
        vm.warp(T_OCT28 + 365 days); // 2027-10-28
        vault.setIndex(BASKET, 1.02e18);
        vm.stopPrank();
    }

    function test_SetIndex_ZeroAndUnknownBasket() public {
        vm.warp(T_OCT28);
        vm.startPrank(owner);
        vm.expectRevert(BasketVault.InvalidPrice.selector);
        vault.setIndex(BASKET, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 5));
        vault.setIndex(5, 1e18);
        vm.stopPrank();
    }

    function test_SetIndex_StoresTimestampAndResetsWorkingPrice() public {
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.02e18);
        vm.warp(T_OCT28 + 5);
        vm.prank(owner);
        vault.setIndex(BASKET, 2e18);
        (, uint256 idx, uint256 wp, uint256 key, uint64 ts,) = vault.baskets(BASKET);
        assertEq(idx, 2e18);
        assertEq(wp, 2e18);
        assertEq(key, 2026 * 12 + 9);
        assertEq(ts, T_OCT28 + 5);
    }

    // ------------------------------------------------ рабочая цена ±3%
    function test_WorkingPrice_ExactBandAndOneWeiOutside() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BasketVault.WorkingPriceUpdated(BASKET, 1e18, 1.03e18, 1e18);
        vault.setWorkingPrice(BASKET, 1.03e18);
        vault.setWorkingPrice(BASKET, 0.97e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 1.03e18 + 1, 1e18));
        vault.setWorkingPrice(BASKET, 1.03e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 0.97e18 - 1, 1e18));
        vault.setWorkingPrice(BASKET, 0.97e18 - 1);
        vm.stopPrank();
    }

    function test_WorkingPrice_BandAfterNewIndex_NonRoundIndex() public {
        vm.warp(T_OCT28);
        uint256 idx = 1.234567890123456789e18;
        vm.startPrank(owner);
        vault.setIndex(BASKET, idx);
        uint256 band = (idx * 300) / 10_000; // округление вниз → полоса не шире 3%
        vault.setWorkingPrice(BASKET, idx + band);
        vault.setWorkingPrice(BASKET, idx - band);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, idx + band + 1, idx));
        vault.setWorkingPrice(BASKET, idx + band + 1);
        // старая полоса (от 1e18) больше не действует
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 1e18, idx));
        vault.setWorkingPrice(BASKET, 1e18);
        vm.stopPrank();
    }

    function test_WorkingPrice_UnknownBasket() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 3));
        vault.setWorkingPrice(3, 1e18);
    }
}

/// Регрессии F-02/F-03: невалидные/враждебные фиды не должны ломать Vault (DoS).
contract FeedDoSRegressionTest is BaseTest {
    function _setFeed(address f) internal {
        vm.prank(owner);
        vault.setStableFeed(address(usdt), IAggregatorV3(f), 1 days);
    }

    function _assertVaultAlive() internal {
        assertEq(vault.stablePrice(address(usdt)), 1e18, "fallback to manual");
        uint256 t = _mint(alice, address(usdt), 100e6);
        _mint(bob, address(usdc), 100e6);
        _redeem(alice, address(usdc), t);
        vault.collateralRatioBps(BASKET);
    }

    function test_Regression_F02_EOAFeed() public {
        _setFeed(makeAddr("eoa-feed")); // нет кода: ответ пустой
        _assertVaultAlive();
    }

    function test_Regression_F02_ShortReturnFeed() public {
        _setFeed(address(new ShortReturnFeed()));
        _assertVaultAlive();
    }

    function test_Regression_F02_ReturnBombFeed() public {
        _setFeed(address(new ReturnBombFeed()));
        uint256 g = gasleft();
        vault.stablePrice(address(usdt));
        assertLt(g - gasleft(), 250_000, "return data is not copied");
        _assertVaultAlive();
    }

    function test_Regression_F02_GasGuzzlerFeed() public {
        _setFeed(address(new GasGuzzlerFeed()));
        uint256 g = gasleft();
        vault.stablePrice(address(usdt));
        assertLt(g - gasleft(), 250_000, "gas capped by FEED_GAS_LIMIT");
        _assertVaultAlive();
    }

    function test_Regression_F02_HugeAnswerNoOverflow() public {
        MockFeed f = new MockFeed(0, type(int256).max);
        _setFeed(address(f));
        _assertVaultAlive();
        f.set(int256(uint256(type(uint128).max)), block.timestamp); // ровно MAX_FEED_ANSWER — валиден (депег)
        assertTrue(vault.isDepegged(address(usdt)));
    }

    function test_Regression_F03_IncompleteRound() public {
        MockFeed f = new MockFeed(8, 0.5e8);
        f.setRounds(10, 9);
        _setFeed(address(f));
        assertFalse(vault.isDepegged(address(usdt)), "stale/incomplete answer ignored");
    }
}
