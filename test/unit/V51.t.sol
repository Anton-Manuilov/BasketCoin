// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {V4Mode} from "../utils/V4Mode.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockFeed} from "../mocks/Mocks.sol";

contract SeqFeedOk {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0, 1, 1, 1);
    }
}

/// v5.1: заморозка минта перед 28-м (M1), худшая цена при сломанном фиде (M3), скользящее окно (L-2),
/// валидация фида секвенсора (L-1), повторная постановка протухшей операции (L-3), genesis (L-4).
contract V51Test is BaseTest {
    bytes32 internal constant SALT = bytes32(uint256(51));

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

    /// пополнение + первый минт $1M, покрытие ~195%
    function _genesis() internal {
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdt), 622_000e6);
        _mint(alice, address(usdt), 1_000_000e6);
        assertApproxEqAbs(_cov(), 19_500, 30);
    }

    function _timelocked(bytes memory data) internal {
        vm.prank(owner);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + vault.opDelay(bytes4(data)));
        vm.prank(owner);
        vault.executeOp(data, SALT);
    }

    // ------------------------------------------------------------ M1: заморозка минта
    function test_Freeze_DefaultsAndSlot() public view {
        assertEq(vault.mintFreezeSec(), 6 hours);
        assertEq(uint256(vm.load(address(vault), bytes32(V4Mode.MINT_FREEZE_SLOT))), 6 hours);
        assertEq(vault.opDelay(vault.setMintFreeze.selector), 2 days);
    }

    function test_Freeze_WindowBefore28th_UntilSetIndex() public {
        _genesis();
        vm.roll(block.number + 1);
        vm.warp(T_OCT28 - 6 hours - 1);
        assertFalse(vault.isMintFrozen(BASKET));
        _mint(bob, address(usdt), 1_000e6);
        vm.warp(T_OCT28 - 6 hours);
        assertTrue(vault.isMintFrozen(BASKET));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MintFrozenBeforeIndex.selector, BASKET, 2026, 10));
        vault.mint(BASKET, address(usdt), 1_000e6, 0);
        // выкуп во время заморозки работает (окно выхода)
        _redeem(bob, address(usdt), 100e18);
        // 28-е до setIndex — всё ещё заморожено
        vm.warp(T_OCT28 + 1 hours);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintFrozenBeforeIndex.selector);
        vault.mint(BASKET, address(usdt), 1_000e6, 0);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.01e18);
        assertFalse(vault.isMintFrozen(BASKET));
        _next();
        _mint(bob, address(usdt), 1_000e6);
    }

    function test_Freeze_LateOn28th_And29th() public {
        _genesis();
        vm.warp(T_OCT28_END - 10);
        assertTrue(vault.isMintFrozen(BASKET), "late 28th without index still frozen");
        vm.warp(T_OCT29);
        assertFalse(vault.isMintFrozen(BASKET), "29th: freeze lifted even if index was not set");
        _next();
        _mint(bob, address(usdt), 1_000e6);
    }

    function test_Freeze_FebruaryAndYearBoundary() public {
        vm.warp(T_FEB28_2027 - 1);
        assertTrue(vault.isMintFrozen(BASKET));
        vm.warp(T_FEB28_2027 - 6 hours - 1);
        assertFalse(vault.isMintFrozen(BASKET));
        vm.warp(T_DEC28_NOON);
        assertTrue(vault.isMintFrozen(BASKET));
    }

    function test_SetMintFreeze_TimelockBoundsDisable() public {
        vm.prank(owner);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setMintFreeze(1 hours);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MintFreezeOutOfRange.selector, 2 days + 1));
        vault.setMintFreeze(2 days + 1);
        bytes memory data = abi.encodeCall(BasketVault.setMintFreeze, (0));
        vm.prank(owner);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BasketVault.MintFreezeUpdated(6 hours, 0);
        vm.prank(owner);
        vault.executeOp(data, SALT);
        assertEq(vault.mintFreezeSec(), 0);
        _genesis();
        vm.warp(T_OCT28 + 1 hours);
        assertFalse(vault.isMintFrozen(BASKET));
        _mint(bob, address(usdt), 1_000e6);
    }

    function test_Freeze_LongerWindow() public {
        _timelocked(abi.encodeCall(BasketVault.setMintFreeze, (2 days)));
        vm.warp(T_OCT28 - 2 days);
        assertTrue(vault.isMintFrozen(BASKET));
        vm.warp(T_OCT28 - 2 days - 1);
        assertFalse(vault.isMintFrozen(BASKET));
    }

    // ------------------------------------------------------------ M3: худшая цена при сломанном фиде
    function test_StaleFeed_NoFullRedeemOnInflatedCoverage() public {
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdc), 400e6);
        MockFeed feed = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 hours);
        _mint(alice, address(usdt), 1_000e6);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Full));
        // фид USDT устарел: раньше резерв USDT считался по ручной $1 (покрытие ~168%, FULL)
        vm.warp(block.timestamp + 1 hours + 1);
        assertLt(_cov(), 11_500, "USDT reserve excluded");
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Suspended));
        BasketVault.RedeemQuote memory q = vault.quoteRedeem(BASKET, address(usdc), 100e18);
        assertFalse(q.executableNow);
        vm.prank(alice);
        vm.expectPartialRevert(BasketVault.RedemptionSuspended.selector);
        vault.redeem(BASKET, address(usdc), 100e18, 0);
        // фид восстановлен — всё как прежде
        feed.set(1e8, block.timestamp);
        assertEq(uint256(_tier()), uint256(BasketVault.RedeemTier.Full));
        _redeem(alice, address(usdc), 100e18);
    }

    function test_BrokenFeed_AlsoBlocksMintFloor() public {
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdt), 400e6);
        MockFeed feed = new MockFeed(8, 1e8);
        vm.prank(address(vault));
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 hours);
        _mint(alice, address(usdc), 1_000e6);
        feed.setBroken(true);
        // минт в USDC: резерв USDT не засчитывается → покрытие < пола, лимиты сужены до 0
        _next();
        assertLt(_cov(), 15_000);
        (uint256 w,) = vault.mintCapacity(BASKET);
        assertEq(w, 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(BASKET, address(usdc), 60e6, 0);
    }

    // ------------------------------------------------------------ L-2: скользящее окно
    function test_SlidingWindow_NoDoubleCapAtBoundary() public {
        _genesis();
        vm.warp((block.timestamp / 3600 + 1) * 3600 - 300); // конец окна
        _next();
        uint256 chunk = _reserveUsd() / 1e12 * 3 / 100;
        _mint(bob, address(usdt), chunk);
        _next();
        _mint(bob, address(usdt), chunk);
        _next();
        _mint(bob, address(usdt), chunk);
        // начало следующего окна: фиксированное окно дало бы ещё 10%, скользящее — нет
        vm.warp((block.timestamp / 3600 + 1) * 3600);
        _next();
        (uint256 w,) = vault.mintCapacity(BASKET);
        assertLt(w, _reserveUsd() * 2 / 100);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.MintWindowCapExceeded.selector);
        vault.mint(BASKET, address(usdt), chunk, 0);
        // через полчаса вес прошлого окна ~50%
        vm.warp(block.timestamp + 1800);
        _next();
        _mint(bob, address(usdt), chunk);
        // через два окна — полный лимит
        vm.warp((block.timestamp / 3600 + 2) * 3600);
        _next();
        (w,) = vault.mintCapacity(BASKET);
        assertApproxEqRel(w, _reserveUsd() / 10, 1e14);
    }

    // ------------------------------------------------------------ L-1: фид секвенсора
    function test_SequencerFeed_ValidAccepted() public {
        SeqFeedOk f = new SeqFeedOk();
        _timelocked(abi.encodeCall(BasketVault.setSequencerUptimeFeed, (address(f))));
        assertEq(vault.sequencerUptimeFeed(), address(f));
    }

    // ------------------------------------------------------------ L-3: протухшая операция
    function test_ExpiredOp_CanBeRescheduled() public {
        bytes memory data = abi.encodeCall(BasketVault.setMintFreeze, (1 hours));
        vm.startPrank(owner);
        bytes32 id = vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 2 days + 14 days);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpAlreadyScheduled.selector, id));
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 1);
        vault.scheduleOp(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vault.executeOp(data, SALT);
        vm.stopPrank();
        assertEq(vault.mintFreezeSec(), 1 hours);
    }

    // ------------------------------------------------------------ L-4: genesis
    function test_Genesis_ReportsMissingTopUp_ThenSucceeds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.GenesisTopUpRequired.selector, BASKET, 249.25e18));
        vault.mint(BASKET, address(usdt), 1_000e6, 0);
        vm.prank(owner);
        vault.topUpReserve(BASKET, address(usdc), 249.25e6);
        _mint(alice, address(usdt), 1_000e6);
        assertGe(_cov(), 15_000);
    }
}
