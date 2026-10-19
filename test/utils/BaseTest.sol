// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockStable} from "../mocks/Mocks.sol";
import {DateLib} from "../../src/libraries/DateLib.sol";

/// Общая база для unit-тестов: Vault, корзина 1, USDT/USDC (6 знаков), акторы с балансами.
abstract contract BaseTest is Test {
    uint256 internal constant T_OCT19 = 1792368000; // 2026-10-19 00:00:00 UTC
    uint256 internal constant T_OCT27_END = 1793145599; // 2026-10-27 23:59:59
    uint256 internal constant T_OCT28 = 1793145600; // 2026-10-28 00:00:00
    uint256 internal constant T_OCT28_END = 1793231999; // 2026-10-28 23:59:59
    uint256 internal constant T_OCT29 = 1793232000; // 2026-10-29 00:00:00
    uint256 internal constant T_NOV28 = 1795824000; // 2026-11-28 00:00:00
    uint256 internal constant T_DEC28_NOON = 1798459200; // 2026-12-28 12:00:00
    uint256 internal constant T_JAN28_2027 = 1801094400; // 2027-01-28 00:00:00
    uint256 internal constant T_FEB28_2027 = 1803772800; // 2027-02-28 00:00:00
    uint256 internal constant T_FEB28_2028 = 1835308800; // 2028-02-28 00:00:00 (високосный год)
    uint256 internal constant T_FEB29_2028 = 1835395200; // 2028-02-29 00:00:00
    uint256 internal constant T_MAR28_2028 = 1837814400; // 2028-03-28 00:00:00
    uint256 internal constant BASKET = 1;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockStable internal usdt;
    MockStable internal usdc;
    BasketToken internal coin;
    BasketVault internal vault;

    function setUp() public virtual {
        vm.warp(T_OCT19);
        usdt = new MockStable("Tether USD", "USDT", 6);
        usdc = new MockStable("USD Coin", "USDC", 6);
        vault = new BasketVault(owner, treasury, address(usdt), address(usdc), 50e18);
        coin = new BasketToken("BasketCoin", "BSKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(BASKET, coin, 1e18);
        vm.stopPrank();
        _fund(address(usdt));
        _fund(address(usdc));
    }

    function _fund(address stable) internal {
        address[4] memory users = [alice, bob, carol, owner];
        uint256 unit = 10 ** MockStable(stable).decimals();
        for (uint256 i; i < users.length; ++i) {
            MockStable(stable).mint(users[i], 100_000_000 * unit);
            vm.prank(users[i]);
            MockStable(stable).approve(address(vault), type(uint256).max);
        }
    }

    /// Добавляет стейбл через таймлок 9 дней (с warp) и раздаёт балансы.
    function _addStableViaTimelock(address stable) internal {
        vm.prank(owner);
        vault.proposeStable(stable, IAggregatorV3(address(0)), 0);
        vm.warp(vm.getBlockTimestamp() + 9 days);
        vm.prank(owner);
        vault.executeStable(stable);
    }

    function _mint(address u, address stable, uint256 amount) internal returns (uint256) {
        vm.prank(u);
        return vault.mint(BASKET, stable, amount, 0);
    }

    function _redeem(address u, address stable, uint256 tokens) internal returns (uint256) {
        vm.prank(u);
        return vault.redeem(BASKET, stable, tokens, 0);
    }

    function _cov() internal view returns (uint256) {
        return vault.collateralRatioBps(BASKET);
    }

    function _tier() internal view returns (BasketVault.RedeemTier) {
        return vault.redeemTier(BASKET);
    }

    function _wp(uint256 basketId) internal view returns (uint256 wp) {
        (,, wp,,,) = vault.baskets(basketId);
    }

    function _idx(uint256 basketId) internal view returns (uint256 idx) {
        (, idx,,,,) = vault.baskets(basketId);
    }

    /// Минимальная добавка в `stable` (цена >= $1, decimals dec), при которой покрытие корзины 1 >= target.
    /// Предполагает, что все стейблы с резервом в корзине стоят >= $1 (оценка по $1).
    function _minExtraFor(uint256 target, address stable) internal view returns (uint256) {
        uint256 supply = coin.totalSupply();
        uint256 p = _wp(BASKET);
        // cov = floor(floor(usd*1e18/P) * BPS / supply) >= target
        uint256 tokensNeeded = (target * supply + 9_999) / 10_000; // ceil
        uint256 usdNeeded = (tokensNeeded * p + 1e18 - 1) / 1e18; // ceil
        uint256 cur;
        for (uint256 i; i < vault.stableCount(); ++i) {
            address st = vault.stableList(i);
            (, uint8 d,,,) = vault.stables(st);
            cur += vault.reserves(BASKET, st) * 10 ** (18 - d);
        }
        if (usdNeeded <= cur) return 0;
        (, uint8 dec,,,) = vault.stables(stable);
        uint256 scale = 10 ** (18 - dec);
        return (usdNeeded - cur + scale - 1) / scale;
    }

    function _topUp(address stable, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(owner);
        vault.topUpReserve(BASKET, stable, amount);
    }

    function _topUpTo(uint256 target, address stable) internal {
        _topUp(stable, _minExtraFor(target, stable));
    }

    function _expectTier(uint256 basketId, BasketVault.RedeemTier oldT, BasketVault.RedeemTier newT) internal {
        vm.expectEmit(true, true, true, false, address(vault));
        emit BasketVault.CoverageTierChanged(basketId, oldT, newT, 0);
    }

    /// Переход на ближайшее 28-е число (UTC) месяца, в котором индекс корзины ещё не обновлялся.
    function _warpToNextIndexDay(uint256 basketId) internal {
        (,,, uint256 lastKey,,) = vault.baskets(basketId);
        while (true) {
            (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(vm.getBlockTimestamp());
            if (d == 28 && y * 12 + (m - 1) != lastKey) return;
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
    }

    /// Довести индекс корзины до target по правилам v0.4: по одному обновлению в месяц (28-го),
    /// каждое — не дальше ±11% от предыдущего (берётся граница из indexBounds). Возвращает число месяцев.
    function _setIndexStepwise(uint256 basketId, uint256 target) internal returns (uint256 steps) {
        while (_idx(basketId) != target || steps == 0) {
            _warpToNextIndexDay(basketId);
            (uint256 lo, uint256 hi) = vault.indexBounds(basketId);
            uint256 next = target < lo ? lo : (target > hi ? hi : target);
            vm.prank(owner);
            vault.setIndex(basketId, next);
            ++steps;
        }
    }

    function _ceilFee(uint256 x) internal pure returns (uint256) {
        return (x * 30 + 9_999) / 10_000;
    }
}
