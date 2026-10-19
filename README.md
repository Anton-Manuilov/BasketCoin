# BasketCoin — смарт-контракты

> **Статус:** прототип. Прошёл только внутреннюю проверку (см. [`AUDIT_REPORT.md`](AUDIT_REPORT.md)).
> Внешнего аудита не было. Ни в одну сеть не деплоился. Не использовать с реальными средствами.

BasketCoin — токен, цена которого следует индексу корзины. Индекс задаёт оракул (ключ владельца) раз в месяц, 28-го числа по UTC.
Токен выпускается под залог стейблкоинов (USDT/USDC) с избыточным обеспечением 120% и выкупается обратно по трёхуровневой схеме.

Полная спецификация: [`SPEC.md`](SPEC.md).

## Коротко о правилах
| Что | Правило |
|---|---|
| Оракул | только владелец |
| Индекс | `setIndex` — только 28-го (UTC), не чаще раза в месяц |
| Лимит индекса | не более **±11%** от предыдущего индекса за одно обновление (константа 1100 bps, границы включительно, округление в сторону строгости). Отказ — `IndexChangeTooLarge`, попытку месяца он не расходует. Стартовый индекс корзины не ограничен |
| Рабочая цена | `setWorkingPrice` — в пределах ±3% от индекса |
| Комиссия | 0,3% на минт и выкуп → `feeRecipient`, округление вверх |
| Минимальный минт | `minMintUsd` ∈ [$50; $1000], по фактически полученной сумме до комиссии |
| Стейблы | USDT/USDC при запуске; новые — через таймлок 9 дней |
| Депег | цена вне $0,95–$1,05 блокирует только этот стейбл |
| Пауза | вручную, владелец |
| Буфер | 20%, эмиссия не ограничена, архитектура с несколькими корзинами |
| Выкуп | ≥140% FULL (с буфером) · 115–140% STANDARD (без буфера) · <115% SUSPENDED (снимается сама) |
| `topUpReserve` | открыт для всех |

## События
Полный список событий — `SPEC.md`, раздел 4.

#### Таблица «действие → событие → параметры → тест»
Все тесты проверяют событие через `vm.expectEmit(address(vault))` — это все topics, все data и адрес эмиттера. Лишних событий нет: это проверяет `vm.recordLogs` + `_assertVaultSigs`, которая сверяет точный список и порядок событий Vault в транзакции. Файл тестов — `test/unit/Events.t.sol`, если не указано другое (↑ — indexed).

