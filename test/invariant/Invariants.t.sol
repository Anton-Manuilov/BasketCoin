// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Mode} from "../utils/V4Mode.sol";
import {Test, console} from "forge-std/Test.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockStable, MockFeed} from "../mocks/Mocks.sol";
import {VaultHandler} from "./Handler.sol";

abstract contract InvariantBase is Test {
    BasketVault vault;
    BasketToken[2] toks;
    address[] stables;
    MockFeed feed;
    address owner = makeAddr("anton");
    address treasury = makeAddr("treasury");
    address[] actors;
    VaultHandler handler;

    function _deploy(bool ownerPriceMoves, bool topUps) internal {
        vm.warp(1792368000); // 2026-10-19
        MockStable usdt = new MockStable("Tether USD", "USDT", 6);
        MockStable usdc = new MockStable("USD Coin", "USDC", 6);
        MockStable dai = new MockStable("Dai", "DAI", 18);
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
        feed = new MockFeed(8, 1e8);
        toks[0] = new BasketToken("BasketCoin", "BKT", owner);
        toks[1] = new BasketToken("BasketCoin EUR", "BKT-EUR", owner);
        vm.startPrank(owner);
        toks[0].grantRole(toks[0].MINTER_ROLE(), address(vault));
        toks[1].grantRole(toks[1].MINTER_ROLE(), address(vault));
        vault.addBasket(1, toks[0], 1e18);
        vault.addBasket(2, toks[1], 1.08e18);
        vm.stopPrank();
        vm.prank(address(vault));
        vault.setStableFeed(address(usdc), IAggregatorV3(address(feed)), 1 days);
        vm.startPrank(owner);
        vault.proposeStable(address(dai), IAggregatorV3(address(0)), 0);
        vm.warp(block.timestamp + 9 days);
        vault.executeStable(address(dai));
        vm.stopPrank();
        stables.push(address(usdt));
        stables.push(address(usdc));
        stables.push(address(dai));

        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(owner); // владелец тоже может минтить/выкупать/пополнять
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < stables.length; ++j) {
                MockStable s = MockStable(stables[j]);
                s.mint(actors[i], 1e12 * 10 ** s.decimals());
                vm.prank(actors[i]);
                s.approve(address(vault), type(uint256).max);
            }
        }
        handler = new VaultHandler(vault, toks, stables, feed, owner, treasury, actors, ownerPriceMoves, topUps);
        targetContract(address(handler));
    }

    function _tierOf(uint256 c) internal pure returns (BasketVault.RedeemTier) {
        if (c >= 14_000) return BasketVault.RedeemTier.Full;
        if (c >= 11_500) return BasketVault.RedeemTier.Standard;
        return BasketVault.RedeemTier.Suspended;
    }

    /// Пишет статистику прогона в invariant-stats/<tag>.csv (агрегируется скриптом после запуска).
    function _printStats(string memory tag) internal {
        string memory path = string.concat("invariant-stats/", tag, ".csv");
        uint256 totalCalls;
        uint256 totalOk;
        for (uint256 i; i < handler.actionCount(); ++i) {
            string memory n = handler.actionNames(i);
            uint256 c = handler.calls(n);
            uint256 s = handler.successes(n);
            totalCalls += c;
            totalOk += s;
            vm.writeLine(path, string.concat(n, ",", vm.toString(c), ",", vm.toString(s)));
            bytes4[] memory sels = handler.seenSelectors(n);
            for (uint256 k; k < sels.length; ++k) {
                vm.writeLine(
                    path,
                    string.concat(
                        "reason:",
                        n,
                        ":",
                        vm.toString(bytes32(sels[k])),
                        ",",
                        vm.toString(handler.revertCount(n, sels[k])),
                        ",0"
                    )
                );
            }
        }
        vm.writeLine(
            path, string.concat("metric:indexUpdatesChecked,", vm.toString(handler.indexUpdatesChecked()), ",0")
        );
        vm.writeLine(
            path, string.concat("metric:indexLimitRejections,", vm.toString(handler.indexLimitRejections()), ",0")
        );
        console.log(tag, "run calls/ok:", totalCalls, totalOk);
    }
}

