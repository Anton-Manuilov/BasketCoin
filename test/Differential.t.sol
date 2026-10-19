// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {DateLib} from "../src/libraries/DateLib.sol";
import {MockStable} from "./mocks/Mocks.sol";

/// Дифференциальные тесты округлений против эталона на Math.mulDiv и fuzz на переполнения.
contract DifferentialRoundingTest is BaseTest {
    MockStable s8;
    MockStable s18;

    function setUp() public override {
        super.setUp();
        s8 = new MockStable("S8", "S8", 8);
        s18 = new MockStable("S18", "S18", 18);
        _addStableViaTimelock(address(s8));
        _addStableViaTimelock(address(s18));
    }

    function _pickStable(uint256 seed) internal view returns (address st, uint256 dec) {
        uint256 k = seed % 3;
        if (k == 0) return (address(usdt), 6);
        if (k == 1) return (address(s8), 8);
        return (address(s18), 18);
    }

    /// Индекс корзины = p. С v0.4 setIndex ограничен ±11% за обновление, поэтому для проверки
    /// математики на произвольных индексах (1 wei .. 1e36) разворачивается свежий Vault, где корзина
    /// создаётся сразу с индексом p (стартовый индекс лимитом не ограничен). Вызывать в начале теста.
    function _setIndex(uint256 p) internal {
        vault = new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18);
        coin = new BasketToken("BasketCoin", "BKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(BASKET, coin, p);
        vm.stopPrank();
        _fund(address(usdt));
        _fund(address(usdc));
        _addStableViaTimelock(address(s8));
        _addStableViaTimelock(address(s18));
        assertEq(_idx(BASKET), p);
        assertEq(_wp(BASKET), p);
    }

    /// Минт: результат Vault == эталон одной точной делёжкой floor(net*scale*min(p,1)*1e4 / (P*12000)).
    /// Vault считает одной операцией mulDiv — совпадение должно быть точным.
    function testFuzz_Diff_MintMatchesReference(uint256 seed, uint256 amountUsd, uint256 pBps, uint256 index)
        public
    {
        (address st, uint256 dec) = _pickStable(seed);
        amountUsd = bound(amountUsd, 50, 1e15); // $50 .. $1e15
        pBps = bound(pBps, 9_500, 10_500);
        index = bound(index, 1e6, 1e30);
        _setIndex(index);
        vm.prank(owner);
        vault.setManualPrice(st, pBps * 1e14);
        uint256 amount = amountUsd * 10 ** dec + (seed % (10 ** dec)); // добавим «копейки»
        uint256 minP = pBps <= 10_000 ? pBps * 1e14 : 1e18;
        if (Math.mulDiv(amount * 10 ** (18 - dec), minP, 1e18) < 50e18) return;

        uint256 fee = Math.mulDiv(amount, 30, 10_000, Math.Rounding.Ceil);
        uint256 net = amount - fee;
        uint256 refTokens = Math.mulDiv(net * 10 ** (18 - dec) * minP, 10_000, index * 12_000);
        assertEq(vault.previewMint(BASKET, st, amount), refTokens, "mint differs from reference");
        assertGe(fee * 10_000, amount * 30, "fee rounded up");
        assertLt((fee - 1) * 10_000, amount * 30, "fee at most +1");
    }

    /// Выкуп: Vault == точное floor(tokens*P*k / (1e4*max(p,1)*scale)) (одно округление); комиссия = ceil.
    function testFuzz_Diff_RedeemWithinOneUnitOfExact(uint256 seed, uint256 tokens, uint256 pBps, uint256 index, bool full)
        public
    {
        (address st, uint256 dec) = _pickStable(seed);
        tokens = bound(tokens, 1e12, 1e30);
        pBps = bound(pBps, 9_500, 10_500);
        index = bound(index, 1e9, 1e24);
        _setIndex(index);
        // корзина с огромным резервом, чтобы уровень FULL/STANDARD задавался флагом
        MockStable(st).mint(owner, type(uint128).max);
        vm.prank(owner);
        MockStable(st).approve(address(vault), type(uint256).max);
        vm.prank(address(vault));
        coin.mint(alice, tokens); // эмулируем выпуск (vault — минтер)
        vm.prank(owner);
        vault.setManualPrice(st, pBps * 1e14);
        uint256 usdValue = Math.mulDiv(tokens, index, 1e18);
        if (usdValue < 1_000e18) return; // слишком мелко для точного выставления уровня
        uint256 need = usdValue * (full ? 15_000 : 13_000) / 10_000;
        _topUp(st, need / 10 ** (18 - dec));
        BasketVault.RedeemQuote memory q = vault.quoteRedeem(BASKET, st, tokens);
        assertEq(uint256(q.tier), uint256(full ? BasketVault.RedeemTier.Full : BasketVault.RedeemTier.Standard));

        uint256 k = full ? 12_000 : 10_000;
        uint256 maxP = pBps >= 10_000 ? pBps * 1e14 : 1e18;
        uint256 exact = Math.mulDiv(tokens * index, k * 1e18, 1e22 * maxP * 10 ** (18 - dec)); // = floor(t*P*k/(1e4*maxP*scale))
        uint256 gross = q.payoutNow + q.feeNow;
        assertEq(gross, exact, "equals exact floor (protocol favoured)");
        assertEq(q.feeNow, Math.mulDiv(gross, 30, 10_000, Math.Rounding.Ceil));
    }

    /// Покрытие: Vault <= точное floor(usd*1e22/(P*supply)), отличие не более 1 bps.
    function testFuzz_Diff_CoverageWithinOneBps(uint256 amount, uint256 extra, uint256 index) public {
        amount = bound(amount, 50e6, 1e15 * 1e6);
        extra = bound(extra, 0, 1e15 * 1e6);
        index = bound(index, 1e12, 1e24);
        _setIndex(index);
        usdt.mint(alice, amount);
        usdc.mint(owner, extra);
        _mint(alice, address(usdt), amount);
        _topUp(address(usdc), extra);
        uint256 usd = (vault.reserves(BASKET, address(usdt)) + vault.reserves(BASKET, address(usdc))) * 1e12;
        uint256 exact = Math.mulDiv(usd, 1e22, index * coin.totalSupply());
        uint256 c = _cov();
        assertLe(c, exact);
        assertLe(exact - c, 1);
    }

    /// Переполнения: крайние суммы и цены не должны давать Panic(0x11) — только осмысленные ошибки.
    function testFuzz_NoOverflowPanicAtExtremes(uint256 amount, uint256 index, uint256 pBps, uint256 redeemFrac)
        public
    {
        amount = bound(amount, 50e18, 1e40); // 18 знаков, до 1e22 «долларов»
        index = bound(index, 1, 1e36);
        _setIndex(index);
        pBps = bound(pBps, 9_500, 10_500);
        redeemFrac = bound(redeemFrac, 1, 10_000);
        s18.mint(alice, amount);
        vm.prank(alice);
        s18.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        vault.setManualPrice(address(s18), pBps * 1e14);

        uint256 t;
        vm.prank(alice);
        try vault.mint(BASKET, address(s18), amount, 0) returns (uint256 out) {
            t = out;
        } catch (bytes memory err) {
            _assertNotPanic(err);
            return;
        }
        vault.collateralRatioBps(BASKET);
        vault.quoteRedeem(BASKET, address(s18), t);
        vm.prank(alice);
        try vault.redeem(BASKET, address(s18), (t * redeemFrac) / 10_000, 0) {}
        catch (bytes memory err) {
            _assertNotPanic(err);
        }
    }

    function _assertNotPanic(bytes memory err) internal pure {
        bytes4 panic = bytes4(keccak256("Panic(uint256)"));
        assertTrue(err.length < 4 || bytes4(err) != panic, "arithmetic panic");
    }
}

