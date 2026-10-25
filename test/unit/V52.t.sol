// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockFeed} from "../mocks/Mocks.sol";

/// Настраиваемый фид секвенсора.
contract SeqFeed {
    int256 public answer;
    uint256 public startedAt;
    bool public broken;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// v5.2: исправления по автоматическому ИИ-скану Nethermind AuditAgent (AA-1 … AA-7).
contract V52Test is BaseTest {
    bytes32 internal constant SALT = bytes32(uint256(52));
    address internal guard = makeAddr("guardian");

    function _v4RegressionMode() internal pure override returns (bool) {
        return false;
    }

    function _next() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
    }

    function _reserveUsd() internal view returns (uint256) {
        return (vault.reserves(BASKET, address(usdt)) + vault.reserves(BASKET, address(usdc))) * 1e12;
    }

    function _genesis() internal {
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdt), 622_000e6);
        _mint(alice, address(usdt), 1_000_000e6);
    }

    function _timelocked(bytes memory data) internal {
        vm.prank(owner);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + vault.opDelay(bytes4(data)));
        vm.prank(owner);
        vault.executeOp(data, SALT);
    }

    function _setGuardian() internal {
        _timelocked(abi.encodeCall(vault.setGuardian, (guard)));
    }

    // ------------------------------------------------------------ AA-1: аварийная заморозка стейбла
    function test_AA1_GuardianFreezesStableMint_Instantly() public {
        _genesis();
        _setGuardian();
        vm.prank(guard);
        vault.freezeStableMint(address(usdt));
        assertTrue(vault.stableMintFrozen(address(usdt)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableMintIsFrozen.selector, address(usdt)));
        vault.mint(BASKET, address(usdt), 1_000e6, 0);
        // другой стейбл и выкуп работают
        _next();
        _mint(bob, address(usdc), 1_000e6);
        _redeem(alice, address(usdt), 100e18);
    }

    function test_AA1_OnlyOwnerOrGuardian_UnfreezeOnlyViaTimelock() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotOwnerOrGuardian.selector, bob));
        vault.freezeStableMint(address(usdt));
        vm.prank(owner);
        vault.freezeStableMint(address(usdt));
        vm.prank(owner);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.unfreezeStableMint(address(usdt));
        assertEq(vault.opDelay(vault.unfreezeStableMint.selector), 2 days);
        _timelocked(abi.encodeCall(vault.unfreezeStableMint, (address(usdt))));
        assertFalse(vault.stableMintFrozen(address(usdt)));
    }

    /// Сценарий отчёта: USDT теряет привязку, ручная цена $1. После заморозки цикл «минт дешёвым USDT →
    /// выкуп в USDC» невозможен.
    function test_AA1_DepegArbitrageBlocked() public {
        _genesis();
        vm.prank(owner);
        vault.freezeStableMint(address(usdt));
        _next();
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.StableMintIsFrozen.selector);
        vault.mint(BASKET, address(usdt), 10_000e6, 0);
        vm.expectPartialRevert(BasketVault.StableMintIsFrozen.selector);
        vault.previewMint(BASKET, address(usdt), 10_000e6);
    }

    // ------------------------------------------------------------ AA-2: окно заморозки при f > 1 дня
    function test_AA2_FreezeTwoDays_CoversWholeIntervalBefore28th() public {
        _timelocked(abi.encodeCall(vault.setMintFreeze, (2 days)));
        vm.warp(T_OCT28 - 2 days - 1);
        assertFalse(vault.isMintFrozen(BASKET));
        for (uint256 t = T_OCT28 - 2 days; t <= T_OCT28_END; t += 15 minutes) {
            vm.warp(t);
            assertTrue(vault.isMintFrozen(BASKET), "gap in freeze");
        }
        vm.warp(T_OCT28 - 1 days + 1); // весь 27-е — заморожено (в v5.1 было открыто)
        assertTrue(vault.isMintFrozen(BASKET));
        vm.warp(T_OCT28_END + 1);
        assertFalse(vault.isMintFrozen(BASKET));
    }

    function testFuzz_AA2_FreezeContiguous(uint256 f, uint256 before) public {
        f = bound(f, 1, 2 days);
        _timelocked(abi.encodeCall(vault.setMintFreeze, (f)));
        before = bound(before, 0, 3 days);
        vm.warp(T_OCT28 - before);
        assertEq(vault.isMintFrozen(BASKET), before <= f);
    }

    function test_AA2_MaxFreezeBound() public {
        bytes memory data = abi.encodeCall(vault.setMintFreeze, (2 days + 1));
        vm.prank(owner);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MintFreezeOutOfRange.selector, 2 days + 1));
        vault.executeOp(data, SALT);
    }

    // ------------------------------------------------------------ AA-4: скользящий час без затухания
    /// Сценарий отчёта: минты в конце часа H и в конце часа H+1 (< 1 ч между ними) не превышают лимит.
    function test_AA4_ReportScenario_TrailingHourNeverExceedsCap() public {
        _genesis();
        uint256 h = (block.timestamp / 3600 + 1) * 3600;
        uint256 cap = _reserveUsd() / 10;
        uint256 chunk = cap / 2 / 1e12 * 99 / 100; // ~ половина лимита (с учётом комиссии)
        vm.warp(h - 24);
        vm.roll(block.number + 1);
        _mint(bob, address(usdt), chunk);
        vm.warp(h - 12);
        vm.roll(block.number + 1);
        _mint(bob, address(usdt), chunk);
        vm.warp(2 * 3600 + h - 3600 - 48); // H+1 − 48 c: прошлые минты моложе часа
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintWindowCapExceeded.selector);
        vault.mint(BASKET, address(usdt), chunk, 0);
        (uint256 w,) = vault.mintCapacity(BASKET);
        assertLt(w, chunk * 1e12 / 2);
        // через час после последнего минта (+ до 10 мин на корзину) — снова доступен
        vm.warp(h - 12 + 1 hours + 10 minutes);
        vm.roll(block.number + 1);
        _mint(bob, address(usdt), chunk);
    }

    /// Фазз: сумма минтов в любом окне 3600 с не превышает лимита на момент последнего минта окна.
    function testFuzz_AA4_RollingHour(uint256 seed) public {
        _genesis();
        uint256 n = 12;
        uint256[] memory ts = new uint256[](n);
        uint256[] memory usd = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + seed % 900);
            vm.roll(block.number + 1);
            uint256 amt = 50e6 + (seed >> 32) % 60_000e6;
            vm.prank(bob);
            try vault.mint(BASKET, address(usdt), amt, 0) {
                ts[k] = block.timestamp;
                usd[k] = (amt - (amt * 30 + 9_999) / 10_000) * 1e12;
                ++k;
            } catch {}
        }
        uint256 capMax = _reserveUsd() / 10; // резерв только растёт → лимит любого прошлого момента <= этого
        for (uint256 i; i < k; ++i) {
            uint256 sum;
            for (uint256 j = i; j < k && ts[j] < ts[i] + 3600; ++j) {
                sum += usd[j];
            }
            assertLe(sum, capMax + 1e18);
        }
    }

    // ------------------------------------------------------------ AA-5: фид секвенсора
    function test_AA5_SetterRejectsSemanticallyBadFeed() public {
        SeqFeed f = new SeqFeed();
        f.set(0, 0); // startedAt == 0
        bytes memory data = abi.encodeCall(vault.setSequencerUptimeFeed, (address(f)));
        vm.prank(owner);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        vault.executeOp(data, SALT);
        f.set(2, block.timestamp - 10); // неожиданный статус
        vm.prank(owner);
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        vault.executeOp(data, SALT);
        f.set(0, block.timestamp - 2 hours);
        vm.prank(owner);
        vault.executeOp(data, SALT);
        assertEq(vault.sequencerUptimeFeed(), address(f));
    }

    function test_AA5_ConstructorValidatesFeed() public {
        SeqFeed f = new SeqFeed();
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18, address(0), address(f));
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18, address(0), makeAddr("eoa"));
        f.set(0, block.timestamp - 2 hours);
        new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18, address(0), address(f));
    }

    function test_AA5_GuardianDisablesOnlyBrokenFeed() public {
        _genesis();
        _setGuardian();
        SeqFeed f = new SeqFeed();
        f.set(0, block.timestamp - 2 hours);
        _timelocked(abi.encodeCall(vault.setSequencerUptimeFeed, (address(f))));
        // исправный фид (даже «упал» / grace) отключить нельзя
        vm.prank(guard);
        vm.expectRevert(BasketVault.SequencerFeedHealthy.selector);
        vault.disableBrokenSequencerFeed();
        f.set(1, block.timestamp - 2 hours);
        vm.prank(guard);
        vm.expectRevert(BasketVault.SequencerFeedHealthy.selector);
        vault.disableBrokenSequencerFeed();
        // фид сломался → mint/redeem стоят → guardian отключает сразу
        f.setBroken(true);
        vm.prank(alice);
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        vault.redeem(BASKET, address(usdt), 100e18, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotOwnerOrGuardian.selector, bob));
        vault.disableBrokenSequencerFeed();
        vm.prank(guard);
        vault.disableBrokenSequencerFeed();
        assertEq(vault.sequencerUptimeFeed(), address(0));
        _redeem(alice, address(usdt), 100e18);
    }

    // ------------------------------------------------------------ AA-6: превью = реальные проверки
    function test_AA6_PreviewMintMirrorsMintChecks() public {
        _genesis();
        _next();
        // лимит окна
        vm.expectPartialRevert(BasketVault.MintWindowCapExceeded.selector);
        vault.previewMint(BASKET, address(usdt), 500_000e6);
        // пауза
        vm.prank(owner);
        vault.pause();
        vm.expectRevert();
        vault.previewMint(BASKET, address(usdt), 1_000e6);
        vm.prank(owner);
        vault.unpause();
        // заморозка перед 28-м
        vm.warp(T_OCT28 - 1 hours);
        vm.expectPartialRevert(BasketVault.MintFrozenBeforeIndex.selector);
        vault.previewMint(BASKET, address(usdt), 1_000e6);
    }

    function test_AA6_PreviewMintMatchesMint() public {
        _genesis();
        _next();
        uint256 p = vault.previewMint(BASKET, address(usdc), 5_000e6);
        assertEq(_mint(bob, address(usdc), 5_000e6), p);
    }

    function test_AA6_PreviewMintGenesisFloor() public {
        vm.expectPartialRevert(BasketVault.GenesisTopUpRequired.selector);
        vault.previewMint(BASKET, address(usdt), 1_000e6);
    }

    function test_AA6_QuoteRedeem_FeedUnavailableAndSequencer() public {
        _genesis();
        MockFeed feed = new MockFeed(8, 1e8);
        _timelocked(abi.encodeCall(vault.setStableFeed, (address(usdc), IAggregatorV3(address(feed)), 1 days)));
        feed.set(1e8, block.timestamp);
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdc), 10_000e6);
        assertTrue(vault.quoteRedeem(BASKET, address(usdc), 100e18).executableNow);
        feed.setBroken(true);
        assertFalse(vault.quoteRedeem(BASKET, address(usdc), 100e18).executableNow);
        assertTrue(vault.isDepegged(address(usdc)));
        feed.setBroken(false);
        feed.set(1e8, block.timestamp);
        SeqFeed f = new SeqFeed();
        f.set(0, block.timestamp - 2 hours);
        _timelocked(abi.encodeCall(vault.setSequencerUptimeFeed, (address(f))));
        feed.set(1e8, block.timestamp);
        assertTrue(vault.quoteRedeem(BASKET, address(usdc), 100e18).executableNow);
        f.set(0, block.timestamp - 10); // grace period
        assertFalse(vault.quoteRedeem(BASKET, address(usdc), 100e18).executableNow);
    }

    // ------------------------------------------------------------ AA-7: комиссии pull
    function test_AA7_BlacklistedTreasuryDoesNotBlockRedeem() public {
        _genesis();
        vm.mockCallRevert(
            address(usdt), abi.encodeWithSelector(IERC20.transfer.selector, treasury), bytes("blacklisted")
        );
        uint256 before = usdt.balanceOf(alice);
        _redeem(alice, address(usdt), 1_000e18);
        assertGt(usdt.balanceOf(alice), before);
        _next();
        _mint(bob, address(usdt), 1_000e6);
        uint256 fees = vault.accruedFees(address(usdt));
        assertGt(fees, 0);
        vm.expectRevert();
        vault.claimFees(address(usdt));
        vm.clearMockedCalls();
        vault.claimFees(address(usdt));
        assertEq(usdt.balanceOf(treasury), fees);
        assertEq(usdt.balanceOf(address(vault)), vault.reserves(BASKET, address(usdt)));
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.claimFees(address(usdt));
    }
}
