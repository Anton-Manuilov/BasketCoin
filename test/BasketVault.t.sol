// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BasketVault} from "../src/BasketVault.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {DateLib} from "../src/libraries/DateLib.sol";
import {MockStable, MockFeed} from "./mocks/Mocks.sol";

contract DateHarness {
    function date(uint256 ts) external pure returns (uint256, uint256, uint256) {
        return DateLib.timestampToDate(ts);
    }
}

contract BasketVaultTest is Test {
    // 2026-10-19 00:00 UTC, 2026-10-28 00:00 UTC, 2026-10-29, 2026-11-28
    uint256 constant T_OCT19 = 1792368000;
    uint256 constant T_OCT28 = 1793145600;
    uint256 constant T_OCT29 = 1793232000;
    uint256 constant T_NOV28 = 1795824000;
    uint256 constant BASKET = 1;

    address owner = makeAddr("anton");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockStable usdt;
    MockStable usdc;
    BasketToken coin;
    BasketVault vault;

    function setUp() public {
        vm.warp(T_OCT19);
        usdt = new MockStable("Tether USD", "USDT", 6);
        usdc = new MockStable("USD Coin", "USDC", 6);
        vault = new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18);
        coin = new BasketToken("BasketCoin", "BKT", owner);

        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(BASKET, coin, 1e18); // индекс $1.00
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            usdt.mint(u, 1_000_000e6);
            usdc.mint(u, 1_000_000e6);
            vm.startPrank(u);
            usdt.approve(address(vault), type(uint256).max);
            usdc.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _mint(address u, address stable, uint256 amount) internal returns (uint256) {
        vm.prank(u);
        return vault.mint(BASKET, stable, amount, 0);
    }

    // ------------------------------------------------------------------ минт
    function test_Mint_FeeAndBuffer() public {
        uint256 out = _mint(alice, address(usdt), 1_000e6);
        // fee = 3 USDT, net = 997 USDT, tokens = 997 / 1.2 = 830.8333...
        assertEq(usdt.balanceOf(treasury), 3e6, "fee to treasury");
        assertEq(vault.reserves(BASKET, address(usdt)), 997e6, "reserve");
        assertEq(out, 830833333333333333333, "tokens out");
        assertEq(coin.balanceOf(alice), out);
        // обеспечение = 997 / 830.8333 = 120%
        assertApproxEqAbs(vault.collateralRatioBps(BASKET), 12_000, 1);
    }

    function test_Mint_AtWorkingPrice() public {
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, 1.03e18);
        uint256 out = _mint(alice, address(usdc), 1_000e6);
        assertEq(out, (uint256(997e18) * 1e18 * 10_000) / (uint256(1.03e18) * 12_000));
    }

    function test_Mint_SlippageReverts() public {
        uint256 expected = vault.previewMint(BASKET, address(usdt), 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.Slippage.selector, expected, expected + 1));
        vault.mint(BASKET, address(usdt), 1_000e6, expected + 1);
    }

    function test_Mint_UnknownBasketAndStableRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnknownBasket.selector, 99));
        vault.mint(99, address(usdt), 100e6, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, address(0xdead)));
        vault.mint(BASKET, address(0xdead), 100e6, 0);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.mint(BASKET, address(usdt), 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------- минимальный минт
    function test_MinMint_Enforced() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 49.99e18, 50e18));
        vault.mint(BASKET, address(usdt), 49.99e6, 0);
        _mint(alice, address(usdt), 50e6); // ровно $50 — ок
    }

    function test_MinMint_ChangeWithinBounds() public {
        vm.startPrank(owner);
        vault.setMinMintUsd(1_000e18);
        assertEq(vault.minMintUsd(), 1_000e18);
        vault.setMinMintUsd(50e18);
        assertEq(vault.minMintUsd(), 50e18);
        vault.setMinMintUsd(500e18);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 499e18, 500e18));
        vault.mint(BASKET, address(usdt), 499e6, 0);
    }

    function test_MinMint_OutOfRangeReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 49e18));
        vault.setMinMintUsd(49e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 1_001e18));
        vault.setMinMintUsd(1_001e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ выкуп
    function test_Redeem_ReturnsCollateral() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        uint256 balBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(BASKET, address(usdt), tokens, 0);
        // gross = 830.833333 USDT, fee = ceil(0.3%) = 2.492500, пользователю 828.340833
        assertEq(out, 828340833);
        assertEq(usdt.balanceOf(alice) - balBefore, out);
        assertEq(coin.balanceOf(alice), 0, "burned");
        assertEq(coin.totalSupply(), 0);
        assertEq(usdt.balanceOf(treasury), 3e6 + 2492500, "fees");
        // буфер ~166.17 USDT остаётся в резерве
        assertEq(vault.reserves(BASKET, address(usdt)), 997e6 - 830833333);
        assertEq(usdt.balanceOf(address(vault)), vault.reserves(BASKET, address(usdt)));
    }

    function test_Redeem_Partial() public {
        uint256 tokens = _mint(alice, address(usdc), 1_200e6);
        vm.prank(alice);
        vault.redeem(BASKET, address(usdc), tokens / 2, 0);
        assertEq(coin.balanceOf(alice), tokens - tokens / 2);
    }

    function test_Redeem_CannotExceedStableReserve() public {
        _mint(alice, address(usdt), 100e6); // USDT резерв 99.7
        uint256 tokens = _mint(bob, address(usdc), 10_000e6);
        vm.prank(bob);
        vm.expectRevert(); // InsufficientReserve
        vault.redeem(BASKET, address(usdt), tokens, 0);
        vm.prank(bob);
        vault.redeem(BASKET, address(usdc), tokens, 0); // в USDC — ок
    }

    function test_Redeem_MoreThanBalanceReverts() public {
        _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        uint256 bal = coin.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance при burn
        vault.redeem(BASKET, address(usdt), bal + 1, 0);
    }

    // ------------------------------------------------------------------ пауза
    function test_Pause_BlocksMintAndRedeem() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(BASKET, address(usdt), 100e6, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(BASKET, address(usdc), 100e6, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(BASKET, address(usdt), tokens, 0);
        vm.stopPrank();

        vm.prank(owner);
        vault.unpause();
        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), tokens, 0);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.pause();
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.unpause();
    }

    // ------------------------------------------------------------------ депег
    function test_Depeg_USDT_BlocksOnlyUSDT() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        _mint(alice, address(usdc), 1_000e6);
        vm.prank(owner);
        vault.setManualPrice(address(usdt), 0.94e18);
        assertTrue(vault.isDepegged(address(usdt)));
        assertFalse(vault.isDepegged(address(usdc)));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableDepegged.selector, address(usdt), 0.94e18));
        vault.mint(BASKET, address(usdt), 100e6, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableDepegged.selector, address(usdt), 0.94e18));
        vault.redeem(BASKET, address(usdt), tokens / 4, 0);
        // USDC продолжает работать
        vault.mint(BASKET, address(usdc), 100e6, 0);
        vault.redeem(BASKET, address(usdc), tokens / 4, 0);
        vm.stopPrank();
    }

    function test_Depeg_Boundaries() public {
        vm.startPrank(owner);
        vault.setManualPrice(address(usdt), 0.95e18); // ровно -5% — ещё не депег
        assertFalse(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 1.05e18); // ровно +5%
        assertFalse(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 1.0501e18);
        assertTrue(vault.isDepegged(address(usdt)));
        vault.setManualPrice(address(usdt), 0.9499e18);
        assertTrue(vault.isDepegged(address(usdt)));
        vm.stopPrank();
    }

    function test_Depeg_Recovery() public {
        uint256 tokens = _mint(alice, address(usdt), 1_000e6);
        vm.prank(owner);
        vault.setManualPrice(address(usdt), 1.08e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(BASKET, address(usdt), tokens, 0);
        vm.prank(owner);
        vault.setManualPrice(address(usdt), 1e18);
        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), tokens, 0);
        _mint(alice, address(usdt), 100e6);
    }

    function test_Depeg_ConservativePricingInsideBand() public {
        // USDT = $0.97: депозит оценивается по $0.97 (меньше токенов)
        vm.prank(owner);
        vault.setManualPrice(address(usdt), 0.97e18);
        uint256 out = _mint(alice, address(usdt), 1_000e6);
        assertEq(out, (uint256(997e18) * 0.97e18 / 1e18) * 10_000 / 12_000);
        // USDC = $1.02: выкуп платит по $1.02 (меньше USDC), минт оценивает по $1
        vm.prank(owner);
        vault.setManualPrice(address(usdc), 1.02e18);
        uint256 out2 = _mint(bob, address(usdc), 1_000e6);
        assertEq(out2, 830833333333333333333);
        (uint256 so,) = vault.previewRedeem(BASKET, address(usdc), out2);
        uint256 gross = (uint256(830833333333333333333) * 1e18) / (1.02e18 * 1e12);
        assertEq(so, gross - (gross * 30 + 9_999) / 10_000);
    }

    function test_Depeg_ViaFeedWithFallback() public {
        MockFeed feed = new MockFeed(8, 1e8);
        vm.prank(owner);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(feed)), 1 days);
        assertEq(vault.stablePrice(address(usdt)), 1e18);

        feed.set(0.93e8, block.timestamp); // фид показывает депег
        assertTrue(vault.isDepegged(address(usdt)));
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(BASKET, address(usdt), 100e6, 0);

        // фид устарел -> fallback на ручную цену ($1)
        vm.warp(block.timestamp + 2 days);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
        assertFalse(vault.isDepegged(address(usdt)));

        // свежий, но фид сломан (revert) -> fallback
        feed.set(0.93e8, block.timestamp);
        assertTrue(vault.isDepegged(address(usdt)));
        feed.setBroken(true);
        assertFalse(vault.isDepegged(address(usdt)));
        _mint(alice, address(usdt), 100e6);

        // ответ <= 0 -> fallback
        feed.setBroken(false);
        feed.set(-1, block.timestamp);
        assertEq(vault.stablePrice(address(usdt)), 1e18);
    }

    // ---------------------------------------------------------------- таймлок
    function test_Timelock_NewStable9Days() public {
        MockStable dai = new MockStable("Dai", "DAI", 18);
        dai.mint(alice, 1_000e18);
        vm.prank(alice);
        dai.approve(address(vault), type(uint256).max);

        vm.prank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        (uint64 executeAfter,,) = vault.pendingStables(address(dai));
        assertEq(executeAfter, block.timestamp + 9 days);

        // до исполнения минт в DAI запрещён
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableNotEnabled.selector, address(dai)));
        vault.mint(BASKET, address(dai), 100e18, 0);

        vm.warp(block.timestamp + 9 days - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TimelockNotExpired.selector, executeAfter));
        vault.executeStable(address(dai));

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        vault.executeStable(address(dai));
        assertEq(vault.stableCount(), 3);

        // 18 decimals: 100 DAI -> 99.7/1.2 токенов
        vm.prank(alice);
        uint256 out = vault.mint(BASKET, address(dai), 100e18, 0);
        assertEq(out, (uint256(99.7e18) * 10_000) / 12_000);
    }

    function test_Timelock_CancelAndNoPending() public {
        address x = address(new MockStable("X", "X", 6));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NoPendingStable.selector, x));
        vault.executeStable(x);
        vault.proposeStable(x, IAggregatorV3(address(0)), 0);
        vault.cancelStable(x);
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NoPendingStable.selector, x));
        vault.executeStable(x);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableAlreadyEnabled.selector, address(usdt)));
        vault.proposeStable(address(usdt), IAggregatorV3(address(0)), 0);
        vm.stopPrank();
    }

    // ------------------------------------------------- индекс: 28-е и ±3%
    function test_SetIndex_Only28th() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotIndexDay.selector, 19));
        vault.setIndex(BASKET, 1.1e18);

        vm.warp(T_OCT28 + 15 hours);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.1e18);
        (, uint256 idx, uint256 wp,,,) = vault.baskets(BASKET);
        assertEq(idx, 1.1e18);
        assertEq(wp, 1.1e18);

        // второй раз в тот же день/месяц — нельзя
        vm.prank(owner);
        vm.expectRevert(BasketVault.IndexAlreadyUpdatedThisMonth.selector);
        vault.setIndex(BASKET, 1.2e18);

        vm.warp(T_OCT29);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotIndexDay.selector, 29));
        vault.setIndex(BASKET, 1.2e18);

        // 28 ноября — снова можно
        vm.warp(T_NOV28 + 1);
        vm.prank(owner);
        vault.setIndex(BASKET, 1.2e18);
    }

    function test_WorkingPrice_Within3Percent() public {
        vm.startPrank(owner);
        vault.setWorkingPrice(BASKET, 1.03e18);
        vault.setWorkingPrice(BASKET, 0.97e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 1.0301e18, 1e18));
        vault.setWorkingPrice(BASKET, 1.0301e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PriceOutOfBand.selector, 0.9699e18, 1e18));
        vault.setWorkingPrice(BASKET, 0.9699e18);
        vm.stopPrank();

        // после нового индекса полоса ±3% считается от нового индекса, рабочая цена сброшена
        vm.warp(T_OCT28);
        vm.startPrank(owner);
        vault.setIndex(BASKET, 1.1e18);
        (,, uint256 wp,,,) = vault.baskets(BASKET);
        assertEq(wp, 1.1e18);
        vault.setWorkingPrice(BASKET, 1.133e18); // +3% от нового индекса
        vm.expectRevert();
        vault.setWorkingPrice(BASKET, 1.03e18);
        vm.stopPrank();
    }

    function test_DateLib_KnownDates() public {
        DateHarness h = new DateHarness();
        _checkDate(h, 0, 1970, 1, 1);
        _checkDate(h, 1709078400, 2024, 2, 28);
        _checkDate(h, 1709164800, 2024, 2, 29); // високосный
        _checkDate(h, 951868800, 2000, 3, 1);
        _checkDate(h, T_OCT28 + 86399, 2026, 10, 28);
        _checkDate(h, T_OCT29, 2026, 10, 29);
        _checkDate(h, 4133894400, 2100, 12, 31);
    }

    function _checkDate(DateHarness h, uint256 ts, uint256 y, uint256 m, uint256 d) internal pure {
        (uint256 yy, uint256 mm, uint256 dd) = h.date(ts);
        assertEq(yy, y);
        assertEq(mm, m);
        assertEq(dd, d);
    }

    // --------------------------------------------------------- права доступа
    function test_Access_NonOwnerReverts() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        vault.setIndex(BASKET, 1e18);
        vm.expectRevert(err);
        vault.setWorkingPrice(BASKET, 1e18);
        vm.expectRevert(err);
        vault.setManualPrice(address(usdt), 1e18);
        vm.expectRevert(err);
        vault.setStableFeed(address(usdt), IAggregatorV3(address(0)), 0);
        vm.expectRevert(err);
        vault.setMinMintUsd(100e18);
        vm.expectRevert(err);
        vault.setFeeRecipient(alice);
        vm.expectRevert(err);
        vault.proposeStable(address(0x1234), IAggregatorV3(address(0)), 0);
        vm.expectRevert(err);
        vault.executeStable(address(0x1234));
        vm.expectRevert(err);
        vault.cancelStable(address(0x1234));
        vm.expectRevert(err);
        vault.addBasket(2, coin, 1e18);
        vm.expectRevert(err);
        vault.renounceOwnership();
        vm.stopPrank();
    }

    function test_Access_TokenMintBurnOnlyVault() public {
        bytes32 role = coin.MINTER_ROLE();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        coin.mint(alice, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        coin.burn(bob, 1e18);
        vm.stopPrank();
    }

    function test_Owner_RenounceDisabledAndTwoStepTransfer() public {
        vm.prank(owner);
        vm.expectRevert(BasketVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner); // ещё не принято
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    function test_FeeRecipient_Change() public {
        address t2 = makeAddr("t2");
        vm.prank(owner);
        vault.setFeeRecipient(t2);
        _mint(alice, address(usdt), 1_000e6);
        assertEq(usdt.balanceOf(t2), 3e6);
        vm.prank(owner);
        vm.expectRevert(BasketVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    // ------------------------------------------------- архитектура: 2-я корзина
    function test_SecondBasket_SeparateToken() public {
        BasketToken eur = new BasketToken("BasketCoin EUR", "BKT-EUR", owner);
        vm.startPrank(owner);
        eur.grantRole(eur.MINTER_ROLE(), address(vault));
        vault.addBasket(2, eur, 1.08e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BasketExists.selector, 2));
        vault.addBasket(2, eur, 1e18);
        vm.stopPrank();

        _mint(alice, address(usdt), 1_000e6); // корзина 1
        vm.prank(alice);
        uint256 out = vault.mint(2, address(usdt), 1_000e6, 0);
        assertEq(out, (uint256(997e18) * 1e18 * 10_000) / (uint256(1.08e18) * 12_000));
        assertEq(vault.reserves(2, address(usdt)), 997e6);
        assertEq(vault.reserves(BASKET, address(usdt)), 997e6);
        assertEq(vault.basketCount(), 2);
    }

    // ------------------------------------------------------------------ fuzz
    /// Минт -> выкуп никогда не возвращает больше депозита, обеспечение не падает ниже 120%.
    function testFuzz_RoundTripNeverProfitable(uint256 amount, uint256 priceBps) public {
        amount = bound(amount, 50e6, 1_000_000e6);
        priceBps = bound(priceBps, 9_700, 10_300);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, priceBps * 1e14);
        uint256 before = usdt.balanceOf(alice);
        uint256 tokens = _mint(alice, address(usdt), amount);
        assertGe(vault.collateralRatioBps(BASKET), 11_999);
        vm.prank(alice);
        vault.redeem(BASKET, address(usdt), tokens, 0);
        assertLe(usdt.balanceOf(alice), before);
        assertEq(usdt.balanceOf(address(vault)), vault.reserves(BASKET, address(usdt)));
    }
}