/// Эталонная реализация (BokkyPooBah's DateTime Library, алгоритм Fliegel–Van Flandern) для сравнения.
library RefDate {
    int256 constant OFFSET19700101 = 2440588;

    function daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(_days);
        int256 L = __days + 68569 + OFFSET19700101;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;
        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    function daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);
        int256 __days = _day - 32075 + (1461 * (_year + 4800 + (_month - 14) / 12)) / 4
            + (367 * (_month - 2 - ((_month - 14) / 12) * 12)) / 12
            - (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) / 4 - OFFSET19700101;
        return uint256(__days);
    }
}

contract DateLibDifferentialTest is Test {
    function _isLeap(uint256 y) internal pure returns (bool) {
        return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    }

    function _daysInMonth(uint256 y, uint256 m) internal pure returns (uint256) {
        if (m == 2) return _isLeap(y) ? 29 : 28;
        if (m == 4 || m == 6 || m == 9 || m == 11) return 30;
        return 31;
    }

    /// Fuzz: 1970..9999 — совпадение с эталоном и обратное преобразование.
    function testFuzz_DateLib_MatchesReference(uint256 ts) public pure {
        ts = bound(ts, 0, 253402300799); // 9999-12-31 23:59:59
        (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(ts);
        (uint256 ry, uint256 rm, uint256 rd) = RefDate.daysToDate(ts / 86400);
        assertEq(y, ry);
        assertEq(m, rm);
        assertEq(d, rd);
        assertEq(RefDate.daysFromDate(y, m, d), ts / 86400, "round trip");
    }

    /// Полный перебор каждого дня 1970-01-01 .. 2200-12-31: дата следующего дня — корректный «преемник».
    function test_DateLib_DailySweep_1970_2200() public pure {
        (uint256 py, uint256 pm, uint256 pd) = DateLib.timestampToDate(0);
        assertEq(py, 1970);
        assertEq(pm, 1);
        assertEq(pd, 1);
        uint256 lastDay = RefDate.daysFromDate(2200, 12, 31);
        for (uint256 day = 1; day <= lastDay; ++day) {
            (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(day * 86400 + 43200);
            if (pd < _daysInMonth(py, pm)) {
                assertTrue(y == py && m == pm && d == pd + 1);
            } else if (pm < 12) {
                assertTrue(y == py && m == pm + 1 && d == 1);
            } else {
                assertTrue(y == py + 1 && m == 1 && d == 1);
            }
            (py, pm, pd) = (y, m, d);
        }
        assertEq(py, 2200);
        assertEq(pm, 12);
        assertEq(pd, 31);
    }

    /// Каждое 28-е число 1970..2200: ровно 12 в году; 00:00:00 и 23:59:59 — 28-е.
    function test_DateLib_Every28th() public pure {
        for (uint256 y = 1970; y <= 2200; ++y) {
            for (uint256 m = 1; m <= 12; ++m) {
                uint256 ts = RefDate.daysFromDate(y, m, 28) * 86400;
                (,, uint256 d0) = DateLib.timestampToDate(ts);
                (,, uint256 d1) = DateLib.timestampToDate(ts + 86399);
                (,, uint256 dPrev) = DateLib.timestampToDate(ts - 1);
                (,, uint256 dNext) = DateLib.timestampToDate(ts + 86400);
                assertEq(d0, 28);
                assertEq(d1, 28);
                assertEq(dPrev, 27);
                assertEq(dNext, 29 <= _daysInMonth(y, m) ? 29 : 1);
            }
        }
    }
}