| # | Действие (функция) | Событие | Параметры | Тест(ы) |
|---|---|---|---|---|
| 1 | Обновление индекса (`setIndex`) | `IndexUpdated` | basketId↑, oldIndex, newIndex, oldWorkingPrice, year, month, timestamp | `test_Ev_IndexUpdated_OldNewYearMonthTimestamp`, `test_Ev_IndexUpdated_WithTierChange`; Oracle.t.sol: `test_SetIndex_DayBoundaries`, `test_SetIndex_YearChange_February_LeapYear_SkippedMonth` |
| 1a | Отказ `setIndex` по лимиту ±11% (v0.4) | — (revert, событий нет) | ошибка `IndexChangeTooLarge(basketId, oldIndex, newIndex, minAllowed, maxAllowed)` | IndexLimit.t.sol: `test_Limit_Plus11PlusOneWei_Reverts_WithArgs`, `test_Limit_Minus11MinusOneWei_Reverts_WithArgs`, `test_Limit_LargeJumps_Revert_WithArgs`, `testFuzz_Limit_SucceedsIffWithinBounds` |
| 2 | Рабочая цена (`setWorkingPrice`) | `WorkingPriceUpdated` | basketId↑, oldPrice, newPrice, index | `test_Ev_WorkingPriceUpdated_OldNewIndex`; Oracle.t.sol: `test_WorkingPrice_ExactBandAndOneWeiOutside` |
| 3 | Смена уровня покрытия (<115 / 115–140 / ≥140) из mint, redeem, topUp, setIndex, setWorkingPrice, setManualPrice, setStableFeed, pokeTier, pokeStable | `CoverageTierChanged` | basketId↑, oldTier↑, newTier↑, coverageBps (после операции) | `test_Ev_Minted_FirstMint_FullArgs_AndTierEvent`, `test_Ev_Redeemed_RaisesTier_EmitsTierAfterRedeemed`, `test_Ev_ReserveToppedUp_WithTierChangeToFull`, `test_Ev_IndexUpdated_WithTierChange`, `test_Ev_ManualPrice_TierChangeCarriesCoverage`, `test_Ev_Depeg_ViaPokeStable_AndPokeTier`; нет события без смены уровня: `test_Ev_NoTierEvent_WhenTierUnchanged_AllSources`; Boundaries.t.sol: `test_TierEvent_CarriesCoverage`, `test_PokeTier_NoEventWhenUnchanged_AndUnknownBasket` |
| 4 | Пауза вкл/выкл (`pause`/`unpause`) | `Paused` / `Unpaused` (OpenZeppelin, подходят) | account (кто вызвал) | `test_Ev_PauseUnpause_StandardOZEvents` |
| 5 | Новый стейбл: заявка (`proposeStable`) | `StableProposed` | stable↑, decimals, feed↑, maxFeedStaleness, executeAfter (eta), previousExecuteAfter | `test_Ev_StableTimelock_ProposeReproposeCancelExecute`; Admin.t.sol: `test_Timelock_ProposeEmitsAndStores` |
| 6 | Новый стейбл: отмена (`cancelStable`) | `StableProposalCancelled` | stable↑, executeAfter (eta отменённой заявки) | `test_Ev_StableTimelock_ProposeReproposeCancelExecute`; Admin.t.sol: `test_Timelock_DuplicateExecuteTwiceCancel` |
| 7 | Новый стейбл: исполнение (`executeStable`) | `StableAdded` (+ `StableDepegStatusChanged`, если цена вне коридора) | stable↑, decimals, feed↑, maxFeedStaleness, viaTimelock | `test_Ev_StableTimelock_ProposeReproposeCancelExecute`, `test_Ev_ExecuteStable_DepeggedOnArrival`; Admin.t.sol: `test_Timelock_ExecuteExactBoundaryAndEvent` |
| 8 | Минимальный минт (`setMinMintUsd`) | `MinMintUpdated` | oldValue, newValue | `test_Ev_MinMintUpdated_OldNew`; MintRedeem.t.sol: `test_MinMint_ParamBounds_OneWei` |
| 9 | Минт (`mint`) | `Minted` | basketId↑, user↑, stable↑, stableIn, fee, tokensOut, workingPrice, stablePrice, tier, coverageBefore, coverageAfter | `test_Ev_Minted_FirstMint_FullArgs_AndTierEvent`, `test_Ev_Minted_SecondMint_StablePriceBelowOne_NoTierEvent`, `test_Ev_Depeg_RecoveryDetectedInMint` |
| 10 | Выкуп (`redeem`) | `Redeemed` | basketId↑, user↑, stable↑, tokensIn, stableOut, fee, workingPrice, stablePrice, tier, coverageBefore, coverageAfter | `test_Ev_Redeemed_Standard_FullArgs`, `test_Ev_Redeemed_Full_WithBuffer_StablePriceAboveOne`, `test_Ev_Redeemed_RaisesTier_EmitsTierAfterRedeemed` |
| 11 | Пополнение резерва (`topUpReserve`) | `ReserveToppedUp` | basketId↑, from↑, stable↑, amount, coverageBefore, coverageAfter | `test_Ev_ReserveToppedUp_CoverageBeforeAfter_NoTierChange`, `test_Ev_ReserveToppedUp_WithTierChangeToFull`, `test_Ev_Depeg_DetectedInTopUp` |
| 12 | Казна (`setFeeRecipient`; конструктор) | `FeeRecipientUpdated` | oldRecipient↑, newRecipient↑ | `test_Ev_FeeRecipientUpdated_OldNew`, `test_Ev_Constructor_AllInitialEvents` |
| 13 | Ручная цена стейбла (`setManualPrice`) | `ManualPriceUpdated` | stable↑, oldPrice, newPrice | `test_Ev_ManualPrice_DepegEnterRepeatExit`, `test_Ev_ManualPrice_TierChangeCarriesCoverage`; Admin.t.sol: `test_Events_ConfigWithArgs` |
| 14 | Фид и его параметры (`setStableFeed`) | `StableFeedUpdated` | stable↑, oldFeed, newFeed, oldMaxStaleness, newMaxStaleness | `test_Ev_StableFeedUpdated_OldNew_AndDepegOnSwitch`; Admin.t.sol: `test_Events_ConfigWithArgs` |
| 15 | Создание корзины (`addBasket`) | `BasketAdded` | basketId↑, token↑, initialIndex, initialTier | `test_Ev_BasketAdded_WithInitialTier_NoTierEvent`; Admin.t.sol: `test_AddBasket_ErrorsAndEvent` |
| 16 | Смена владельца (`transferOwnership` → `acceptOwnership`; конструктор) | `OwnershipTransferStarted`, `OwnershipTransferred` (OpenZeppelin Ownable2Step) | previousOwner↑, newOwner↑ | `test_Ev_Ownership_TwoStep`, `test_Ev_Constructor_AllInitialEvents` |
| 17 | Вход/выход стейбла в депег (`setManualPrice`, `setStableFeed`, `executeStable`, `pokeStable`, `pokeTier`, `topUpReserve`; выход — также в успешных `mint`/`redeem`) | `StableDepegStatusChanged` | stable↑, depegged, price | `test_Ev_ManualPrice_DepegEnterRepeatExit` (вход, повтор без события, выход, вход вверх; ±1 wei у 0,95/1,05), `test_Ev_StableFeedUpdated_OldNew_AndDepegOnSwitch`, `test_Ev_Depeg_ViaPokeStable_AndPokeTier`, `test_Ev_Depeg_RecoveryDetectedInMint`, `test_Ev_Depeg_DetectedInTopUp`, `test_Ev_ExecuteStable_DepeggedOnArrival` |
| 18 | Деплой (конструктор) | `OwnershipTransferred`, `FeeRecipientUpdated`, `MinMintUpdated`, `StableAdded`×2 | см. строки 5–16, `viaTimelock = false` | `test_Ev_Constructor_AllInitialEvents` (ровно 5 событий) |
| 19 | Ревертнутые вызовы | — | событий нет | `test_Ev_RevertedCallsEmitNothing` |

