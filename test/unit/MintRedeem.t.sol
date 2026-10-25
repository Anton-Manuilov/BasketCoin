// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockStable, FeeOnTransferStable, NoReturnStable, ReturnFalseStable} from "../mocks/Mocks.sol";

/// Минимальный минт, комиссии и округления, decimals 6/8/18, нестандартные токены, пауза, несколько корзин.
contract MintRedeemTest is BaseTest {
    // ------------------------------------------------ минимальный минт: границы
    function test_MinMint_50_ExactAndMinusOneUnit_6dec() public {
        _mint(alice, address(usdt), 50e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 50e18 - 1e12, 50e18));
        vault.mint(BASKET, address(usdt), 50e6 - 1, 0);
    }

    function test_MinMint_AppliesBeforeProtocolFee() public {
        // $50 проходит, хотя после комиссии 0,3% в резерв попадает только $49,85
        vm.prank(alice);
        vault.mint(BASKET, address(usdt), 50e6, 0);
        assertEq(vault.reserves(BASKET, address(usdt)), 50e6 - 150_000);
        assertLt(vault.reserves(BASKET, address(usdt)) * 1e12, vault.minMintUsd());
    }

    function test_MinMint_1000_ExactAndMinusOneUnit() public {
        vm.prank(owner);
        vault.setMinMintUsd(1_000e18);
        _mint(alice, address(usdc), 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 1_000e18 - 1e12, 1_000e18));
        vault.mint(BASKET, address(usdc), 1_000e6 - 1, 0);
    }

    function test_MinMint_ParamBounds_OneWei() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit BasketVault.MinMintUpdated(50e18, 50e18);
        vault.setMinMintUsd(50e18);
        vault.setMinMintUsd(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 50e18 - 1));
        vault.setMinMintUsd(50e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 1_000e18 + 1));
        vault.setMinMintUsd(1_000e18 + 1);
        vm.stopPrank();
    }

    function test_MinMint_ConstructorBounds() public {
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 49e18));
        new BasketVault(
            owner,
            treasury,
            address(usdt),
            address(usdc),
            49e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        vm.expectRevert(abi.encodeWithSelector(BasketVault.MinMintOutOfRange.selector, 1_001e18));
        new BasketVault(
            owner,
            treasury,
            address(usdt),
            address(usdc),
            1_001e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
    }

    function test_MinMint_UsesConservativePriceBelowOne() public {
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.97e18);
        // 50 USDT * 0,97 = $48,5 < $50
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 48.5e18, 50e18));
        vault.mint(BASKET, address(usdt), 50e6, 0);
        uint256 need = (uint256(50e18) * 1e18 + 0.97e18 - 1) / 0.97e18 / 1e12 + 1; // ceil в единицах USDT
        _mint(alice, address(usdt), need);
    }

    function test_MinMint_8and18Decimals() public {
        MockStable s8 = new MockStable("S8", "S8", 8);
        MockStable s18 = new MockStable("S18", "S18", 18);
        _addStableViaTimelock(address(s8));
        _addStableViaTimelock(address(s18));
        _fund(address(s8));
        _fund(address(s18));
        _mint(alice, address(s8), 50e8);
        _mint(alice, address(s18), 50e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 50e18 - 1e10, 50e18));
        vault.mint(BASKET, address(s8), 50e8 - 1, 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 50e18 - 1, 50e18));
        vault.mint(BASKET, address(s18), 50e18 - 1, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------ комиссии и округления
    function test_Fee_MintRoundsUp() public {
        _mint(alice, address(usdt), 50e6); // 150000 ровно
        assertEq((usdt.balanceOf(treasury) + vault.accruedFees(address(usdt))), 150_000);
        _mint(alice, address(usdt), 50e6 + 1); // 150000,003 → 150001
        assertEq((usdt.balanceOf(treasury) + vault.accruedFees(address(usdt))), 150_000 + 150_001);
    }

    function test_Fee_RedeemRoundsUp_AndDust() public {
        _mint(alice, address(usdt), 1_000e6);
        // 1 wei токена → gross = 0 → ZeroAmount
        vm.prank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.redeem(BASKET, address(usdt), 1, 0);
        // 1e12 wei = $0,000001 → gross = 1, fee = ceil = 1, выплата 0 → ZeroAmount
        vm.prank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.redeem(BASKET, address(usdt), 1e12, 0);
        // 2e12 → gross 2, fee 1, выплата 1
        uint256 before = (usdt.balanceOf(treasury) + vault.accruedFees(address(usdt)));
        assertEq(_redeem(alice, address(usdt), 2e12), 1);
        assertEq((usdt.balanceOf(treasury) + vault.accruedFees(address(usdt))) - before, 1);
    }

    function test_ZeroAmountReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.mint(BASKET, address(usdt), 0, 0);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.redeem(BASKET, address(usdt), 0, 0);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.topUpReserve(BASKET, address(usdt), 0);
        vm.stopPrank();
    }

    /// При MAX_PRICE и минимальном минте выпуск всё ещё > 0 (≈41 wei): ветка tokensOut == 0 в mint
    /// недостижима при текущих ограничениях и оставлена как защитная.
    function test_Mint_AtMaxIndex_StillNonZero() public {
        // v0.4: индекс 1e36 достижим только как стартовый индекс новой корзины
        BasketToken t2 = new BasketToken("T2", "T2", owner);
        vm.startPrank(owner);
        t2.grantRole(t2.MINTER_ROLE(), address(vault));
        vault.addBasket(2, t2, 1e36);
        vm.stopPrank();
        vm.prank(alice);
        uint256 out = vault.mint(2, address(usdt), 50e6, 0);
        assertEq(out, (uint256(49.85e6) * 1e12 * 1e22) / (1e36 * 12_000));
        assertGt(out, 0);
    }

    function test_Rounding_NeverOverIssues(uint256 amount, uint256 pBps) public {
        amount = bound(amount, 50e6, 10_000_000e6);
        pBps = bound(pBps, 9_700, 10_300);
        vm.prank(owner);
        vault.setWorkingPrice(BASKET, pBps * 1e14);
        uint256 t = _mint(alice, address(usdt), amount);
        uint256 net = amount - _ceilFee(amount);
        // стоимость выпущенного * 1,2 <= netUsd
        assertLe((t * _wp(BASKET) / 1e18) * 12_000 / 10_000, net * 1e12);
        (uint256 out, uint256 fee) = vault.previewRedeem(BASKET, address(usdt), t);
        assertLe(out + fee, (t * _wp(BASKET) / 1e18) / 1e12, "payout <= exact value");
    }

    // ------------------------------------------------ decimals 6/8/18: одинаковая стоимость → одинаковый результат
    function test_Decimals_6_8_18_Equivalent() public {
        MockStable s8 = new MockStable("S8", "S8", 8);
        MockStable s18 = new MockStable("S18", "S18", 18);
        _addStableViaTimelock(address(s8));
        _addStableViaTimelock(address(s18));
        _fund(address(s8));
        _fund(address(s18));
        uint256 t6 = _mint(alice, address(usdt), 1_000e6);
        uint256 t8 = _mint(bob, address(s8), 1_000e8);
        uint256 t18 = _mint(carol, address(s18), 1_000e18);
        assertEq(t6, t8);
        assertEq(t6, t18);
        // котировки при одном и том же состоянии (STANDARD)
        (uint256 o6,) = vault.previewRedeem(BASKET, address(usdt), t6);
        (uint256 o8,) = vault.previewRedeem(BASKET, address(s8), t8);
        (uint256 o18,) = vault.previewRedeem(BASKET, address(s18), t18);
        assertEq(o6, 828_340_833);
        // большая точность → не меньше, чем у 6 знаков, и разница меньше 1 единицы USDT-точности (+ ceil комиссии)
        assertApproxEqAbs(o8, o6 * 100, 100);
        assertApproxEqAbs(o18, o6 * 1e12, 1e12);
        _redeem(alice, address(usdt), t6);
        _redeem(bob, address(s8), t8);
        _redeem(carol, address(s18), t18);
        assertEq(coin.totalSupply(), 0);
    }

    function test_Decimals_Above18_Rejected() public {
        MockStable s19 = new MockStable("S19", "S19", 19);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnsupportedDecimals.selector, 19));
        vault.proposeStable(address(s19), IAggregatorV3(address(0)), 0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.UnsupportedDecimals.selector, 19));
        new BasketVault(
            owner,
            treasury,
            address(s19),
            address(usdc),
            50e18,
            address(0),
            address(0),
            IAggregatorV3(address(0)),
            IAggregatorV3(address(0)),
            0
        );
    }

    // ------------------------------------------------ нестандартные токены
    function test_NoReturnToken_USDTLike() public {
        NoReturnStable nr = new NoReturnStable();
        _addStableViaTimelock(address(nr));
        nr.mint(alice, 10_000e6);
        vm.prank(alice);
        nr.approve(address(vault), type(uint256).max);
        uint256 t = _mint(alice, address(nr), 1_000e6);
        vm.prank(alice);
        vault.topUpReserve(BASKET, address(nr), 100e6);
        uint256 out = _redeem(alice, address(nr), t);
        assertEq(out, 828_340_833);
        assertEq(nr.balanceOf(address(vault)), vault.reserves(BASKET, address(nr)) + vault.accruedFees(address(nr)));
        assertEq((nr.balanceOf(treasury) + vault.accruedFees(address(nr))), 3e6 + 2_492_500);
    }

    function test_FeeOnTransferToken() public {
        FeeOnTransferStable fot = new FeeOnTransferStable(100); // 1% за перевод
        _addStableViaTimelock(address(fot));
        _fund(address(fot));
        uint256 t = _mint(alice, address(fot), 1_000e6);
        // получено 990, комиссия протокола от 990
        uint256 received = 990e6;
        assertEq(vault.reserves(BASKET, address(fot)), received - _ceilFee(received));
        assertEq(t, ((received - _ceilFee(received)) * 1e12 * 10_000) / 12_000);
        assertGe(fot.balanceOf(address(vault)), vault.reserves(BASKET, address(fot)) + vault.accruedFees(address(fot)));
        vm.prank(alice);
        vault.topUpReserve(BASKET, address(fot), 100e6);
        assertEq(vault.reserves(BASKET, address(fot)), received - _ceilFee(received) + 99e6);
        uint256 balBefore = fot.balanceOf(alice);
        uint256 out = _redeem(alice, address(fot), t);
        assertEq(fot.balanceOf(alice) - balBefore, out - out / 100, "user receives minus token fee");
        assertGe(fot.balanceOf(address(vault)), vault.reserves(BASKET, address(fot)) + vault.accruedFees(address(fot)));
        // минимальный минт применяется к фактически полученной сумме
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BelowMinMint.selector, 49.5e18, 50e18));
        vault.mint(BASKET, address(fot), 50e6, 0);
    }

    function test_ReturnFalseToken_Reverts() public {
        ReturnFalseStable rf = new ReturnFalseStable();
        _addStableViaTimelock(address(rf));
        _fund(address(rf));
        uint256 t = _mint(alice, address(rf), 1_000e6);
        rf.setFail(true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(rf)));
        vault.mint(BASKET, address(rf), 1_000e6, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(rf)));
        vault.redeem(BASKET, address(rf), t, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(rf)));
        vault.topUpReserve(BASKET, address(rf), 1e6);
        vm.stopPrank();
    }

    // ------------------------------------------------ пауза: взаимодействие с депегом и SUSPENDED
    function test_Pause_WithDepeg_PauseCheckedFirst() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        vm.startPrank(owner);
        vm.stopPrank();
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.9e18);
        vm.startPrank(owner);
        vault.pause();
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(BASKET, address(usdt), 100e6, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(BASKET, address(usdt), t, 0);
        vm.stopPrank();
        vm.prank(owner);
        vault.unpause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StableDepegged.selector, address(usdt), 0.9e18));
        vault.redeem(BASKET, address(usdt), t, 0);
    }

    function test_Pause_WithSuspended_TopUpDuringPauseRestores() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        vm.warp(T_OCT28);
        vm.startPrank(owner);
        vault.setIndex(BASKET, 1.1e18);
        vault.pause();
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(BASKET, address(usdt), t, 0);
        vm.prank(owner);
        vault.unpause();
        uint256 cov = _cov();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.RedemptionSuspended.selector, BASKET, cov, 11_500));
        vault.redeem(BASKET, address(usdt), t, 0);
        vm.warp(block.timestamp + vault.PAUSE_COOLDOWN()); // новая пауза — только после кулдауна
        vm.prank(owner);
        vault.pause();
        _expectTier(BASKET, BasketVault.RedeemTier.Suspended, BasketVault.RedeemTier.Standard);
        _topUpTo(12_000, address(usdc)); // topUp работает на паузе и меняет уровень
        assertFalse(vault.quoteRedeem(BASKET, address(usdt), t).executableNow);
        vm.prank(owner);
        vault.unpause();
        assertTrue(vault.quoteRedeem(BASKET, address(usdt), t).executableNow);
        _redeem(alice, address(usdt), t);
    }

    function test_Pause_OwnerConfigStillWorks_AndDoublePauseReverts() public {
        vm.startPrank(owner);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vm.stopPrank();
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.99e18);
        vm.startPrank(owner);
        vault.setWorkingPrice(BASKET, 1.01e18);
        vault.setMinMintUsd(100e18);
        vault.unpause();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
        vm.stopPrank();
    }

    // ------------------------------------------------ несколько корзин с общим стейблом
    function test_MultiBasket_ReserveIsolation() public {
        BasketToken eur = new BasketToken("BasketCoin EUR", "BKT-EUR", owner);
        vm.startPrank(owner);
        eur.grantRole(eur.MINTER_ROLE(), address(vault));
        vault.addBasket(2, eur, 1.08e18);
        vm.stopPrank();

        uint256 t1 = _mint(alice, address(usdt), 10_000e6);
        vm.prank(bob);
        uint256 t2 = vault.mint(2, address(usdt), 100e6, 0);
        assertEq(vault.reserves(2, address(usdt)), 100e6 - 300_000);

        // топ-ап корзины 1 не влияет на корзину 2
        uint256 cov2 = vault.collateralRatioBps(2);
        _topUpTo(15_000, address(usdc));
        assertEq(vault.collateralRatioBps(2), cov2);
        assertEq(uint256(vault.redeemTier(2)), uint256(BasketVault.RedeemTier.Standard));

        // в корзине 2 нельзя забрать больше её собственного резерва USDT
        vm.prank(bob);
        uint256 out2 = vault.redeem(2, address(usdt), t2, 0);
        assertLe(out2, 100e6);
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.InsufficientReserve.selector);
        vault.redeem(2, address(usdc), 1e18, 0); // резерв USDC в корзине 2 = 0
        // токены корзины 1 нельзя сжечь через корзину 2
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(2, address(usdt), t1 / 1000, 0);
        // резерв корзины 1 не тронут
        assertEq(vault.reserves(BASKET, address(usdt)), 10_000e6 - 30e6);
    }

    function test_MultiBasket_StablePriceChangeSyncsAllBaskets() public {
        BasketToken eur = new BasketToken("BasketCoin EUR", "BKT-EUR", owner);
        vm.startPrank(owner);
        eur.grantRole(eur.MINTER_ROLE(), address(vault));
        vault.addBasket(2, eur, 1e18);
        vm.stopPrank();
        _mint(alice, address(usdt), 1_000e6);
        vm.prank(bob);
        vault.mint(2, address(usdt), 1_000e6, 0);
        _expectTier(BASKET, BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Suspended);
        _expectTier(2, BasketVault.RedeemTier.Standard, BasketVault.RedeemTier.Suspended);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.955e18);
    }

    function test_VaultWithoutMinterRole_Reverts() public {
        BasketToken x = new BasketToken("X", "X", owner);
        vm.prank(owner);
        vault.addBasket(9, x, 1e18);
        vm.prank(alice);
        vm.expectRevert(); // AccessControlUnauthorizedAccount(vault, MINTER_ROLE)
        vault.mint(9, address(usdt), 100e6, 0);
    }

    function test_Redeem_MoreThanBalance() public {
        uint256 t = _mint(alice, address(usdt), 1_000e6);
        _mint(bob, address(usdt), 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, t, t + 1));
        vault.redeem(BASKET, address(usdt), t + 1, 0);
    }

    function test_Slippage_MintAndRedeem_ExactArgs() public {
        uint256 exp = vault.previewMint(BASKET, address(usdt), 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.Slippage.selector, exp, exp + 1));
        vault.mint(BASKET, address(usdt), 1_000e6, exp + 1);
        vm.prank(alice);
        assertEq(vault.mint(BASKET, address(usdt), 1_000e6, exp), exp); // ровно minOut — проходит
        (uint256 out,) = vault.previewRedeem(BASKET, address(usdt), exp);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.Slippage.selector, out, out + 1));
        vault.redeem(BASKET, address(usdt), exp, out + 1);
        vm.prank(alice);
        assertEq(vault.redeem(BASKET, address(usdt), exp, out), out);
    }
}
