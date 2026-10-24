// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Mode} from "./utils/V4Mode.sol";
import {Test, console2} from "forge-std/Test.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockStable} from "./mocks/Mocks.sol";

/// Запасная логика при отказе лимитера минта (лимиты выключены через vm.store, как будто обойдены/сломаны).
/// Проверяем: выкуп не ниже P*0,997 в STANDARD, SUSPENDED (<115%), гонки на границах, депег, setIndex, пауза.
contract FallbackV5Test is Test {
    uint256 constant T_OCT19 = 1792368000;
    uint256 constant T_OCT28 = 1793145600;
    uint256 constant T_NOV28 = 1795824000;
    uint256 constant B = 1;
    address owner = makeAddr("anton");
    address treasury = makeAddr("treasury");
    address[10] users;
    MockStable usdt;
    MockStable usdc;
    BasketToken coin;
    BasketVault vault;

    function setUp() public {
        vm.warp(T_OCT19);
        usdt = new MockStable("Tether USD", "USDT", 6);
        usdc = new MockStable("USD Coin", "USDC", 6);
        vault = new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18, owner, address(0));
        V4Mode.disableMintLimits(address(vault)); // лимитер «сломан»
        coin = new BasketToken("BasketCoin", "BKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(B, coin, 1e18);
        vm.stopPrank();
        for (uint256 i; i < 10; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("u", vm.toString(i))));
            _fund(users[i]);
        }
        _fund(owner);
        // 10 вкладчиков по $10 000 (покрытие 120% — минт без лимитов)
        for (uint256 i; i < 10; ++i) {
            vm.prank(users[i]);
            vault.mint(B, address(usdt), 10_000e6, 0);
        }
    }

    function _fund(address u) internal {
        usdt.mint(u, 100_000_000e6);
        usdc.mint(u, 100_000_000e6);
        vm.startPrank(u);
        usdt.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _cov() internal view returns (uint256) { return vault.collateralRatioBps(B); }
    function _P() internal view returns (uint256 wp) { (,, wp,,,) = vault.baskets(B); }

    function _topUpTo(uint256 target) internal {
        uint256 needUsd = (target * coin.totalSupply() * _P() + 1e22 - 1) / 1e22;
        uint256 cur = (vault.reserves(B, address(usdt)) + vault.reserves(B, address(usdc))) * 1e12;
        if (needUsd <= cur) return;
        vm.prank(owner);
        vault.topUpReserve(B, address(usdc), (needUsd - cur + 1e12 - 1) / 1e12);
    }

    /// выкуп; возвращает выплату за 1 токен в USD 18 знаков (0 = revert)
    function _redeem(address u, address st, uint256 amt) internal returns (uint256 perToken, bool ok) {
        uint256 c0 = _cov();
        vm.prank(u);
        try vault.redeem(B, st, amt, 0) returns (uint256 out) {
            perToken = out * 1e12 * 1e18 / amt;
            ok = true;
        } catch {}
        console2.log("  redeem cov_before", c0, "per_token_e6", perToken / 1e12);
        console2.log("    ok", ok, "cov_after", _cov());
    }

    function _assertSolvent() internal view {
        uint256 r = vault.reserves(B, address(usdt)) + vault.reserves(B, address(usdc));
        assertLe(r, usdt.balanceOf(address(vault)) + usdc.balanceOf(address(vault)), "reserve > balance");
    }

    // (1) ниже 140%: выкуп по P*0,997
    function test_F1_below140_redeemAtP() public {
        _topUpTo(13_000);
        assertEq(uint256(vault.redeemTier(B)), 1, "STANDARD");
        (uint256 pt, bool ok) = _redeem(users[0], address(usdt), 100e18);
        assertTrue(ok);
        assertGe(pt, _P() * 997 / 1000 - 1e12, "< P*0.997");
        assertLt(pt, _P() * 1200 / 1000 * 997 / 1000, "must not pay 1.2P");
        _assertSolvent();
    }

    // (2) SUSPENDED: setIndex +11% дважды при 120% -> 108% -> 97%; выкуп откатывается; минт?
    function test_F2_suspended_mintAndRecovery() public {
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(B, 1.11e18);
        console2.log("cov after setIndex+11% (Oct28)", _cov(), "tier", uint256(vault.redeemTier(B)));
        assertEq(uint256(vault.redeemTier(B)), 0, "SUSPENDED");
        (, bool ok) = _redeem(users[1], address(usdt), 100e18);
        assertFalse(ok, "redeem must revert in SUSPENDED");
        (,,,, uint256 rem,) = _quote(users[1]);
        rem;
        // минт в SUSPENDED при выключенном лимитере
        uint256 c0 = _cov();
        vm.prank(users[2]);
        try vault.mint(B, address(usdt), 10_000e6, 0) returns (uint256 t) {
            console2.log("MINT in SUSPENDED: ok, tokens", t / 1e18, "cov", _cov());
        } catch { console2.log("MINT in SUSPENDED: revert"); }
        assertGe(_cov(), c0, "mint must not lower coverage below 120 when below 120");
        // восстановление казной
        _topUpTo(14_100);
        assertEq(uint256(vault.redeemTier(B)), 2, "FULL after topUp");
        (uint256 pt, bool ok2) = _redeem(users[1], address(usdt), 100e18);
        assertTrue(ok2);
        assertGe(pt, _P() * 997 / 1000);
        _assertSolvent();
    }

    function _quote(address) internal pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, 0);
    }

    // (2b) с включёнными лимитами (как в контракте) минт в SUSPENDED/ниже пола откатывается
    function test_F2b_suspended_mintWithLimiterOn() public {
        vm.store(address(vault), bytes32(uint256(17)), bytes32(uint256(15000) | (uint256(16000) << 32) | (uint256(1000) << 64) | (uint256(500) << 96)));
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(B, 1.11e18);
        vm.prank(users[2]);
        vm.expectRevert();
        vault.mint(B, address(usdt), 1_000e6, 0);
    }

    // (3a) массовый выкуп/гонка: старт 141% (FULL), все 10 вкладчиков выходят по очереди
    function test_F3a_bankRun_fromFULL() public {
        _topUpTo(14_100);
        uint256 minPt = type(uint256).max;
        uint256 stuck;
        for (uint256 i; i < 10; ++i) {
            uint256 bal = coin.balanceOf(users[i]);
            (uint256 pt, bool ok) = _redeem(users[i], address(usdt), bal);
            if (!ok) { stuck++; continue; }
            if (pt < minPt) minPt = pt;
            _assertSolvent();
        }
        console2.log("bank run: min payout per token e6", minPt / 1e12, "stuck holders", stuck);
        assertGe(minPt, _P() * 997 / 1000 - 1e12, "someone got < P*0.997");
    }

    // (3b) гонка у границы 140%: один крупный выкуп в FULL сразу перед сменой режима
    function test_F3b_race_at140() public {
        _topUpTo(14_001);
        (uint256 ptWhale,) = _redeem(users[0], address(usdt), coin.balanceOf(users[0]));
        (uint256 ptNext,) = _redeem(users[1], address(usdt), coin.balanceOf(users[1]));
        console2.log("whale e6", ptWhale / 1e12, "next e6", ptNext / 1e12);
        // остальным должно хватать минимум P на токен
        uint256 r = (vault.reserves(B, address(usdt)) + vault.reserves(B, address(usdc))) * 1e12;
        console2.log("remaining coverage of P", r * 1e4 / (coin.totalSupply() * _P() / 1e18));
        assertGe(r * 1e18 / coin.totalSupply(), _P(), "remaining holders below P");
    }

    // (3c) граница 115%: выкуп в STANDARD при 115,1% не должен оставить остальных без P
    function test_F3c_race_at115() public {
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(B, 1.0434e18); // 120% / 1.0434 = 115.0x%
        console2.log("cov", _cov(), "tier", uint256(vault.redeemTier(B)));
        for (uint256 i; i < 10; ++i) _redeem(users[i], address(usdt), coin.balanceOf(users[i]));
        if (coin.totalSupply() > 0) {
            uint256 r = (vault.reserves(B, address(usdt)) + vault.reserves(B, address(usdc))) * 1e12;
            console2.log("left supply", coin.totalSupply() / 1e18, "reserve per token e6", r * 1e6 / coin.totalSupply());
        }
        _assertSolvent();
    }

    // (3d) депег USDT + низкое покрытие
    function test_F3d_depeg_lowCoverage() public {
        _topUpTo(13_000);
        vm.prank(address(vault));
        vault.setManualPrice(address(usdt), 0.94e18);
        vault.pokeTier(B);
        console2.log("depeg cov", _cov(), "tier", uint256(vault.redeemTier(B)));
        (uint256 ptT, bool okT) = _redeem(users[0], address(usdt), 100e18);
        (uint256 ptC, bool okC) = _redeem(users[1], address(usdc), 100e18);
        console2.log("usdt ok", okT, ptT / 1e12);
        console2.log("usdc ok", okC, ptC / 1e12);
        vm.prank(users[2]);
        try vault.mint(B, address(usdt), 1_000e6, 0) { console2.log("mint depegged USDT: ok"); }
        catch { console2.log("mint depegged USDT: revert"); }
        _assertSolvent();
    }

    // (3e) setIndex +11% при 145% -> STANDARD
    function test_F3e_setIndex_atLowCoverage() public {
        _topUpTo(14_500);
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(B, 1.11e18);
        console2.log("145% -> setIndex+11% -> cov", _cov(), "tier", uint256(vault.redeemTier(B)));
        assertEq(uint256(vault.redeemTier(B)), 1);
        (uint256 pt,) = _redeem(users[0], address(usdt), 100e18);
        assertGe(pt, _P() * 997 / 1000 - 1e12);
    }

    // (3f) пауза guardian + восстановление topUpReserve во время паузы
    function test_F3f_pause_and_topup() public {
        vm.warp(T_OCT28);
        vm.prank(owner);
        vault.setIndex(B, 1.11e18); // SUSPENDED
        vm.prank(owner); // guardian = owner
        vault.pause();
        vm.prank(users[0]);
        vm.expectRevert();
        vault.mint(B, address(usdt), 1_000e6, 0);
        _topUpTo(15_000); // topUp работает во время паузы
        assertEq(uint256(vault.redeemTier(B)), 2);
        vm.prank(owner);
        vault.unpause();
        (uint256 pt, bool ok) = _redeem(users[0], address(usdt), 100e18);
        assertTrue(ok);
        assertGe(pt, _P() * 1200 / 1000 * 997 / 1000 - 1e12);
    }
}