/// Полный профиль: пользователи + все действия владельца (цены, индекс, пауза, warp, пополнение).
contract VaultInvariants is InvariantBase {
    function setUp() public {
        _deploy(true, true);
    }

    /// 1. Баланс каждого стейбла на Vault >= сумма учтённых резервов по всем корзинам.
    function invariant_BalanceCoversReserves() public view {
        for (uint256 j; j < stables.length; ++j) {
            uint256 sum = vault.reserves(1, stables[j]) + vault.reserves(2, stables[j]) + vault.accruedFees(stables[j]);
            assertGe(MockStable(stables[j]).balanceOf(address(vault)), sum);
        }
    }

    /// 1b. Для стандартных токенов (без комиссии за перевод) — строгое равенство: нет «зависших» средств.
    function invariant_BalanceEqualsReserves() public view {
        for (uint256 j; j < stables.length; ++j) {
            uint256 sum = vault.reserves(1, stables[j]) + vault.reserves(2, stables[j]) + vault.accruedFees(stables[j]);
            assertEq(MockStable(stables[j]).balanceOf(address(vault)), sum);
        }
    }

    /// 2. totalSupply = Σ минтов − Σ выкупов (ghost), по каждой корзине.
    function invariant_SupplyMatchesGhost() public view {
        for (uint256 k; k < 2; ++k) {
            uint256 id = k + 1;
            assertEq(toks[k].totalSupply(), handler.ghostMinted(id) - handler.ghostBurned(id));
        }
    }

    /// 3. Выкуп никогда не проходит при покрытии < 115%.
    function invariant_NoRedeemBelow115() public view {
        assertEq(handler.vRedeemBelowMin(), 0);
    }

    /// 4. Выкуп не снижает покрытие оставшихся держателей.
    function invariant_RedeemNeverLowersCoverage() public view {
        assertEq(handler.vRedeemLoweredCoverage(), 0);
    }

    /// 5. Минт при цене стейбла <= $1 не опускает покрытие ниже min(предыдущее, 120%).
    function invariant_MintKeepsCoverageFloor() public view {
        assertEq(handler.vMintBelowFloor(), 0);
    }

    /// 7. Комиссии в казне = ghost-сумма (ghost считается независимо: ceil(0,3%) от суммы минта / gross выкупа).
    function invariant_FeesMatchGhost() public view {
        for (uint256 j; j < stables.length; ++j) {
            assertEq(
                MockStable(stables[j]).balanceOf(treasury) + vault.accruedFees(stables[j]),
                handler.ghostFees(stables[j])
            );
        }
    }

    /// 8. Пока пауза — ни один минт/выкуп не прошёл.
    function invariant_NothingWhilePaused() public view {
        assertEq(handler.vSuccessWhilePaused(), 0);
    }

    /// 9. Депег стейбла — ни один минт/выкуп по нему не прошёл.
    function invariant_NothingWhileDepegged() public view {
        assertEq(handler.vSuccessWhileDepegged(), 0);
    }

    /// 11. Каждое прошедшее обновление индекса — в пределах ±11% от предыдущего; отказ по лимиту
    ///     бывает только за пределами ±11% и не расходует попытку месяца.
    function invariant_IndexChangeWithinLimit() public view {
        assertEq(handler.vIndexChangeOutOfLimit(), 0, "setIndex beyond +-11% succeeded");
        assertEq(handler.vIndexWrongfullyRejected(), 0, "in-limit setIndex rejected");
        assertEq(handler.vIndexAttemptBurned(), 0, "rejected attempt burned the month");
    }

    /// 10. Уровень всегда соответствует покрытию (redeemTier и сохранённый lastTier).
    function invariant_TierMatchesCoverage() public view {
        for (uint256 id = 1; id <= 2; ++id) {
            BasketVault.RedeemTier expected = _tierOf(vault.collateralRatioBps(id));
            assertEq(uint256(vault.redeemTier(id)), uint256(expected));
            assertEq(uint256(vault.lastTier(id)), uint256(expected));
        }
    }

    function afterInvariant() external {
        _printStats("full");
    }
}

/// Профиль без внешнего пополнения и без смены индекса/рабочей цены (цены стейблов, пауза, warp — да).
/// 6. Ни один актор не выходит в плюс циклом минт→выкуп (в единицах стейблов, нормировано к 18 знакам).
contract NoProfitInvariants is InvariantBase {
    function setUp() public {
        _deploy(false, false);
        // Отключённые в этом профиле действия не выбираются вовсе (иначе ~1/3 вызовов — пустые).
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = VaultHandler.mint.selector;
        sel[1] = VaultHandler.redeem.selector;
        sel[2] = VaultHandler.setManualPrice.selector;
        sel[3] = VaultHandler.setFeedPrice.selector;
        sel[4] = VaultHandler.togglePause.selector;
        sel[5] = VaultHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function invariant_NoActorProfitsWithoutTopUp() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(handler.ghostOutNorm(actors[i]), handler.ghostInNorm(actors[i]));
        }
    }

    function invariant_BalanceCoversReserves() public view {
        for (uint256 j; j < stables.length; ++j) {
            uint256 sum = vault.reserves(1, stables[j]) + vault.reserves(2, stables[j]) + vault.accruedFees(stables[j]);
            assertGe(MockStable(stables[j]).balanceOf(address(vault)), sum);
        }
    }

    function afterInvariant() external {
        _printStats("no-profit");
    }
}
