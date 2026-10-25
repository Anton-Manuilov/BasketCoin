// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockFeed} from "../mocks/Mocks.sol";

/// Chainlink L2 Sequencer Uptime Feed: answer 0 — работает, 1 — упал; startedAt — момент смены статуса.
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;
    bool public broken;

    function set(int256 a, uint256 s) external {
        (answer, startedAt) = (a, s);
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "down");
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// Этап B: guardian и ограниченная пауза, таймлок админских функций, sequencer uptime, роли токена.
contract StageBTest is BaseTest {
    address internal guardian = makeAddr("guardian");
    bytes32 internal constant SALT = bytes32(0);

    // ------------------------------------------------------------ хелперы таймлока
    function _schedule(bytes memory data, bytes32 salt) internal returns (bytes32 id) {
        vm.prank(owner);
        id = vault.scheduleOp(data, salt);
    }

    function _execute(bytes memory data, bytes32 salt) internal {
        vm.prank(owner);
        vault.executeOp(data, salt);
    }

    function _timelocked(bytes memory data) internal {
        _schedule(data, SALT);
        vm.warp(block.timestamp + vault.opDelay(bytes4(data)));
        _execute(data, SALT);
    }

    function _setGuardian() internal {
        _timelocked(abi.encodeCall(BasketVault.setGuardian, (guardian)));
        assertEq(vault.guardian(), guardian);
    }

    // ================================================================ guardian / пауза
    function test_Guardian_CanPauseButNotUnpause() public {
        _setGuardian();
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Guardian_NoOtherPowers() public {
        _setGuardian();
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);
        vm.startPrank(guardian);
        vm.expectRevert(err);
        vault.scheduleOp(abi.encodeCall(BasketVault.setGuardian, (guardian)), SALT);
        vm.expectRevert(err);
        vault.setMinMintUsd(100e18);
        vm.expectRevert(err);
        vault.revokeGuardian();
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setGuardian(alice);
        vm.stopPrank();
    }

    function test_Guardian_RevokeIsInstant() public {
        _setGuardian();
        vm.expectEmit(address(vault));
        emit BasketVault.GuardianUpdated(guardian, address(0));
        vm.prank(owner);
        vault.revokeGuardian();
        assertEq(vault.guardian(), address(0));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotOwnerOrGuardian.selector, guardian));
        vault.pause();
    }

    function test_Guardian_ViaConstructor() public {
        BasketVault v = new BasketVault(
            owner,
            treasury,
            address(usdt),
            address(usdc),
            50e18,
            guardian,
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        assertEq(v.guardian(), guardian);
        vm.prank(guardian);
        v.pause();
        assertTrue(v.paused());
    }

    function test_Pause_ExpiresAutomatically() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        vm.prank(owner);
        vault.pause();
        uint256 until = block.timestamp + 30 days;
        assertEq(vault.pausedUntil(), until);
        vm.warp(until - 1);
        assertTrue(vault.paused());
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(BASKET, address(usdt), t, 0);
        vm.warp(until);
        assertFalse(vault.paused(), "pause expired");
        assertTrue(vault.quoteRedeem(BASKET, address(usdt), t).executableNow);
        _redeem(alice, address(usdt), t);
        // истёкшую паузу снимать не нужно
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
    }

    function test_Pause_CannotBeExtended() public {
        vm.prank(owner);
        vault.pause();
        vm.warp(block.timestamp + 29 days);
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
    }

    function test_Pause_CooldownAfterUnpause() public {
        _setGuardian();
        vm.prank(guardian);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        uint256 allowed = block.timestamp + 3 days;
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PauseCooldown.selector, allowed));
        vault.pause();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PauseCooldown.selector, allowed));
        vault.pause();
        vm.warp(allowed - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PauseCooldown.selector, allowed));
        vault.pause();
        vm.warp(allowed);
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_CooldownAfterExpiry_MaxDutyCycle() public {
        vm.prank(owner);
        vault.pause();
        uint256 end = block.timestamp + 30 days;
        vm.warp(end + 3 days - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PauseCooldown.selector, end + 3 days));
        vault.pause();
        assertFalse(vault.paused());
        _mint(alice, address(usdt), 100e6); // окно выхода/входа
        vm.warp(end + 3 days);
        vm.prank(owner);
        vault.pause();
        assertEq(vault.pausedUntil(), end + 33 days);
    }

    function testFuzz_Pause_NeverLongerThanMax(uint256 dt) public {
        dt = bound(dt, 0, 400 days);
        vm.prank(owner);
        vault.pause();
        uint256 start = block.timestamp;
        vm.warp(start + dt);
        assertEq(vault.paused(), dt < 30 days);
    }

    // ================================================================ таймлок
    function test_Timelock_DelaysPerSelector() public view {
        assertEq(vault.opDelay(BasketVault.setStableFeed.selector), 2 days);
        assertEq(vault.opDelay(BasketVault.setManualPrice.selector), 2 days);
        assertEq(vault.opDelay(BasketVault.setFeeRecipient.selector), 2 days);
        assertEq(vault.opDelay(BasketVault.setGuardian.selector), 2 days);
        assertEq(vault.opDelay(BasketVault.setSequencerUptimeFeed.selector), 2 days);
        assertEq(vault.opDelay(BasketVault.setTokenRole.selector), 7 days);
        assertEq(vault.opDelay(BasketVault.setIndex.selector), 0);
        assertEq(vault.opDelay(Ownable.transferOwnership.selector), 0);
        assertEq(vault.opDelay(BasketVault.executeOp.selector), 0);
    }

    function test_Timelock_FullCycle_WithEvents() public {
        bytes memory data = abi.encodeCall(BasketVault.setFeeRecipient, (carol));
        bytes32 id = keccak256(abi.encode(data, SALT));
        assertEq(vault.opId(data, SALT), id);
        uint256 eta = block.timestamp + 2 days;
        vm.expectEmit(address(vault));
        emit BasketVault.OpScheduled(id, BasketVault.setFeeRecipient.selector, data, SALT, eta);
        _schedule(data, SALT);
        assertEq(vault.opEta(id), eta);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotReady.selector, id, eta));
        vault.executeOp(data, SALT);

        vm.warp(eta);
        vm.expectEmit(address(vault));
        emit BasketVault.OpExecuted(id, BasketVault.setFeeRecipient.selector);
        vm.expectEmit(address(vault));
        emit BasketVault.FeeRecipientUpdated(treasury, carol);
        _execute(data, SALT);
        assertEq(vault.feeRecipient(), carol);
        assertEq(vault.opEta(id), 0);
        // повторно исполнить нельзя
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotScheduled.selector, id));
        vault.executeOp(data, SALT);
    }

    function test_Timelock_Expiry() public {
        bytes memory data = abi.encodeCall(BasketVault.setFeeRecipient, (carol));
        bytes32 id = _schedule(data, SALT);
        uint256 eta = block.timestamp + 2 days;
        vm.warp(eta + 14 days);
        _execute(data, SALT); // граница включительно
        id = _schedule(data, SALT);
        eta = block.timestamp + 2 days;
        vm.warp(eta + 14 days + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpExpired.selector, id, eta + 14 days));
        vault.executeOp(data, SALT);
        // протухшую заявку можно отменить и поставить заново
        vm.prank(owner);
        vault.cancelOp(id);
        _schedule(data, SALT);
    }

    function test_Timelock_Cancel() public {
        bytes memory data = abi.encodeCall(BasketVault.setManualPrice, (address(usdt), 0.99e18));
        bytes32 id = _schedule(data, SALT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.cancelOp(id);
        vm.expectEmit(address(vault));
        emit BasketVault.OpCancelled(id);
        vm.prank(owner);
        vault.cancelOp(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotScheduled.selector, id));
        vault.executeOp(data, SALT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotScheduled.selector, id));
        vault.cancelOp(id);
    }

    function test_Timelock_ScheduleValidation() public {
        vm.startPrank(owner);
        bytes memory idx = abi.encodeCall(BasketVault.setIndex, (BASKET, 1e18));
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotTimelockable.selector, BasketVault.setIndex.selector));
        vault.scheduleOp(idx, SALT);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotTimelockable.selector, bytes4(0)));
        vault.scheduleOp(hex"aabb", SALT);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotTimelockable.selector, bytes4(0)));
        vault.scheduleOp("", SALT);
        bytes memory data = abi.encodeCall(BasketVault.setFeeRecipient, (carol));
        bytes32 id = vault.scheduleOp(data, SALT);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpAlreadyScheduled.selector, id));
        vault.scheduleOp(data, SALT);
        vault.scheduleOp(data, bytes32(uint256(1))); // другая соль — другая операция
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.scheduleOp(data, bytes32(uint256(2)));
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.executeOp(data, SALT);
    }

    function test_Timelock_InnerRevertBubbles_OpStaysConsumed() public {
        bytes memory data = abi.encodeCall(BasketVault.setFeeRecipient, (address(0)));
        bytes32 id = _schedule(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        vault.executeOp(data, SALT);
        assertGt(vault.opEta(id), 0, "revert rolls back the whole tx");
    }

    function test_Timelock_DirectCallsRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setGuardian(alice);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setSequencerUptimeFeed(alice);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setTokenRole(address(coin), bytes32(0), alice, true);
        vm.expectRevert(BasketVault.OnlyTimelock.selector);
        vault.setManualPrice(address(usdt), 1e18);
        vm.stopPrank();
    }

    function test_Timelock_ManualPriceAndFeed() public {
        _timelocked(abi.encodeCall(BasketVault.setManualPrice, (address(usdt), 0.99e18)));
        assertEq(vault.stablePrice(address(usdt)), 0.99e18);
        MockFeed f = new MockFeed(8, 1e8);
        _timelocked(abi.encodeCall(BasketVault.setStableFeed, (address(usdt), IAggregatorV3(address(f)), 1 days)));
        f.set(1e8, block.timestamp);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    function test_Timelock_IndexStillDirect_On28th() public {
        // индекс не идёт через таймлок: объявление за 2 дня дало бы безрисковый арбитраж (T4)
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.05e18);
        (, uint256 index,,,,) = vault.baskets(BASKET);
        assertEq(index, 1.05e18);
    }

    // ================================================================ роли токена
    function _vaultAdminOfCoin() internal {
        vm.startPrank(owner);
        coin.grantRole(coin.DEFAULT_ADMIN_ROLE(), address(vault));
        coin.renounceRole(coin.DEFAULT_ADMIN_ROLE(), owner);
        vm.stopPrank();
    }

    function test_TokenRole_GrantRevokeVia7DayTimelock() public {
        _vaultAdminOfCoin();
        bytes32 minter = coin.MINTER_ROLE();
        bytes memory data = abi.encodeCall(BasketVault.setTokenRole, (address(coin), minter, carol, true));
        bytes32 id = _schedule(data, SALT);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.OpNotReady.selector, id, block.timestamp + 5 days));
        vault.executeOp(data, SALT);
        vm.warp(block.timestamp + 5 days);
        vm.expectEmit(address(vault));
        emit BasketVault.TokenRoleUpdated(address(coin), minter, carol, true);
        _execute(data, SALT);
        assertTrue(coin.hasRole(minter, carol));
        _timelocked(abi.encodeCall(BasketVault.setTokenRole, (address(coin), minter, carol, false)));
        assertFalse(coin.hasRole(minter, carol));
    }

    function test_TokenRole_OwnerCannotGrantDirectly() public {
        _vaultAdminOfCoin();
        bytes32 minter = coin.MINTER_ROLE();
        bytes32 admin = coin.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, admin));
        coin.grantRole(minter, owner);
    }

    function test_TokenRole_UnregisteredTokenReverts() public {
        BasketToken other = new BasketToken("X", "X", address(vault));
        bytes memory data = abi.encodeCall(BasketVault.setTokenRole, (address(other), bytes32(0), carol, true));
        _schedule(data, SALT);
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TokenNotRegistered.selector, address(other)));
        vault.executeOp(data, SALT);
    }

    // ================================================================ sequencer uptime
    MockSequencerFeed internal seq;

    function _useSequencer(int256 answer, uint256 startedAt) internal {
        seq = new MockSequencerFeed();
        seq.set(answer, startedAt);
        _timelocked(abi.encodeCall(BasketVault.setSequencerUptimeFeed, (address(seq))));
        assertEq(vault.sequencerUptimeFeed(), address(seq));
    }

    function test_Sequencer_UpLongEnough_Works() public {
        _useSequencer(0, block.timestamp - 1 days);
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _redeem(alice, address(usdt), t);
    }

    function test_Sequencer_Down_BlocksMintAndRedeem() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _useSequencer(0, block.timestamp - 1 days);
        seq.set(1, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(BasketVault.SequencerDown.selector);
        vault.mint(BASKET, address(usdt), 100e6, 0);
        vm.prank(alice);
        vm.expectRevert(BasketVault.SequencerDown.selector);
        vault.redeem(BASKET, address(usdt), t, 0);
        // view и topUp не зависят от секвенсора
        vault.collateralRatioBps(BASKET);
        vm.prank(bob);
        vault.topUpReserve(BASKET, address(usdc), 10e6);
    }

    function test_Sequencer_GracePeriodBoundary() public {
        _useSequencer(0, block.timestamp - 1 days);
        uint256 upSince = block.timestamp;
        seq.set(0, upSince); // только что восстановился
        vm.warp(upSince + 3600);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.SequencerGracePeriod.selector, upSince));
        vault.mint(BASKET, address(usdt), 100e6, 0);
        vm.warp(upSince + 3601);
        _mint(alice, address(usdt), 100e6);
    }

    function test_Sequencer_InvalidAnswers() public {
        _useSequencer(0, block.timestamp - 1 days);
        seq.set(2, block.timestamp - 1 days);
        _expectSeqInvalid();
        seq.set(-1, block.timestamp - 1 days);
        _expectSeqInvalid();
        seq.set(0, 0);
        _expectSeqInvalid();
        seq.set(0, block.timestamp + 1);
        _expectSeqInvalid();
        seq.set(0, block.timestamp - 1 days);
        seq.setBroken(true);
        _expectSeqInvalid();
    }

    function test_Sequencer_EOAFeedInvalid_AndDisable() public {
        // v5.1: EOA/неотвечающий фид отклоняется уже при установке
        bytes memory data = abi.encodeCall(BasketVault.setSequencerUptimeFeed, (makeAddr("eoa")));
        _schedule(data, SALT);
        vm.warp(block.timestamp + vault.opDelay(bytes4(data)));
        vm.prank(owner);
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        vault.executeOp(data, SALT);
        assertEq(vault.sequencerUptimeFeed(), address(0));
        _timelocked(abi.encodeCall(BasketVault.setSequencerUptimeFeed, (address(0))));
        _mint(alice, address(usdt), 100e6);
    }

    function _expectSeqInvalid() internal {
        vm.prank(alice);
        vm.expectRevert(BasketVault.SequencerFeedInvalid.selector);
        vault.mint(BASKET, address(usdt), 100e6, 0);
    }
}
