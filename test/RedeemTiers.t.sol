// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Mode} from "./utils/V4Mode.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {MockStable, MockFeed} from "./mocks/Mocks.sol";
import {DateLib} from "../src/libraries/DateLib.sol";

/// Тесты трёхуровневого выкупа по покрытию: FULL (>=140%), STANDARD (115%..140%), SUSPENDED (<115%).
contract RedeemTiersTest is Test {
    uint256 constant T_OCT19 = 1792368000; // 2026-10-19 00:00 UTC
    uint256 constant T_OCT28 = 1793145600; // 2026-10-28 00:00 UTC
    uint256 constant T_NOV28 = 1795824000; // 2026-11-28 00:00 UTC
    uint256 constant BASKET = 1;

    address owner = makeAddr("anton");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    MockStable usdt;
    MockStable usdc;
    BasketToken coin;
    BasketVault vault;

    function setUp() public {
        vm.warp(T_OCT19);
        usdt = new MockStable("Tether USD", "USDT", 6);
        usdc = new MockStable("USD Coin", "USDC", 6);
        vault = new BasketVault(
            owner,
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
        // v5: регрессия v4 — ограничитель минта выключен через vm.store (в контракте это невозможно:
        // setMintLimits держит безопасные границы). Лимиты v5 покрыты отдельно в test/unit/MintLimits.t.sol.
        V4Mode.disableMintLimits(address(vault));
        coin = new BasketToken("BasketCoin", "BKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(BASKET, coin, 1e18);
        vm.stopPrank();

        address[4] memory users = [alice, bob, carol, owner];
        for (uint256 i; i < users.length; ++i) {
            usdt.mint(users[i], 10_000_000e6);
            usdc.mint(users[i], 10_000_000e6);
            vm.startPrank(users[i]);
            usdt.approve(address(vault), type(uint256).max);
            usdc.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers
    function _mint(address u, address stable, uint256 amount) internal returns (uint256) {
        vm.prank(u);
        return vault.mint(BASKET, stable, amount, 0);
    }

    function _cov() internal view returns (uint256) {
        return vault.collateralRatioBps(BASKET);
    }

    function _tier() internal view returns (BasketVault.RedeemTier) {
        return vault.redeemTier(BASKET);
    }

    /// Пополняет резерв USDC (owner) ровно до покрытия `target` bps (стейблы по $1).
    function _topUpTo(uint256 target) internal {
        (,, uint256 wp,,,) = vault.baskets(BASKET);
        uint256 needUsd = (target * coin.totalSupply() * wp + 1e22 - 1) / 1e22; // ceil
        uint256 cur = (vault.reserves(BASKET, address(usdt)) + vault.reserves(BASKET, address(usdc))) * 1e12;
        require(needUsd > cur, "already above");
        uint256 extra = (needUsd - cur + 1e12 - 1) / 1e12;
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdc), extra);
    }

    function _expectTier(BasketVault.RedeemTier oldT, BasketVault.RedeemTier newT) internal {
        vm.expectEmit(true, true, true, false, address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, oldT, newT, 0);
    }

    /// v0.4: индекс меняется не более чем на ±11% за одно обновление (28-го, раз в месяц).
    function _setIndexStepwise(uint256 target) internal returns (uint256 steps) {
        while (true) {
            (, uint256 idx,, uint256 lastKey,,) = vault.baskets(BASKET);
            if (idx == target && steps > 0) return steps;
            (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(vm.getBlockTimestamp());
            if (d != 28 || y * 12 + (m - 1) == lastKey) {
                vm.warp(vm.getBlockTimestamp() + 1 days);
                continue;
            }
            (uint256 lo, uint256 hi) = vault.indexBounds(BASKET);
            uint256 next = target < lo ? lo : (target > hi ? hi : target);
            vm.prank(owner);
            vault.setIndex(BASKET, next);
            ++steps;
        }
    }

    function _standardOut(uint256 tokens) internal pure returns (uint256) {
        uint256 gross = tokens / 1e12; // P = $1, стейбл 6 знаков
        return gross - (gross * 30 + 9_999) / 10_000; // комиссия округляется вверх
    }

    function _fullOut(uint256 tokens) internal pure returns (uint256) {
        uint256 gross = ((tokens * 12_000) / 10_000) / 1e12;
        return gross - (gross * 30 + 9_999) / 10_000; // комиссия округляется вверх
    }

    // -------------------------------------------------- базовое состояние
    function test_Tier_ZeroSupplyIsFull() public view {
        assertEq(coin.totalSupply(), 0);
        assertEq(_cov(), type(uint256).max);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Full));
        assertEq(uint256(vault.lastTier(BASKET)), uint256(BasketVault.RedeemTier.Full));
    }

    function test_Tier_AfterMintIsStandard() public {
        _expectTier(BasketVault.RedeemTier.Full, BasketVault.RedeemTier.Standard);
        _mint(alice, address(usdt), 1_000e6);
        assertApproxEqAbs(_cov(), 12_000, 1);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Standard));
        assertEq(uint256(vault.lastTier(BASKET)), uint256(BasketVault.RedeemTier.Standard));
    }

    // --------------------------------------------------- граница 140%
    function test_Boundary_140() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);

        _topUpTo(13_999);
        assertEq(_cov(), 13_999);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Standard));
        BasketVault.RedeemQuote memory q = vault.quoteRedeem(BASKET, address(usdt), tokens);
        assertEq(q.payoutNow, _standardOut(tokens), "13999: no buffer");

        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Full);
        _topUpTo(14_000);
        assertEq(_cov(), 14_000);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Full));

        vm.prank(alice);
        uint256 out = vault.redeem(BASKET, address(usdt), tokens, 0);
        assertEq(out, _fullOut(tokens), "14000: with buffer");
        assertGe(_cov(), 14_000, "remaining holders not diluted");
    }

    function test_Boundary_140_JustBelowRedeemsWithoutBuffer() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(13_999);
        vm.prank(alice);
        uint256 out = vault.redeem(BASKET, address(usdt), tokens, 0);
        assertEq(out, _standardOut(tokens));
    }

    // --------------------------------------------------- граница 115%
    function test_Boundary_115_AndAutoResumeByTopUp() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Suspended);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.1e18); // 120% / 1.1 ≈ 109%
        uint256 cov = _cov();
        assertLt(cov, 11_500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.RedemptionSuspended.selector, BASKET, cov, 11_500));
        vault.redeem(BASKET, address(usdt), tokens, 0);

        _topUpTo(11_499); // чуть ниже 115% — всё ещё приостановлено
        assertEq(_cov(), 11_499);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Suspended));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.RedemptionSuspended.selector, BASKET, 11_499, 11_500));
        vault.redeem(BASKET, address(usdt), tokens, 0);

        _expectTier(BasketVault.RedeemTier.Suspended, BasketVault.RedeemTier.Standard);
        _topUpTo(11_500); // ровно 115% — выкуп снова доступен (без буфера)
        assertEq(_cov(), 11_500);
        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), tokens / 2, 0);
    }

    function test_AutoResume_ByWorkingPrice() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.05e18); // ≈114.3%
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Suspended));
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(BASKET, address(usdt), tokens, 0);

        _expectTier(BasketVault.RedeemTier.Suspended, BasketVault.RedeemTier.Standard);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.0185e18); // -3% от индекса → ≈117.8%
        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), tokens, 0);
    }

    // --------------------------------------------------- переходы уровней
    function test_Transition_ByWorkingPrice() public {
        _mint(alice, address(usdt), 1_000e6);
        _topUpTo(14_200);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Full));

        _expectTier(BasketVault.RedeemTier.Full, BasketVault.RedeemTier.Standard);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.03e18); // 142% / 1.03 ≈ 137.9%

        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Full);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 0.98e18); // ≈144.9%
    }

    function test_Transition_ByIndexDrop() public {
        _mint(alice, address(usdt), 1_000e6);
        // v0.4: сразу 0,85 нельзя (−15% > 11%) — отказ с аргументами, попытка месяца не сгорает
        vm.warp(T_OCT28);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BasketVault.IndexChangeTooLarge.selector, BASKET, 1e18, 0.85e18, 0.89e18, 1.11e18)
        );
        vault.setIndex(BASKET, 0.85e18);
        vm.prank(owner);
        vault.setIndex(BASKET, 0.89e18); // тот же месяц: 120% / 0,89 ≈ 134,8% — STANDARD
        assertEq(uint256(vault.redeemTier(BASKET)), uint256(BasketVault.RedeemTier.Standard));
        vm.warp(T_NOV28);
        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Full);
        vm.prank(owner);
        vault.setIndex(BASKET, 0.85e18); // 120% / 0,85 ≈ 141,2%
        assertGe(_cov(), 14_000);
    }

    function test_Transition_StandardRedemptionsAccumulateBuffer() public {
        uint256 ta = _mint(alice, address(usdt), 1_000e6);
        uint256 tb = _mint(bob, address(usdt), 1_000e6);
        uint256 tc = _mint(carol, address(usdt), 1_000e6);

        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), ta, 0); // без буфера: покрытие растёт до ≈130%
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Standard));
        assertGt(_cov(), 12_900);

        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Full);
        vm.prank(bob);
        vault.redeem(BASKET, address(usdt), tb, 0); // → ≈160%
        assertGe(_cov(), 14_000);

        vm.prank(carol);
        uint256 out = vault.redeem(BASKET, address(usdt), tc, 0);
        assertEq(out, _fullOut(tc), "carol gets buffer");
        assertEq(coin.totalSupply(), 0);
    }

    function test_Transition_ManualStablePriceEmits() public {
        _mint(alice, address(usdt), 1_000e6);
        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Suspended);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.955e18); // не депег, но 120% * 0.955 ≈ 114.6%
    }

    function test_PokeTier_AfterFeedMove() public {
        _mint(alice, address(usdt), 1_000e6);
        MockFeed feed = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 days);
        feed.set(0.955e8, block.timestamp); // меняется без транзакции в Vault
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Suspended));
        assertEq(uint256(vault.lastTier(BASKET)), uint256(BasketVault.RedeemTier.Standard)); // ещё не синхронизирован
        _expectTier(BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Suspended);
        vm.prank(carol); // кто угодно
        vault.pokeTier(BASKET);
        assertEq(uint256(vault.lastTier(BASKET)), uint256(BasketVault.RedeemTier.Suspended));
    }

    function test_NoEventWhenTierUnchanged() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.recordLogs();
        _mint(bob, address(usdt), 1_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = BasketVault.CoverageTierChanged.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "unexpected tier event");
        }
    }

    // --------------------------------------------------- котировка (view)
    function test_Quote_StandardAndFull() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        BasketVault.RedeemQuote memory q = vault.quoteRedeem(BASKET, address(usdt), tokens);
        assertEq(uint256(q.tier), uint256(BasketVault.RedeemTier.Standard));
        assertEq(q.coverageBps, _cov());
        assertEq(q.payoutNow, _standardOut(tokens));
        assertEq(q.feeNow, ((tokens / 1e12) * 30 + 9_999) / 10_000);
        assertEq(q.payoutWithBuffer, _fullOut(tokens));
        assertEq(q.reserveAvailable, 997e6);
        assertTrue(q.executableNow);
        (uint256 so, uint256 fee) = vault.previewRedeem(BASKET, address(usdt), tokens);
        assertEq(so, q.payoutNow);
        assertEq(fee, q.feeNow);

        _topUpTo(15_000);
        q = vault.quoteRedeem(BASKET, address(usdt), tokens);
        assertEq(uint256(q.tier), uint256(BasketVault.RedeemTier.Full));
        assertEq(q.payoutNow, q.payoutWithBuffer);
        // в USDT резерв 997, а выкуп с буфером ≈994 — проходит
        assertTrue(q.executableNow);
    }

    function test_Quote_NotExecutable() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        // пауза
        vm.prank(owner);
        vault.pause();
        assertFalse(vault.quoteRedeem(BASKET, address(usdt), tokens).executableNow);
        vm.prank(owner);
        vault.unpause();
        // нет резерва в USDC
        assertFalse(vault.quoteRedeem(BASKET, address(usdc), tokens).executableNow);
        // приостановка
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.1e18);
        BasketVault.RedeemQuote memory q = vault.quoteRedeem(BASKET, address(usdt), tokens);
        assertEq(uint256(q.tier), uint256(BasketVault.RedeemTier.Suspended));
        assertEq(q.payoutNow, 0);
        assertGt(q.payoutWithBuffer, 0);
        assertFalse(q.executableNow);
    }

    function test_Quote_DepegNotExecutable() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        _mint(alice, address(usdc), 10_000e6);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.94e18);
        assertFalse(vault.quoteRedeem(BASKET, address(usdt), tokens).executableNow);
        assertTrue(vault.quoteRedeem(BASKET, address(usdc), tokens).executableNow);
    }

    // ------------------------------------------- защита от проскальзывания
    function test_Slippage_WhenTierDropsBeforeExecution() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(14_100);
        uint256 quoted = vault.quoteRedeem(BASKET, address(usdt), tokens).payoutNow; // с буфером
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.02e18); // уровень падает до STANDARD
        uint256 actual = vault.quoteRedeem(BASKET, address(usdt), tokens).payoutNow;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.Slippage.selector, actual, quoted));
        vault.redeem(BASKET, address(usdt), tokens, quoted);
    }

    // ------------------------------------------------ лимит резерва стейбла
    function test_Full_StillLimitedByStableReserve() public {
        uint256 ta = _mint(alice, address(usdt), 1_000e6);
        uint256 tb = _mint(bob, address(usdt), 1_000e6);
        _topUpTo(20_000); // пополнение в USDC ≈ 1329; в USDT 1994
        vm.prank(alice);
        uint256 outA = vault.redeem(BASKET, address(usdc), ta, 0); // FULL, из USDC
        assertEq(outA, _fullOut(ta));
        // в USDC осталось ≈332 — полный выкуп bob (≈997) в USDC не проходит
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.InsufficientReserve.selector);
        vault.redeem(BASKET, address(usdc), tb, 0);
        vm.prank(bob);
        uint256 outB = vault.redeem(BASKET, address(usdt), tb, 0); // в USDT — ок
        assertEq(outB, _fullOut(tb));
    }

    // ------------------------------------------------------------- topUp
    function test_TopUp() public {
        _mint(alice, address(usdt), 1_000e6);
        uint256 supply = coin.totalSupply();
        vm.expectEmit(true, true, true, false, address(vault)); // покрытие до/после — в Events.t.sol
        emit BasketVault.ReserveToppedUp(BASKET, carol, address(usdc), 300e6, 0, 0);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdc), 300e6);
        assertEq(coin.totalSupply(), supply, "no tokens minted");
        assertEq(vault.reserves(BASKET, address(usdc)), 300e6);

        vm.startPrank(carol);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.topUpReserve(BASKET, address(usdc), 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, address(0xbeef)));
        vault.topUpReserve(BASKET, address(0xbeef), 1e6);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 7));
        vault.topUpReserve(7, address(usdc), 1e6);
        vm.stopPrank();

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdc), 1e6); // работает и на паузе
    }

    // ---------------------------------------------------------------- fuzz
    /// Инвариант: любой разрешённый выкуп (FULL или STANDARD) не уменьшает покрытие оставшихся держателей;
    /// при SUSPENDED выкуп отклоняется.
    function testFuzz_RedeemNeverLowersCoverage(
        uint256 a,
        uint256 b,
        uint256 topUp,
        uint256 indexBps,
        uint256 driftBps,
        uint256 fracBps
    ) public {
        a = bound(a, 50e6, 1_000_000e6);
        b = bound(b, 50e6, 1_000_000e6);
        topUp = bound(topUp, 0, 2_000_000e6);
        indexBps = bound(indexBps, 7_000, 11_000);
        driftBps = bound(driftBps, 9_700, 10_300);
        fracBps = bound(fracBps, 1, 10_000);

        uint256 ta = _mint(alice, address(usdt), a);
        _mint(bob, address(usdt), b);
        if (topUp > 0) {
            vm.prank(owner);
            vault.topUpReserve(BASKET, address(usdt), topUp);
        }
        _setIndexStepwise(indexBps * 1e14); // v0.4: 0,7…1,1 — за несколько месяцев по ≤ 11%
        vm.startPrank(owner);
        vault.setWorkingPrice(BASKET, (indexBps * 1e14 * driftBps) / 10_000);
        vm.stopPrank();

        uint256 amount = (ta * fracBps) / 10_000;
        if (amount == 0) amount = 1;
        uint256 covBefore = _cov();
        BasketVault.RedeemTier tierBefore = _tier();

        vm.prank(alice);
        if (tierBefore == BasketVault.RedeemTier.Suspended) {
            vm.expectRevert();
            vault.redeem(BASKET, address(usdt), amount, 0);
            return;
        }
        try vault.redeem(BASKET, address(usdt), amount, 0) {
            assertGe(_cov(), covBefore, "coverage decreased");
            assertEq(
                usdt.balanceOf(address(vault)), vault.reserves(BASKET, address(usdt)) + vault.accruedFees(address(usdt))
            );
        } catch (bytes memory err) {
            // допустимо только округление до нуля на крошечных суммах
            assertEq(bytes4(err), BasketVault.ZeroAmount.selector);
        }
    }

    /// Минт и немедленный выкуп даже на уровне FULL не приносят прибыли (комиссии 2×0,3%).
    function testFuzz_MintThenFullRedeemNotProfitable(uint256 amount, uint256 topUp) public {
        amount = bound(amount, 50e6, 1_000_000e6);
        topUp = bound(topUp, 0, 5_000_000e6);
        _mint(alice, address(usdt), 1_000e6);
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdt), 500e6 + topUp); // покрытие ≥ 170%
        uint256 before = usdt.balanceOf(bob);
        uint256 t = _mint(bob, address(usdt), amount);
        vm.prank(bob);
        vault.redeem(BASKET, address(usdt), t, 0);
        assertLe(usdt.balanceOf(bob), before);
    }
}