Ограничения:
- Выход из депега внутри `redeem` использует тот же код (`_syncDepeg`), что и в `mint`, но отдельным тестом не проверен.
- Событие депега появляется только тогда, когда переход обнаружен в транзакции. Движение фида без транзакций в Vault не видно on-chain, пока кто-то не вызовет `pokeStable`/`pokeTier`.
- Роли токена (`MINTER_ROLE`) логируются стандартными `RoleGranted`/`RoleRevoked` в `BasketToken`.

## Структура
```
src/
  BasketVault.sol          залог, реестр корзин, минт/выкуп, оракул (лимит индекса ±11%), таймлок стейблов
  BasketToken.sol          ERC20 корзины (mint/burn только MINTER_ROLE = Vault)
  libraries/DateLib.sol    timestamp → дата UTC
  interfaces/IAggregatorV3.sol
  testnet/TestStablecoins.sol  ТОЛЬКО ТЕСТНЕТ: TestUSDT/TestUSDC (6 знаков, открытый кран ≤ 10 000 за вызов)
test/
  unit/                    граничные случаи, оракул, лимит индекса, минт/выкуп, права и события
  invariant/               handler + stateful-инварианты
  Differential.t.sol       сравнение с эталонами (Math.mulDiv, BokkyPooBah DateTime)
  Reentrancy.t.sol         атака через токен с хуками
  BasketVault.t.sol, RedeemTiers.t.sol — базовые сценарии
script/invariant_stats.py  сводка откатов по действиям handler'а
script/Deploy.s.sol        деплой тестнет-набора (Base Sepolia) → deployments/base-sepolia.json
script/UpdateIndex.s.sol   ежемесячный setIndex с проверками до отправки
script/verify.sh           верификация на Blockscout/Sourcify без API-ключа
script/dry-run-anvil.sh    сухой прогон деплоя и операций на локальном форке Base Sepolia
docs/OPERATIONS.md         деплой, индекс, пауза, цены, владение, подписи (Ledger / MetaMask / Safe)
```

