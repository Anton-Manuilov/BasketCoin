// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {DateLib} from "../../src/libraries/DateLib.sol";
import {MockStable, MockFeed} from "../mocks/Mocks.sol";

/// Handler для stateful-fuzz: случайные действия пользователей и владельца.
/// Все вызовы Vault обёрнуты в try/catch: handler не ревертит, а считает успехи и откаты по каждому действию.
contract VaultHandler is Test {
    BasketVault public vault;
    BasketToken[2] public tokens;
    uint256[2] public basketIds = [uint256(1), uint256(2)];
    address[] public stables;
    MockFeed public feed; // фид для stables[1]
    address public owner;
    address public treasury;
    address[] public actors;
    bool public allowOwnerPriceMoves; // false — профиль «без внешнего пополнения и без смены индекса»
    bool public allowTopUp;

    // ---------------- ghost-переменные
    mapping(uint256 => uint256) public ghostMinted;
    mapping(uint256 => uint256) public ghostBurned;
    mapping(address => uint256) public ghostFees;
    mapping(address => uint256) public ghostInNorm; // внесено актором (стейблы, нормировано к 18 знакам)
    mapping(address => uint256) public ghostOutNorm; // получено актором
    uint256 public vRedeemBelowMin;
    uint256 public vRedeemLoweredCoverage;
    uint256 public vMintBelowFloor;
    uint256 public vSuccessWhilePaused;
    uint256 public vSuccessWhileDepegged;
    uint256 public vIndexChangeOutOfLimit; // прошедший setIndex дальше ±11% от предыдущего индекса
    uint256 public vIndexWrongfullyRejected; // отказ IndexChangeTooLarge при изменении в пределах ±11%
    uint256 public vIndexAttemptBurned; // после отказа по лимиту повтор в том же месяце не прошёл
    uint256 public indexUpdatesChecked; // сколько успешных setIndex проверено на лимит
    uint256 public indexLimitRejections; // сколько отказов по лимиту (с повтором в том же месяце)

    // ---------------- статистика
    string[] public actionNames;
    mapping(string => uint256) public calls;
    mapping(string => uint256) public successes;
    // причины откатов: action => selector => count
    mapping(string => mapping(bytes4 => uint256)) public revertCount;
    mapping(string => bytes4[]) internal _seenSelectors;

    function _recordRevert(string memory action, bytes memory err) internal {
        bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
        if (revertCount[action][sel] == 0) _seenSelectors[action].push(sel);
        revertCount[action][sel]++;
    }

    function seenSelectors(string memory action) external view returns (bytes4[] memory) {
        return _seenSelectors[action];
    }

    constructor(
        BasketVault v,
        BasketToken[2] memory t,
        address[] memory st,
        MockFeed f,
        address owner_,
        address treasury_,
        address[] memory actors_,
        bool ownerPriceMoves,
        bool topUps
    ) {
        vault = v;
        tokens = t;
        stables = st;
        feed = f;
        owner = owner_;
        treasury = treasury_;
        actors = actors_;
        allowOwnerPriceMoves = ownerPriceMoves;
        allowTopUp = topUps;
        actionNames = [
            "mint",
            "redeem",
            "topUp",
            "setManualPrice",
            "setFeedPrice",
            "setWorkingPrice",
            "setIndex",
            "togglePause",
            "warp"
        ];
    }

    function actionCount() external view returns (uint256) {
        return actionNames.length;
    }

    // ---------------- helpers
    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _stable(uint256 s) internal view returns (address) {
        return stables[s % stables.length];
    }

    function _basket(uint256 s) internal view returns (uint256 id, BasketToken t) {
        uint256 k = s % 2;
        return (basketIds[k], tokens[k]);
    }

    function _dec(address st) internal view returns (uint256 d) {
        (, uint8 dd,,,) = vault.stables(st);
        d = dd;
    }

    function _norm(address st, uint256 amount) internal view returns (uint256) {
        return amount * 10 ** (18 - _dec(st));
    }

    function _pokeAll() internal {
        vault.pokeTier(1);
        vault.pokeTier(2);
    }

    // ---------------- пользовательские действия
    function mint(uint256 actorSeed, uint256 basketSeed, uint256 stableSeed, uint256 usd, uint256 dust) external {
        calls["mint"]++;
        address a = _actor(actorSeed);
        address st = _stable(stableSeed);
        (uint256 id, BasketToken t) = _basket(basketSeed);
        usd = bound(usd, 1, 2_000_000);
        uint256 amount = usd * 10 ** _dec(st) + (dust % 10 ** _dec(st));
        bool paused = vault.paused();
        bool depeg = vault.isDepegged(st);
        uint256 p = vault.stablePrice(st);
        uint256 covBefore = vault.collateralRatioBps(id);
        vm.prank(a);
        try vault.mint(id, st, amount, 0) returns (uint256 out) {
            successes["mint"]++;
            ghostMinted[id] += out;
            ghostFees[st] += (amount * 30 + 9_999) / 10_000; // независимый расчёт: ceil(0,3%)
            ghostInNorm[a] += _norm(st, amount);
            if (paused) vSuccessWhilePaused++;
            if (depeg) vSuccessWhileDepegged++;
            uint256 floor_ = covBefore < 12_000 ? covBefore : 12_000;
            // покрытие в bps округляется вниз: допускаем 1 bps (точное отношение не падает ниже min(до, 120%))
            if (p <= 1e18 && vault.collateralRatioBps(id) + 1 < floor_) vMintBelowFloor++;
            assertEq(t.balanceOf(a) >= out, true);
        } catch (bytes memory err) {
            _recordRevert("mint", err);
        }
    }

    function redeem(uint256 actorSeed, uint256 basketSeed, uint256 stableSeed, uint256 fracBps) external {
        calls["redeem"]++;
        (uint256 id, BasketToken t) = _basket(basketSeed);
        // ищем актора с балансом (начиная со случайного)
        address a = _actor(actorSeed);
        for (uint256 i; i < actors.length && t.balanceOf(a) == 0; ++i) {
            a = _actor((actorSeed % actors.length) + i + 1);
        }
        uint256 bal = t.balanceOf(a);
        fracBps = bound(fracBps, 1, 10_000);
        uint256 amount = (bal * fracBps) / 10_000;
        if (amount == 0) amount = 1;
        // в 3 из 4 случаев выбираем стейбл, где выкуп исполним (если такой есть); иначе — случайный
        address st = _stable(stableSeed);
        if (stableSeed % 4 != 0) {
            for (uint256 j; j < stables.length; ++j) {
                address cand = _stable((stableSeed % stables.length) + j);
                if (vault.quoteRedeem(id, cand, amount).executableNow) {
                    st = cand;
                    break;
                }
            }
        }
        bool paused = vault.paused();
        bool depeg = vault.isDepegged(st);
        uint256 covBefore = vault.collateralRatioBps(id);
        uint256 reserveBefore = vault.reserves(id, st);
        uint256 userBal = MockStable(st).balanceOf(a);
        vm.prank(a);
        try vault.redeem(id, st, amount, 0) {
            successes["redeem"]++;
            ghostBurned[id] += amount;
            uint256 gross = reserveBefore - vault.reserves(id, st);
            ghostFees[st] += (gross * 30 + 9_999) / 10_000; // независимый расчёт: ceil(0,3% от gross)
            ghostOutNorm[a] += _norm(st, MockStable(st).balanceOf(a) - userBal);
            if (paused) vSuccessWhilePaused++;
            if (depeg) vSuccessWhileDepegged++;
            if (covBefore < 11_500) vRedeemBelowMin++;
            if (t.totalSupply() > 0 && vault.collateralRatioBps(id) < covBefore) vRedeemLoweredCoverage++;
        } catch (bytes memory err) {
            _recordRevert("redeem", err);
        }
    }

    function topUp(uint256 actorSeed, uint256 basketSeed, uint256 stableSeed, uint256 usd) external {
        if (!allowTopUp) return;
        calls["topUp"]++;
        address a = _actor(actorSeed);
        address st = _stable(stableSeed);
        (uint256 id,) = _basket(basketSeed);
        uint256 amount = bound(usd, 0, 500_000) * 10 ** _dec(st);
        vm.prank(a);
        try vault.topUpReserve(id, st, amount) {
            successes["topUp"]++;
        } catch (bytes memory err) {
            _recordRevert("topUp", err);
        }
    }

    // ---------------- действия владельца (в т.ч. противоположные: туда-обратно)
    /// v5.2: казна забирает накопленные комиссии (pull).
    function claimFees(uint256 stableSeed) external {
        address st = _stable(stableSeed);
        if (vault.accruedFees(st) == 0) return;
        vault.claimFees(st);
    }

    function setManualPrice(uint256 stableSeed, uint256 bps) external {
        calls["setManualPrice"]++;
        address st = _stable(stableSeed);
        bps = bound(bps, 9_300, 10_700); // ~70% значений внутри полосы ±5%
        vm.prank(address(vault));
        try vault.setManualPrice(st, bps * 1e14) {
            successes["setManualPrice"]++;
        } catch {}
    }

    function setFeedPrice(uint256 bps, bool stale) external {
        calls["setFeedPrice"]++;
        bps = bound(bps, 9_300, 10_700);
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.set(int256(bps * 1e4), stale ? 1 : block.timestamp); // 8 знаков
        successes["setFeedPrice"]++;
        _pokeAll(); // цена фида меняется без транзакции в Vault → синхронизируем уровень
    }

    function setWorkingPrice(uint256 basketSeed, uint256 bps) external {
        if (!allowOwnerPriceMoves) return;
        calls["setWorkingPrice"]++;
        (uint256 id,) = _basket(basketSeed);
        (, uint256 idx,,,,) = vault.baskets(id);
        bps = bound(bps, 9_650, 10_350); // частично за пределами ±3% → часть откатов ожидаема
        vm.prank(owner);
        try vault.setWorkingPrice(id, (idx * bps) / 10_000) {
            successes["setWorkingPrice"]++;
        } catch (bytes memory err) {
            _recordRevert("setWorkingPrice", err);
        }
    }

    function setIndex(uint256 basketSeed, uint256 bps) external {
        if (!allowOwnerPriceMoves) return;
        calls["setIndex"]++;
        (uint256 id,) = _basket(basketSeed);
        (, uint256 idx,,,,) = vault.baskets(id);
        bps = bound(bps, 8_500, 11_500);
        // переходим на ближайшее 28-е число (возможно, уже обновлённого месяца → откат)
        (,, uint256 d) = DateLib.timestampToDate(block.timestamp);
        if (d != 28) {
            uint256 daysAhead = d < 28 ? 28 - d : 28 + 31 - d; // попадём на 28-е следующего месяца или около
            vm.warp(block.timestamp + daysAhead * 1 days);
            (,, d) = DateLib.timestampToDate(block.timestamp);
            while (d != 28) {
                vm.warp(block.timestamp + 1 days);
                (,, d) = DateLib.timestampToDate(block.timestamp);
            }
        }
        uint256 newIdx = (idx * bps) / 10_000; // диапазон 85–115% — часть попыток за пределами ±11%
        if (newIdx < 0.5e18) newIdx = 0.5e18;
        if (newIdx > 2e18) newIdx = 2e18;
        // независимая проверка лимита: 0,89·old <= new <= 1,11·old (точно, без округлений)
        bool withinLimit = newIdx * 10_000 >= idx * 8_900 && newIdx * 10_000 <= idx * 11_100;
        vm.prank(owner);
        try vault.setIndex(id, newIdx) {
            successes["setIndex"]++;
            indexUpdatesChecked++;
            if (!withinLimit) vIndexChangeOutOfLimit++;
        } catch (bytes memory err) {
            _recordRevert("setIndex", err);
            if (err.length >= 4 && bytes4(err) == BasketVault.IndexChangeTooLarge.selector) {
                if (withinLimit) vIndexWrongfullyRejected++;
                // revert не должен расходовать попытку месяца: повтор с допустимым значением проходит
                indexLimitRejections++;
                vm.prank(owner);
                try vault.setIndex(id, idx) {
                    indexUpdatesChecked++;
                } catch {
                    vIndexAttemptBurned++;
                }
            }
        }
        _pokeAll(); // warp мог сделать фид устаревшим
    }

    /// Пауза включается в 1 из 3 вызовов, снимается всегда — чтобы большая часть времени была без паузы.
    function togglePause(uint256 seed) external {
        calls["togglePause"]++;
        if (!vault.paused() && seed % 3 != 0) {
            successes["togglePause"]++;
            return;
        }
        vm.startPrank(owner);
        if (vault.paused()) {
            try vault.unpause() {
                successes["togglePause"]++;
            } catch {}
        } else {
            try vault.pause() {
                successes["togglePause"]++;
            } catch {}
        }
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        secs = bound(secs, 1, 3 days);
        vm.warp(block.timestamp + secs);
        successes["warp"]++;
        _pokeAll(); // фид мог устареть
    }
}
