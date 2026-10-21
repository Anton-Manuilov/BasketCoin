// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockStable, MockFeed} from "../mocks/Mocks.sol";

/// Полная проверка событий BasketVault: каждое событие — vm.expectEmit со всеми topics и data
/// (vm.expectEmit(address(vault)) проверяет все поля и эмиттера), плюс точный список событий Vault
/// в транзакции через vm.recordLogs (нет лишних событий, в т.ч. CoverageTierChanged без смены уровня).
contract EventsTest is BaseTest {
    BasketVault.RedeemTier internal constant SUS = BasketVault.RedeemTier.Suspended;
    BasketVault.RedeemTier internal constant STD = BasketVault.RedeemTier.Standard;
    BasketVault.RedeemTier internal constant FULL = BasketVault.RedeemTier.Full;
    uint256 internal constant MAX = type(uint256).max;

    bytes32 internal immutable SIG_MINTED = BasketVault.Minted.selector;
    bytes32 internal immutable SIG_REDEEMED = BasketVault.Redeemed.selector;
    bytes32 internal immutable SIG_TOPUP = BasketVault.ReserveToppedUp.selector;
    bytes32 internal immutable SIG_TIER = BasketVault.CoverageTierChanged.selector;
    bytes32 internal immutable SIG_DEPEG = BasketVault.StableDepegStatusChanged.selector;
    bytes32 internal immutable SIG_INDEX = BasketVault.IndexUpdated.selector;
    bytes32 internal immutable SIG_WP = BasketVault.WorkingPriceUpdated.selector;
    bytes32 internal immutable SIG_MANUAL = BasketVault.ManualPriceUpdated.selector;
    bytes32 internal immutable SIG_FEED = BasketVault.StableFeedUpdated.selector;
    bytes32 internal immutable SIG_ADDED = BasketVault.StableAdded.selector;
    bytes32 internal immutable SIG_PROPOSED = BasketVault.StableProposed.selector;
    bytes32 internal immutable SIG_CANCELLED = BasketVault.StableProposalCancelled.selector;
    bytes32 internal immutable SIG_MINMINT = BasketVault.MinMintUpdated.selector;
    bytes32 internal immutable SIG_FEERCPT = BasketVault.FeeRecipientUpdated.selector;
    bytes32 internal immutable SIG_BASKET = BasketVault.BasketAdded.selector;

    // ------------------------------------------------------------ helpers
    /// Сверяет точный список событий, выпущенных Vault после vm.recordLogs().
    function _assertVaultSigs(bytes32[] memory expected) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) ++n;
        }
        assertEq(n, expected.length, "number of vault events");
        uint256 j;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            assertEq(logs[i].topics[0], expected[j], "event order/signature");
            ++j;
        }
    }

    function _s(bytes32 a) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = a;
    }

    function _s(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        (r[0], r[1]) = (a, b);
    }

    function _s(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _none() internal pure returns (bytes32[] memory r) {
        r = new bytes32[](0);
    }

    /// Покрытие корзины 1 после действия (действие выполняется на снимке состояния и откатывается).
    function _covAfter(function() internal action) internal returns (uint256 c) {
        uint256 snap = vm.snapshotState();
        action();
        c = _cov();
        vm.revertToState(snap);
    }

    function _act_mintAlice1000() internal {
        _mint(alice, address(usdt), 1_000e6);
    }

    function _act_mintBob1000Usdc() internal {
        _mint(bob, address(usdc), 1_000e6);
    }

    uint256 internal pendingTokens;
    address internal pendingStable;
    uint256 internal pendingAmount;

    function _act_redeemAlice() internal {
        _redeem(alice, pendingStable, pendingTokens);
    }

    function _act_topUpCarol() internal {
        vm.prank(carol);
        vault.topUpReserve(BASKET, pendingStable, pendingAmount);
    }

    // ------------------------------------------------------------ конструктор
    function test_Ev_Constructor_AllInitialEvents() public {
        vm.recordLogs();
        vm.expectEmit(true, true, true, true);
        emit Ownable.OwnershipTransferred(address(0), owner);
        vm.expectEmit(true, true, true, true);
        emit BasketVault.FeeRecipientUpdated(address(0), treasury);
        vm.expectEmit(true, true, true, true);
        emit BasketVault.MinMintUpdated(0, 75e18);
        vm.expectEmit(true, true, true, true);
        emit BasketVault.GuardianUpdated(address(0), address(0));
        vm.expectEmit(true, true, true, true);
        emit BasketVault.SequencerUptimeFeedUpdated(address(0), address(0));
        vm.expectEmit(true, true, true, true);
        emit BasketVault.StableAdded(address(usdt), 6, address(0), 0, false);
        vm.expectEmit(true, true, true, true);
        emit BasketVault.StableAdded(address(usdc), 6, address(0), 0, false);
        BasketVault v = new BasketVault(owner, treasury, address(usdt), address(usdc), 75e18, address(0), address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v)) ++n;
        }
        assertEq(n, 7, "exactly 7 events from the new vault");
    }

    // ------------------------------------------------------------ корзина
    function test_Ev_BasketAdded_WithInitialTier_NoTierEvent() public {
        BasketToken t2 = new BasketToken("B2", "B2", owner);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.BasketAdded(2, address(t2), 2e18, FULL);
        vm.prank(owner);
        vault.addBasket(2, t2, 2e18);
        _assertVaultSigs(_s(SIG_BASKET));
    }

    // ------------------------------------------------------------ индекс и рабочая цена
    function test_Ev_IndexUpdated_OldNewYearMonthTimestamp() public {
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.02e18);
        vm.warp(T_OCT28 + 3600);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1e18, 1.05e18, 1.02e18, 2026, 10, T_OCT28 + 3600);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.05e18);
        _assertVaultSigs(_s(SIG_INDEX)); // supply = 0: уровень Full не меняется
    }

    function test_Ev_IndexUpdated_WithTierChange() public {
        _mint(alice, address(usdt), 1_000e6); // ~120% → Standard
        vm.warp(T_OCT28);
        uint256 expCov = _cov() * 1e18 / 1.06e18; // оценка, точное значение — ниже через снимок
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vault.setIndex(BASKET, 1.06e18);
        uint256 covExact = _cov();
        vm.revertToState(snap);
        assertApproxEqAbs(covExact, expCov, 1);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.IndexUpdated(BASKET, 1e18, 1.06e18, 1e18, 2026, 10, T_OCT28);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, SUS, covExact);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.06e18);
        _assertVaultSigs(_s(SIG_INDEX, SIG_TIER));
    }

    function test_Ev_WorkingPriceUpdated_OldNewIndex() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.WorkingPriceUpdated(BASKET, 1e18, 0.98e18, 1e18);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 0.98e18);
        _assertVaultSigs(_s(SIG_WP)); // 120%/0,98 ≈ 122% — уровень тот же, лишнего события нет
    }

    // ------------------------------------------------------------ пауза
    function test_Ev_PauseUnpause_StandardOZEvents() public {
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit Pausable.Paused(owner);
        vm.expectEmit(address(vault));
        emit BasketVault.PauseWindow(owner, block.timestamp + 30 days);
        vm.prank(owner);
        vault.pause();
        _assertVaultSigs(_s(Pausable.Paused.selector, BasketVault.PauseWindow.selector));
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit Pausable.Unpaused(owner);
        vm.prank(owner);
        vault.unpause();
        _assertVaultSigs(_s(Pausable.Unpaused.selector));
    }

    // ------------------------------------------------------------ таймлок стейблов
    function test_Ev_StableTimelock_ProposeReproposeCancelExecute() public {
        MockStable dai = new MockStable("Dai", "DAI", 18);
        MockFeed f = new MockFeed(8, 1e8);
        uint256 eta1 = block.timestamp + 9 days;
        vm.startPrank(owner);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableProposed(address(dai), 18, address(f), 3600, eta1, 0);
        vault.proposeStable(address(dai), IAggregatorV3(address(f)), 3600);
        _assertVaultSigs(_s(SIG_PROPOSED));

        vm.warp(block.timestamp + 1 days);
        uint256 eta2 = block.timestamp + 9 days;
        vm.expectEmit(address(vault));
        emit BasketVault.StableProposed(address(dai), 18, address(f), 7200, eta2, eta1); // перезапуск
        vault.proposeStable(address(dai), IAggregatorV3(address(f)), 7200);

        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableProposalCancelled(address(dai), eta2);
        vault.cancelStable(address(dai));
        _assertVaultSigs(_s(SIG_CANCELLED));

        uint256 eta3 = block.timestamp + 9 days;
        vault.proposeStable(address(dai), IAggregatorV3(address(f)), 3600);
        vm.warp(eta3);
        f.set(1e8, eta3);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableAdded(address(dai), 18, address(f), 3600, true);
        vault.executeStable(address(dai));
        _assertVaultSigs(_s(SIG_ADDED)); // цена $1 — события депега нет
        vm.stopPrank();
    }

    function test_Ev_ExecuteStable_DepeggedOnArrival() public {
        MockStable dai = new MockStable("Dai", "DAI", 18);
        MockFeed f = new MockFeed(8, 0.9e8);
        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(f)), 3600);
        vm.warp(block.timestamp + 9 days);
        f.set(0.9e8, block.timestamp);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableAdded(address(dai), 18, address(f), 3600, true);
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(dai), true, 0.9e18);
        vm.prank(owner);
        vault.executeStable(address(dai));
        _assertVaultSigs(_s(SIG_ADDED, SIG_DEPEG));
        assertTrue(vault.lastDepegged(address(dai)));
    }

    // ------------------------------------------------------------ параметры
    function test_Ev_MinMintUpdated_OldNew() public {
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.MinMintUpdated(50e18, 200e18);
        vm.prank(owner);
        vault.setMinMintUsd(200e18);
        _assertVaultSigs(_s(SIG_MINMINT));
    }

    function test_Ev_FeeRecipientUpdated_OldNew() public {
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.FeeRecipientUpdated(treasury, carol);
        vm.prank(address(vault));
        vault.setFeeRecipient(carol);
        _assertVaultSigs(_s(SIG_FEERCPT));
    }

    function test_Ev_Ownership_TwoStep() public {
        vm.expectEmit(address(vault));
        emit Ownable2Step.OwnershipTransferStarted(owner, bob);
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.expectEmit(address(vault));
        emit Ownable.OwnershipTransferred(owner, bob);
        vm.prank(bob);
        vault.acceptOwnership();
    }

    // ------------------------------------------------------------ минт
    function test_Ev_Minted_FirstMint_FullArgs_AndTierEvent() public {
        uint256 exp = vault.previewMint(BASKET, address(usdt), 1_000e6);
        uint256 after_ = _covAfter(_act_mintAlice1000);
        assertEq(after_, 12_000); // 997 USDT / (830,8333.. токенов × $1) = 120,00% (округление вниз)
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.Minted(BASKET, alice, address(usdt), 1_000e6, 3e6, exp, 1e18, 1e18, FULL, MAX, after_);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, FULL, STD, after_);
        _mint(alice, address(usdt), 1_000e6);
        _assertVaultSigs(_s(SIG_MINTED, SIG_TIER));
        assertEq(_cov(), after_);
    }

    function test_Ev_Minted_SecondMint_StablePriceBelowOne_NoTierEvent() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdc), 0.99e18);
        uint256 before_ = _cov();
        uint256 exp = vault.previewMint(BASKET, address(usdc), 1_000e6);
        uint256 after_ = _covAfter(_act_mintBob1000Usdc);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.Minted(BASKET, bob, address(usdc), 1_000e6, 3e6, exp, 1e18, 0.99e18, STD, before_, after_);
        _mint(bob, address(usdc), 1_000e6);
        _assertVaultSigs(_s(SIG_MINTED)); // уровень Standard не изменился — CoverageTierChanged нет
    }

    // ------------------------------------------------------------ выкуп
    function test_Ev_Redeemed_Standard_FullArgs() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        pendingTokens = t / 2;
        pendingStable = address(usdt);
        uint256 before_ = _cov();
        (uint256 out, uint256 fee) = vault.previewRedeem(BASKET, address(usdt), t / 2);
        uint256 after_ = _covAfter(_act_redeemAlice);
        assertGe(after_, before_);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.Redeemed(BASKET, alice, address(usdt), t / 2, out, fee, 1e18, 1e18, STD, before_, after_);
        _redeem(alice, address(usdt), t / 2);
        _assertVaultSigs(_s(SIG_REDEEMED));
    }

    function test_Ev_Redeemed_Full_WithBuffer_StablePriceAboveOne() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(15_000, address(usdt));
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 1.01e18); // выплата по max(p,$1) = 1,01
        assertEq(uint256(_tier()), uint256(FULL));
        pendingTokens = t;
        pendingStable = address(usdt);
        uint256 before_ = _cov();
        (uint256 out, uint256 fee) = vault.previewRedeem(BASKET, address(usdt), t);
        uint256 after_ = _covAfter(_act_redeemAlice);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.Redeemed(BASKET, alice, address(usdt), t, out, fee, 1e18, 1.01e18, FULL, before_, after_);
        _redeem(alice, address(usdt), t);
        _assertVaultSigs(_s(SIG_REDEEMED));
    }

    function test_Ev_Redeemed_RaisesTier_EmitsTierAfterRedeemed() public {
        // Пример из SPEC: три держателя, выкупы на STANDARD оставляют буфер → третий выкуп поднимает до FULL.
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        _topUpTo(13_900, address(usdt));
        pendingTokens = t;
        pendingStable = address(usdt);
        uint256 after_ = _covAfter(_act_redeemAlice);
        assertGe(after_, 14_000);
        vm.recordLogs();
        vm.expectEmit(true, true, true, false, address(vault));
        emit BasketVault.Redeemed(BASKET, alice, address(usdt), 0, 0, 0, 0, 0, STD, 0, 0);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, FULL, after_);
        _redeem(alice, address(usdt), t);
        _assertVaultSigs(_s(SIG_REDEEMED, SIG_TIER));
    }

    // ------------------------------------------------------------ пополнение
    function test_Ev_ReserveToppedUp_CoverageBeforeAfter_NoTierChange() public {
        _mint(alice, address(usdt), 1_000e6);
        pendingStable = address(usdc);
        pendingAmount = 10e6;
        uint256 before_ = _cov();
        uint256 after_ = _covAfter(_act_topUpCarol);
        assertGt(after_, before_);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.ReserveToppedUp(BASKET, carol, address(usdc), 10e6, before_, after_);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdc), 10e6);
        _assertVaultSigs(_s(SIG_TOPUP));
    }

    function test_Ev_ReserveToppedUp_WithTierChangeToFull() public {
        _mint(alice, address(usdt), 1_000e6);
        uint256 extra = _minExtraFor(14_000, address(usdc));
        pendingStable = address(usdc);
        pendingAmount = extra;
        uint256 before_ = _cov();
        uint256 after_ = _covAfter(_act_topUpCarol);
        assertEq(after_, 14_000);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.ReserveToppedUp(BASKET, carol, address(usdc), extra, before_, 14_000);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, FULL, 14_000);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdc), extra);
        _assertVaultSigs(_s(SIG_TOPUP, SIG_TIER));
    }

    // ------------------------------------------------------------ ручная цена и депег
    function test_Ev_ManualPrice_DepegEnterRepeatExit() public {
        vm.startPrank(owner);
        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.ManualPriceUpdated(address(usdt), 1e18, 0.95e18);
        vault.setManualPrice(address(usdt), 0.95e18); // граница включительно — не депег
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_MANUAL));

        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.ManualPriceUpdated(address(usdt), 0.95e18, 0.95e18 - 1);
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdt), true, 0.95e18 - 1);
        vault.setManualPrice(address(usdt), 0.95e18 - 1);
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_MANUAL, SIG_DEPEG));

        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.9e18); // всё ещё депег — повторного события нет
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_MANUAL));

        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.ManualPriceUpdated(address(usdt), 0.9e18, 1.05e18);
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdt), false, 1.05e18);
        vault.setManualPrice(address(usdt), 1.05e18);
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_MANUAL, SIG_DEPEG));

        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdt), true, 1.05e18 + 1);
        vault.setManualPrice(address(usdt), 1.05e18 + 1); // депег вверх
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_MANUAL, SIG_DEPEG));
        vm.stopPrank();
    }

    function test_Ev_ManualPrice_TierChangeCarriesCoverage() public {
        _mint(alice, address(usdt), 1_000e6);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.ManualPriceUpdated(address(usdt), 1e18, 0.95e18);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, SUS, 11_400); // 12 000 × 0,95
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.95e18);
        _assertVaultSigs(_s(SIG_MANUAL, SIG_TIER));
        assertEq(_cov(), 11_400);
    }

    // ------------------------------------------------------------ фид
    function test_Ev_StableFeedUpdated_OldNew_AndDepegOnSwitch() public {
        MockFeed f = new MockFeed(8, 1e8);
        vm.startPrank(owner);
        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.StableFeedUpdated(address(usdt), address(0), address(f), 0, 3600);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(f)), 3600);
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_FEED));

        MockFeed g = new MockFeed(18, 0.93e18);
        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.StableFeedUpdated(address(usdt), address(f), address(g), 3600, 60);
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdt), true, 0.93e18);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(g)), 60);
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_FEED, SIG_DEPEG));

        vm.recordLogs();
        vm.stopPrank();
        vm.prank(address(vault));
        vm.expectEmit(address(vault));
        emit BasketVault.StableFeedUpdated(address(usdt), address(g), address(0), 60, 0);
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdt), false, 1e18); // фид отключён → ручная $1
        vault.setStableFeed(address(usdt), IAggregatorV3(address(0)), 0);
        vm.startPrank(owner);
        _assertVaultSigs(_s(SIG_FEED, SIG_DEPEG));
        vm.stopPrank();
    }

    function test_Ev_Depeg_ViaPokeStable_AndPokeTier() public {
        MockFeed f = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdc), IAggregatorV3(address(f)), 3600);
        _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdc), 1_000e6);
        f.set(0.94e8, block.timestamp); // фид движется без транзакции в Vault

        // покрытие (997 + 997×0,94) / 1661,67 = 116,40% — уровень Standard не меняется
        assertEq(vault.collateralRatioBps(BASKET), 11_640);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdc), true, 0.94e18);
        vault.pokeStable(address(usdc)); // кто угодно
        _assertVaultSigs(_s(SIG_DEPEG)); // только депег, без CoverageTierChanged

        f.set(0.80e8, block.timestamp); // дальше вниз: 108,0% → Suspended; статус депега не меняется
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, STD, SUS, vault.collateralRatioBps(BASKET));
        vault.pokeStable(address(usdc));
        _assertVaultSigs(_s(SIG_TIER));

        vm.recordLogs();
        vault.pokeStable(address(usdc)); // повторно — ничего не изменилось
        _assertVaultSigs(_none());

        f.set(1e8, block.timestamp);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdc), false, 1e18);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, SUS, STD, 12_000);
        vault.pokeTier(BASKET);
        _assertVaultSigs(_s(SIG_DEPEG, SIG_TIER));

        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, address(0xdead)));
        vault.pokeStable(address(0xdead));
    }

    function test_Ev_Depeg_RecoveryDetectedInMint() public {
        MockFeed f = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdc), IAggregatorV3(address(f)), 3600);
        f.set(0.9e8, block.timestamp);
        vault.pokeStable(address(usdc));
        assertTrue(vault.lastDepegged(address(usdc)));
        f.set(1e8, block.timestamp); // восстановился без poke
        uint256 exp = vault.previewMint(BASKET, address(usdc), 1_000e6);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdc), false, 1e18);
        vm.expectEmit(address(vault));
        emit BasketVault.Minted(BASKET, bob, address(usdc), 1_000e6, 3e6, exp, 1e18, 1e18, FULL, MAX, 12_000);
        vm.expectEmit(address(vault));
        emit BasketVault.CoverageTierChanged(BASKET, FULL, STD, 12_000);
        _mint(bob, address(usdc), 1_000e6);
        _assertVaultSigs(_s(SIG_DEPEG, SIG_MINTED, SIG_TIER));
    }

    function test_Ev_Depeg_DetectedInTopUp() public {
        _mint(alice, address(usdt), 1_000e6);
        MockFeed f = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdc), IAggregatorV3(address(f)), 3600);
        f.set(0.9e8, block.timestamp); // topUp принимает депегнутый стейбл (по min(p,$1))
        pendingStable = address(usdc);
        pendingAmount = 100e6;
        uint256 before_ = _cov();
        uint256 after_ = _covAfter(_act_topUpCarol);
        vm.recordLogs();
        vm.expectEmit(address(vault));
        emit BasketVault.StableDepegStatusChanged(address(usdc), true, 0.9e18);
        vm.expectEmit(address(vault));
        emit BasketVault.ReserveToppedUp(BASKET, carol, address(usdc), 100e6, before_, after_);
        vm.prank(carol);
        vault.topUpReserve(BASKET, address(usdc), 100e6);
        _assertVaultSigs(_s(SIG_DEPEG, SIG_TOPUP));
    }

    // ------------------------------------------------------------ отсутствие лишних событий
    function test_Ev_NoTierEvent_WhenTierUnchanged_AllSources() public {
        _mint(alice, address(usdt), 1_000e6); // Standard
        vm.recordLogs();
        _mint(bob, address(usdt), 1_000e6);
        _assertVaultSigs(_s(SIG_MINTED));
        vm.recordLogs();
        _redeem(bob, address(usdt), 1e18);
        _assertVaultSigs(_s(SIG_REDEEMED));
        vm.recordLogs();
        _topUp(address(usdc), 1e6);
        _assertVaultSigs(_s(SIG_TOPUP));
        vm.recordLogs();
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 0.99e18);
        _assertVaultSigs(_s(SIG_WP));
        vm.recordLogs();
        vm.prank(address(vault));
        vault.setManualPrice(address(usdc), 1.01e18);
        _assertVaultSigs(_s(SIG_MANUAL));
        vm.recordLogs();
        vm.prank(address(vault));
        vault.setStableFeed(address(usdc), IAggregatorV3(address(0)), 10);
        _assertVaultSigs(_s(SIG_FEED));
        vm.warp(T_OCT28);
        vm.recordLogs();
        vm.prank(owner);
        vault.setIndex(BASKET, 1.01e18);
        _assertVaultSigs(_s(SIG_INDEX));
        vm.recordLogs();
        vault.pokeTier(BASKET);
        vault.pokeStable(address(usdt));
        _assertVaultSigs(_none());
    }

    function test_Ev_RevertedCallsEmitNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        try vault.mint(BASKET, address(usdt), 1, 0) {} catch {}
        vm.prank(owner);
        try vault.setIndex(BASKET, 1e18) {} catch {} // не 28-е
        _assertVaultSigs(_none());
    }
}