## Запуск
```bash
git submodule update --init --recursive   # forge-std v1.17.0, OpenZeppelin v5.1.0
forge build
forge test                                 # быстрый профиль (fuzz 256, invariant 64 × 50)
FOUNDRY_PROFILE=ci forge test              # fuzz 10 000, invariant 1000 × 200
forge coverage --report summary --no-match-coverage '(test|lib|script)/'
slither . --filter-paths "lib/|test/"
python3 script/invariant_stats.py          # после прогона инвариантов (нужен pycryptodome)
```
Требуется Foundry ≥ 1.8 (проверено на forge 1.8.5), solc 0.8.24.

## Тестнет (Base Sepolia)
Деплой, верификация и операции владельца описаны в [docs/OPERATIONS.md](docs/OPERATIONS.md).
На тестнете вместо USDT/USDC используются TestUSDT/TestUSDC с открытым краном (`faucet(uint256)`, до 10 000 за вызов).

## Лицензия
**Не решено.** В файлах стоит `SPDX-License-Identifier: MIT` (как при создании), но файла `LICENSE` нет — нужно решение Антона перед публикацией.

---

## English summary (for auditors)
**Status:** prototype, internal review only — **not externally audited**, never deployed.

- `BasketVault` holds stablecoin collateral per (basket, stable) pair and mints/burns `BasketToken`s at the owner-set working price.
- The owner is the oracle. The index can be set only on the 28th (UTC), at most once per calendar month.
- Each `setIndex` may move the index by at most ±11% from the previous fixed index (`MAX_INDEX_CHANGE_BPS = 1100`, a constant):
  - bounds are inclusive and rounded toward strictness: `min = ceil(old*0.89)`, `max = floor(old*1.11)`;
  - violations revert with `IndexChangeTooLarge(basketId, oldIndex, newIndex, minAllowed, maxAllowed)` and do not consume the monthly slot;
  - the initial index set in `addBasket` is unrestricted;
  - the limit caps a single step, not the cumulative drift: ×3.50 / ×0.25 over 12 months.
- The working price must stay within ±3% of the current index.
- Mint is collateralised at 120%. Fee is 0.3% on mint and redeem (rounded up). Token output is rounded down with a single `mulDiv`.
- Redemption tier depends on coverage *before* the redeem:
  - ≥140%: par + 20% buffer;
  - 115–140%: par;
  - <115%: suspended.
  Thresholds are constants.
- Stables are valued at `min(p,$1)` for coverage/mint and `max(p,$1)` for payouts. A depeg outside [0.95, 1.05] blocks only that stable. New stables require a 9-day timelock.
- Feeds are read with a gas-capped, fixed-buffer `staticcall`; invalid/stale/incomplete answers fall back to the owner's manual price.
- Trust assumptions: the owner key (oracle, pause, params, stable additions) and the token admin (`MINTER_ROLE`) are fully trusted. Fee-on-transfer stables are accounted by received amount. Rebasing tokens and tokens with hooks are out of scope.
- Every state change emits an event with old/new values. Mint, redeem and top-up events carry coverage before/after. Depeg transitions are logged when detected in a transaction. See the events table above (columns: action → event → params → test).
- See `AUDIT_REPORT.md` (Russian) for:
  - invariants and run statistics;
  - Slither triage;
  - findings F-01…F-09 with regression tests;
  - known risks.

  Raw outputs are in `test-results.txt`.

**License:** undecided (SPDX MIT headers present, no LICENSE file yet).
