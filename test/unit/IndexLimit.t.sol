// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";

/// v0.4: жёсткий лимит изменения индекса за одно обновление setIndex — ±11% (1100 bps) от предыдущего
/// зафиксированного индекса. Границы включительно, округление границ в сторону строгости:
/// min = ceil(old × 8900 / 10000), max = floor(old × 11100 / 10000).
contract IndexLimitTest is BaseTest {
    BasketVault.RedeemTier internal constant FULL = BasketVault.RedeemTier.Full;

    function _set(uint256 id, uint256 v) internal {
        vm.prank(owner);
        vault.setIndex(id, v);
    }

    function _expectLimit(uint256 id, uint256 oldIdx, uint256 newIdx, uint256 lo, uint256 hi) internal {
        vm.expectRevert(abi.encodeWithSelector(BasketVault.IndexChangeTooLarge.selector, id, oldIdx, newIdx, lo, hi));
    }

    /// Независимый эталон границ (без mulDiv).
    function _refBounds(uint256 old) internal pure returns (uint256 lo, uint256 hi) {
        lo = (old * 8_900 + 9_999) / 10_000;
        hi = (old * 11_100) / 10_000;
    }

    function _newBasket(uint256 id, uint256 initialIndex) internal {
        BasketToken t = new BasketToken("T", "T", owner);
        vm.startPrank(owner);
        t.grantRole(t.MINTER_ROLE(), address(vault));
        vault.addBasket(id, t, initialIndex);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ константа и view
    function test_Limit_ConstantAndBoundsView() public {
        assertEq(vault.MAX_INDEX_CHANGE_BPS(), 1_100);
        (uint256 lo, uint256 hi) = vault.indexBounds(BASKET);
        assertEq(lo, 0.89e18);
        assertEq(hi, 1.11e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 7));
        vault.indexBounds(7);
    }

    // ------------------------------------------------------------ успех
    function test_Limit_Plus11Exact_Succeeds() public {
        vm.warp(T_OCT28);
        vm.expectEmit(address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1e18, 1.11e18, 1e18, 2026, 10, T_OCT28);
        _set(BASKET, 1.11e18);
        assertEq(_idx(BASKET), 1.11e18);
    }

    function test_Limit_Minus11Exact_Succeeds() public {
        vm.warp(T_OCT28);
        _set(BASKET, 0.89e18);
        assertEq(_idx(BASKET), 0.89e18);
    }

    function test_Limit_InsideRange_Succeeds() public {
        vm.warp(T_OCT28);
        _set(BASKET, 1.0499e18);
        assertEq(_idx(BASKET), 1.0499e18);
        vm.warp(T_NOV28);
        _set(BASKET, 0.95e18); // −9,5% от 1,0499
        assertEq(_idx(BASKET), 0.95e18);
    }

    function test_Limit_ZeroChange_Succeeds() public {
        vm.warp(T_OCT28);
        _set(BASKET, 1e18);
        (, uint256 idx,, uint256 key,,) = vault.baskets(BASKET);
        assertEq(idx, 1e18);
        assertEq(key, 2026 * 12 + 9); // месяц израсходован
    }

    // ------------------------------------------------------------ отказ
    function test_Limit_Plus11PlusOneWei_Reverts_WithArgs() public {
        vm.warp(T_OCT28);
        _expectLimit(BASKET, 1e18, 1.11e18 + 1, 0.89e18, 1.11e18);
        _set(BASKET, 1.11e18 + 1);
        assertEq(_idx(BASKET), 1e18);
    }

    function test_Limit_Minus11MinusOneWei_Reverts_WithArgs() public {
        vm.warp(T_OCT28);
        _expectLimit(BASKET, 1e18, 0.89e18 - 1, 0.89e18, 1.11e18);
        _set(BASKET, 0.89e18 - 1);
        assertEq(_idx(BASKET), 1e18);
    }

    function test_Limit_LargeJumps_Revert_WithArgs() public {
        vm.warp(T_OCT28);
        uint256[6] memory vals = [uint256(2e18), 0.5e18, 0.85e18, 1.2e18, 1, 1e36];
        for (uint256 i; i < vals.length; ++i) {
            _expectLimit(BASKET, 1e18, vals[i], 0.89e18, 1.11e18);
            _set(BASKET, vals[i]);
        }
        assertEq(_idx(BASKET), 1e18);
        _set(BASKET, 1.11e18); // после всех отказов попытка месяца цела
    }

    // ------------------------------------------------------------ округление границ
    /// old = 1e18 + 7: old×0,89 и old×1,11 не целые → min округляется вверх, max — вниз.
    function test_Limit_BoundsRoundTowardStrictness() public {
        uint256 old = 1e18 + 7;
        _newBasket(2, old);
        (uint256 lo, uint256 hi) = vault.indexBounds(2);
        (uint256 rlo, uint256 rhi) = _refBounds(old);
        assertEq(lo, rlo);
        assertEq(hi, rhi);
        assertEq(lo, 0.89e18 + 7); // 6,23 → вверх до 7
        assertEq(hi, 1.11e18 + 7); // 7,77 → вниз до 7
        assertGe(lo * 10_000, old * 8_900, "min never below -11%");
        assertLe(hi * 10_000, old * 11_100, "max never above +11%");

        vm.warp(T_OCT28);
        _expectLimit(2, old, lo - 1, lo, hi); // точное −11% (…6,23) уже вне диапазона
        _set(2, lo - 1);
        _expectLimit(2, old, hi + 1, lo, hi); // точное +11% (…7,77) — вне диапазона
        _set(2, hi + 1);
        _set(2, hi); // граница включительно
        _newBasket(3, old);
        _set(3, lo);
        assertEq(_idx(2), hi);
        assertEq(_idx(3), lo);
    }

    // ------------------------------------------------------------ последовательные месяцы
    function test_Limit_SequentialMonths_EachFromNewValue() public {
        vm.warp(T_OCT28);
        _set(BASKET, 1.11e18);
        vm.warp(T_NOV28);
        // лимит теперь от 1,11: max = 1,2321, min = 0,9879
        (uint256 lo, uint256 hi) = vault.indexBounds(BASKET);
        assertEq(lo, 0.9879e18);
        assertEq(hi, 1.2321e18);
        _expectLimit(BASKET, 1.11e18, 1.2321e18 + 1, 0.9879e18, 1.2321e18);
        _set(BASKET, 1.2321e18 + 1);
        _set(BASKET, 1.2321e18); // +23,21% к исходному 1,0 за два месяца
        vm.warp(T_DEC28_NOON);
        _expectLimit(BASKET, 1.2321e18, 1.096569e18 - 1, 1.096569e18, 1.367631e18);
        _set(BASKET, 1.096569e18 - 1);
        _set(BASKET, 1.096569e18); // −11% от 1,2321
        vm.warp(T_JAN28_2027); // смена года — лимит от последнего значения
        (lo, hi) = vault.indexBounds(BASKET);
        (uint256 rlo, uint256 rhi) = _refBounds(1.096569e18);
        assertEq(lo, rlo);
        assertEq(hi, rhi);
        _set(BASKET, hi);
        assertEq(_idx(BASKET), rhi);
    }

    // ------------------------------------------------------------ revert не сжигает попытку
    function test_Limit_RejectionDoesNotBurnMonthAttempt() public {
        vm.warp(T_OCT28);
        _expectLimit(BASKET, 1e18, 1.5e18, 0.89e18, 1.11e18);
        _set(BASKET, 1.5e18);
        (,,, uint256 key,,) = vault.baskets(BASKET);
        assertEq(key, type(uint256).max, "month key untouched");
        vm.warp(T_OCT28_END); // тот же день, позже
        _set(BASKET, 1.1e18);
        assertEq(_idx(BASKET), 1.1e18);
        vm.expectRevert(BasketVault.IndexAlreadyUpdatedThisMonth.selector);
        _set(BASKET, 1.1e18); // успешное обновление уже израсходовало месяц
    }

    // ------------------------------------------------------------ стартовый индекс не ограничен
    function test_Limit_InitialIndexUnlimited() public {
        _newBasket(2, 5e18);
        _newBasket(3, 1);
        _newBasket(4, 1e36);
        assertEq(_idx(2), 5e18);
        assertEq(_idx(3), 1);
        assertEq(_idx(4), 1e36);
        // а первый setIndex новой корзины уже ограничен — от стартового индекса
        vm.warp(T_OCT28);
        _expectLimit(2, 5e18, 1e18, 4.45e18, 5.55e18);
        _set(2, 1e18);
        _set(2, 5.55e18);
        // индекс 1 wei: min = ceil(0,89) = 1, max = floor(1,11) = 1 — только 0%
        _expectLimit(3, 1, 2, 1, 1);
        _set(3, 2);
        _set(3, 1);
    }

    // ------------------------------------------------------------ рабочая цена ±3% от нового индекса
    function test_Limit_WorkingPriceBandFromNewIndex() public {
        vm.warp(T_OCT28);
        _set(BASKET, 1.11e18);
        assertEq(_wp(BASKET), 1.11e18);
        vm.startPrank(owner);
        vault.setWorkingPrice(BASKET, 1.1433e18); // +3%
        vault.setWorkingPrice(BASKET, 1.0767e18); // −3%
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 1.1433e18 + 1, 1.11e18));
        vault.setWorkingPrice(BASKET, 1.1433e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 1.03e18, 1.11e18));
        vault.setWorkingPrice(BASKET, 1.03e18); // старая полоса не действует
        vm.stopPrank();
        // лимит индекса считается от индекса, а не от рабочей цены
        vm.warp(T_NOV28);
        (uint256 lo, uint256 hi) = vault.indexBounds(BASKET);
        assertEq(lo, 0.9879e18);
        assertEq(hi, 1.2321e18);
    }

    // ------------------------------------------------------------ fuzz
    /// setIndex проходит тогда и только тогда, когда 0,89·old <= new <= 1,11·old (точно);
    /// при отказе — IndexChangeTooLarge с независимо посчитанными границами.
    function testFuzz_Limit_SucceedsIffWithinBounds(uint256 old, uint256 newIdx, uint8 mode, uint256 delta) public {
        old = bound(old, 1, 1e36);
        _newBasket(2, old);
        (uint256 rlo, uint256 rhi) = _refBounds(old);
        delta = bound(delta, 0, 3);
        if (mode % 4 == 0) {
            newIdx = bound(newIdx, 1, 1e36); // произвольный
        } else if (mode % 4 == 1) {
            newIdx = (delta % 2 == 0) ? rlo + delta : (rlo > delta ? rlo - delta : rlo); // около min
        } else if (mode % 4 == 2) {
            newIdx = (delta % 2 == 0) ? rhi + delta : (rhi > delta ? rhi - delta : rhi); // около max
        } else {
            newIdx = bound(newIdx, rlo, rhi); // внутри
        }
        if (newIdx == 0 || newIdx > 1e36) return; // InvalidPrice — отдельный тест
        bool within = newIdx * 10_000 >= old * 8_900 && newIdx * 10_000 <= old * 11_100;
        vm.warp(T_OCT28);
        vm.prank(owner);
        try vault.setIndex(2, newIdx) {
            assertTrue(within, "accepted outside +-11%");
            assertEq(_idx(2), newIdx);
        } catch (bytes memory err) {
            assertFalse(within, "rejected inside +-11%");
            assertEq(
                err,
                abi.encodeWithSelector(BasketVault.IndexChangeTooLarge.selector, 2, old, newIdx, rlo, rhi),
                "error args"
            );
            assertEq(_idx(2), old);
            // попытка месяца не сгорела
            _set(2, old);
        }
    }
}
