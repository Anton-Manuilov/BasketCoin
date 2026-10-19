# BasketCoin — отчёт о внутренней проверке (pre-audit), v0.4

> **Важно.** Это внутренняя проверка: её провёл тот же исполнитель, который писал код, автоматическими инструментами и тестами. **Это не внешний аудит** и не гарантия отсутствия уязвимостей. Перед деплоем с реальными средствами нужен независимый аудит (см. раздел 10).

- Дата: 2026-10-19 (Asia/Saigon, UTC+7). Версия v0.4 добавляет лимит изменения индекса ±11% (раздел 7.1).
- Код: `src/` — commit в локальном git-репозитории (см. `git log`); на момент проверки нигде не публиковался и не деплоился (позже — только тестнет Base Sepolia, токен BKT).
- Инструменты:
  - Solidity 0.8.24 (optimizer 200);
  - OpenZeppelin 5.1.0, forge-std 1.17.0;
  - Foundry forge 1.8.5;
  - Slither 0.11.6.
- Сырые результаты: `test-results.txt`. Все числа ниже взяты из него.

## 1. Объём проверки
| Файл | Назначение |
|---|---|
| `src/BasketVault.sol` | залог, корзины, минт/выкуп, оракул, таймлок, события |
| `src/BasketToken.sol` | ERC20 + AccessControl (MINTER_ROLE) |
| `src/libraries/DateLib.sol` | timestamp → дата UTC |
| `src/interfaces/IAggregatorV3.sol` | интерфейс фида |

Поведение, зафиксированное Антоном, не менялось:
- оракул — только ключ owner;
- `setIndex` — только 28-го (UTC), не чаще раза в месяц;
- рабочая цена — ±3% от индекса;
- (v0.4, решение Антона) лимит изменения индекса за одно обновление — ±11%;
- комиссия 0,3% на минт и выкуп → `feeRecipient`;
- `minMint` — в диапазоне $50–$1000;
- стейблы: USDT/USDC при запуске, новые — через таймлок 9 дней;
- депег ±5% блокирует только свой стейбл;
- пауза — вручную, owner;
- буфер 20%, эмиссия не ограничена, несколько корзин;
- выкуп: ≥140% FULL / 115–140% STANDARD / <115% SUSPENDED;
- `topUpReserve` открыт для всех.

Предложения изменить это поведение вынесены в рекомендации (раздел 10).

## 2. Методы
1. Unit-тесты граничных случаев:
   - покрытие 115/140 ±1 bps и ±1 wei;
   - переходы уровней из каждого источника;
   - депег 0,95/1,05 при decimals фида 6/8/18;
   - устаревшие и неполные раунды;
   - пауза × депег × SUSPENDED;
   - минимальный минт;
   - комиссии и округление;
   - decimals стейбла 6/8/18 и нестандартные токены (без return, fee-on-transfer, return false);
   - таймлок;
   - 28-е число (конец суток, смена года, февраль, високосный год);
   - ±3%;
   - изоляция корзин;
   - права;
   - события и ошибки с аргументами.
2. Stateful-инварианты: handler, 3 актора + owner, 9 действий, включая действия owner'а; ghost-переменные; `fail_on_revert = false`.
3. Fuzz: 9 fuzz-тестов, в профиле ci — по 10 000 прогонов.
4. Дифференциальные тесты:
   - минт/выкуп/покрытие против эталона на `Math.mulDiv`;
   - `DateLib` против эталона BokkyPooBah (fuzz + ежедневный проход 1970–2200 + каждое 28-е).
5. Реентрантность:
   - вредоносный токен с хуками (ERC777-подобный), добавленный через таймлок;
   - повторный вход в mint/redeem/topUp/poke из хуков на mint/redeem/topUp.
6. Ревью CEI, проверка переполнений (fuzz на экстремальных значениях).
7. Статический анализ: Slither (все находки разобраны), `forge lint` (0 предупреждений в `src/`).
8. Мутационная проверка инвариантов и событий: внесённая ошибка должна ловиться тестами (раздел 5).

## 3. Тесты
Итог (`test-results.txt`):

| Профиль | Параметры | Результат |
|---|---|---|
| default | fuzz 256, invariant 64 runs × 50 depth | **198 passed, 0 failed, 0 skipped** (14 suites) |
| ci (`FOUNDRY_PROFILE=ci`) | fuzz 10 000, invariant 1000 runs × 200 depth | **198 passed, 0 failed, 0 skipped** (14 suites), `real 2m2.215s` |

По категориям:

| Категория | Файл | Тестов |
|---|---|---|
| Границы покрытия и переходы уровней | `test/unit/Boundaries.t.sol` | 21 |
| Оракул: депег, фиды, 28-е число, ±3% | `test/unit/Oracle.t.sol` (OracleTest) | 21 |
| Регрессии DoS через фид | `test/unit/Oracle.t.sol` (FeedDoSRegressionTest) | 6 |
| Минт/выкуп, минимум, комиссии, decimals, нестандартные токены, пауза, мультикорзины | `test/unit/MintRedeem.t.sol` | 25 |
| Таймлок, права, ошибки, регрессии | `test/unit/Admin.t.sol` | 20 |
| События (все параметры + отсутствие лишних) | `test/unit/Events.t.sol` | 26 |
| Лимит изменения индекса ±11% (v0.4) | `test/unit/IndexLimit.t.sol` | 14 |
| Реентрантность | `test/Reentrancy.t.sol` | 7 |
| Дифференциальные (округление) | `test/Differential.t.sol` (DifferentialRoundingTest) | 4 |
| Дифференциальные (DateLib) | `test/Differential.t.sol` (DateLibDifferentialTest) | 3 |
| Базовые сценарии v0.1–v0.2 | `test/BasketVault.t.sol`, `test/RedeemTiers.t.sol` | 29 + 20 |
| Инварианты | `test/invariant/Invariants.t.sol` | 2 сьюта (11 + 2 инварианта) |
| **Итого** | | **198** |

## 4. Инварианты
Профиль ci:
- **VaultInvariants**: runs 1000, calls 200 000, reverts 0. Все 9 действий handler'а.
- **NoProfitInvariants**: runs 1000, calls 200 000, reverts 0. Без topUp и без движения индекса и рабочей цены. Отключённые действия исключены через `targetSelector`.

«reverts: 0» у Foundry означает, что откатов на уровне handler'а нет. Вызовы Vault внутри handler'а обёрнуты в try/catch, их откаты считаются отдельно (таблица ниже).

| # | Инвариант | Что проверяет |
|---|---|---|
| 1 | `invariant_BalanceCoversReserves` | баланс каждого стейбла на Vault ≥ Σ резервов по корзинам |
| 1b | `invariant_BalanceEqualsReserves` | для стандартных токенов — строгое равенство (нет «зависших» средств) |
| 2 | `invariant_SupplyMatchesGhost` | totalSupply = Σ minted − Σ burned (ghost) по каждой корзине |
| 3 | `invariant_NoRedeemBelow115` | ни один успешный выкуп при покрытии < 115% |
| 4 | `invariant_RedeemNeverLowersCoverage` | успешный выкуп не снижает покрытие |
| 5 | `invariant_MintKeepsCoverageFloor` | минт при цене стейбла ≤ $1 держит покрытие ≥ min(прежнее, 120%) − 1 bps (округление bps вниз) |
| 6 | `invariant_NoActorProfitsWithoutTopUp` | цикл минт → выкуп без внешнего пополнения не даёт прибыли (в USD по $1) |
| 7 | `invariant_FeesMatchGhost` | приход в казну = ghost-сумма. Ghost считается **независимо**: ceil(0,3%) от суммы минта или gross выкупа |
| 8 | `invariant_NothingWhilePaused` | ни один минт или выкуп не прошёл на паузе |
| 9 | `invariant_NothingWhileDepegged` | ни один минт или выкуп не прошёл в депегнутом стейбле |
| 10 | `invariant_TierMatchesCoverage` | `redeemTier` соответствует порогам по `collateralRatioBps` |
| 11 | `invariant_IndexChangeWithinLimit` (v0.4) | каждый успешный `setIndex` в пределах ±11% от предыдущего; отказ `IndexChangeTooLarge` только вне ±11%; после отказа повтор в том же месяце проходит |

Доля откатов вызовов Vault внутри handler'а. Это счётчик handler'а, он на 201 вызов больше счётчика Foundry (200 201 против 200 000).

| Действие | Full: вызовов | откатов | % | NoProfit: вызовов | откатов | % |
|---|---|---|---|---|---|---|
| mint | 22 308 | 10 514 | 47,1% | 33 438 | 16 337 | 48,9% |
| redeem | 22 480 | 12 472 | 55,5% | 33 409 | 19 238 | 57,6% |
| topUp | 22 138 | 131 | 0,6% | — | — | — |
| setManualPrice | 22 238 | 0 | 0% | 33 701 | 0 | 0% |
| setFeedPrice | 22 199 | 0 | 0% | 33 123 | 0 | 0% |
| setWorkingPrice | 22 130 | 3 559 | 16,1% | — | — | — |
| setIndex | 22 320 | 13 880 | 62,2% | — | — | — |
| togglePause | 22 150 | 0 | 0% | 33 339 | 0 | 0% |
| warp | 22 238 | 0 | 0% | 33 191 | 0 | 0% |
| **Итого** | 200 201 | 40 556 | **20,3%** | 200 201 | 35 575 | **17,8%** |

Причины откатов (Full):
- mint: EnforcedPause 5678, StableDepegged 3963, BelowMinMint 873;
- redeem: EnforcedPause 5604, StableDepegged 2539, ZeroAmount 2225, InsufficientReserve 1969, RedemptionSuspended 135;
- setWorkingPrice: PriceOutOfBand 3559;
- setIndex: IndexAlreadyUpdatedThisMonth 10 963, IndexChangeTooLarge 2917 (v0.4);
- topUp: ZeroAmount 131.

Лимит индекса (v0.4, Full): handler проверил 11 357 успешных `setIndex` (8440 прямых + 2917 повторных попыток в том же месяце после отказа по лимиту — все прошли). Нарушений инварианта 11: 0.

Все откаты ожидаемые: это проверки самого протокола. Они и нужны, чтобы проверить инварианты 3, 8 и 9.

## 5. Мутационная проверка
Каждая мутация вносилась во временную копию `BasketVault.sol`. Затем запускались тесты (профиль default), после чего код восстанавливался (`diff` пуст).

| Мутация | Чем поймана |
|---|---|
| M1: у `redeem` убран `whenNotPaused` | `invariant_NothingWhilePaused` |
| M2: на STANDARD выкуп платит с буфером (k = 1,2 всегда) | `invariant_RedeemNeverLowersCoverage` |
| M3: SUSPENDED не блокирует выкуп | `invariant_NoRedeemBelow115` |
| M4: комиссия минта не переводится в казну | сначала **не поймана**: см. T-01. После исправления — `invariant_FeesMatchGhost` и `invariant_BalanceEqualsReserves` |
| M5: при выкупе не проверяется депег | `invariant_NothingWhileDepegged` |
| M6: комиссия выкупа округляется вниз | `invariant_FeesMatchGhost` |
| L1 (v0.4): проверка лимита индекса удалена | `invariant_IndexChangeWithinLimit` + IndexLimitTest: 8 тестов упали |
| L2 (v0.4): нижняя граница округляется вниз, а не вверх | IndexLimitTest: 3 теста упали (инвариант этого не видит — нужна точность до wei) |
| L3 (v0.4): лимит 12% вместо 11% | `invariant_IndexChangeWithinLimit` + IndexLimitTest: 10 тестов упали |
| L4 (v0.4): границы исключительные (`<=`/`>=`) | `invariant_IndexChangeWithinLimit` + IndexLimitTest: 8 тестов упали |
| E1: в `Minted` перепутаны coverageBefore/After | EventsTest: 2 теста упали |
| E2: `setManualPrice` не синхронизирует депег | EventsTest: 1 тест упал |
| E3: `CoverageTierChanged` выпускается всегда | EventsTest: 11 тестов упали |

## 6. Slither
Команда: `slither . --filter-paths "lib/|test/"`. Итог: **10 results**, все уровня Low или Informational. Ни одной находки уровня Medium или High. Код выхода 255 означает «есть находки». В CI задан порог `fail-on: medium`.

До подавлений было 17 находок. Ложные срабатывания подавлены inline-комментариями с обоснованием:
- `divide-before-multiply` ×4 (DateLib);
- `incorrect-equality` ×2;
- `missing-zero-check` ×2.

| Детектор | Кол-во | Где | Разбор |
|---|---|---|---|
| calls-loop | 3 | `_coverageBps` → `token.totalSupply()` в цикле `_syncAllTiers` (из setManualPrice, setStableFeed, pokeStable) | Принято. View-вызов доверенного BasketToken. Число корзин задаёт owner. Риск — только газ при большом числе корзин (рекомендация R-7) |
| reentrancy-benign | 2 | mint/redeem: `lastDepegged`/`lastTier` пишутся после `token.mint/burn` | Принято. Обе функции под `nonReentrant`. Внешний вызов идёт к доверенному BasketToken. После вызова пишутся только кэши для событий. Проверено в `test/Reentrancy.t.sol` |
| timestamp | 3 | setIndex (день/месяц), executeStable (таймлок), `_readFeed` (давность) | Принято. Валидатор может сдвинуть время на секунды, для суток, 9 дней и staleness это несущественно |
| assembly | 2 | `_staticcallWords5`, `_staticcallWord` | Сделано намеренно: ограничение газа и фиксированный буфер ответа (защита от return-bomb, F-02). Помечено `memory-safe` |
| ~~divide-before-multiply~~ | (4) | DateLib | Ложное: календарная арифметика Hinnant, где деление с округлением — часть алгоритма. Подтверждено дифференциальным тестом |
| ~~incorrect-equality~~ | (2) | ключ месяца, `tokensOut == 0` | Ложное: это не сравнение балансов |
| ~~missing-zero-check~~ | (2) | конструктор, setFeeRecipient | Ложное: проверка есть в `_validateFeeRecipient` |

`forge lint` на `src/`: 0 предупреждений. Каждое подавление снабжено комментарием-обоснованием в коде.

Aderyn и Halmos не запускались (необязательные инструменты).

## 7. Найденные проблемы и исправления
Оценка серьёзности внутренняя: High — потеря средств; Medium — DoS или нарушение правил; Low — неточность или граничный случай; Info — качество кода.

| ID | Серьёзность | Проблема | Исправление | Регрессионный тест |
|---|---|---|---|---|
| F-01 | **High** | Один `BasketToken` можно было привязать к двум корзинам. Общий totalSupply позволял выкупать токены одной корзины за резервы другой и ломал покрытие | `tokenRegistered`, ошибка `TokenAlreadyRegistered` | `test_Regression_F01_SameTokenTwoBaskets` |
| F-02 | Medium | Сломанный или враждебный фид останавливал весь Vault: `_coverageBps` перебирает все стейблы, поэтому откат или OOG фида блокировал минт и выкуп во всех корзинах. Причины: EOA, короткий ответ, return-bomb, сжигание газа, огромный answer (переполнение) | `staticcall` с лимитом газа 100 000, фиксированным буфером и проверкой длины ответа; answer ≤ 2^128−1; при невалидном ответе — ручная цена | `test_Regression_F02_EOAFeed`, `_ShortReturnFeed`, `_ReturnBombFeed`, `_GasGuzzlerFeed`, `_HugeAnswerNoOverflow` |
| F-03 | Low | Принимались неполный раунд (`answeredInRound < roundId`), `updatedAt = 0` и `updatedAt` в будущем | Добавлены проверки | `test_Regression_F03_IncompleteRound`, OracleTest: `updatedAt` 0/будущее |
| F-04 | Low | Комиссия округлялась вниз: на малых суммах она могла быть 0, и округление шло в пользу пользователя | Комиссия считается `ceil`; при нулевой выплате — ошибка `ZeroAmount` | `test_Fee_MintRoundsUp`, `test_Fee_RedeemRoundsUp_AndDust` |
| F-05 | Low | Индекс, рабочая и ручная цены не были ограничены: 0 или огромное значение давали деление на 0 или Panic при переполнении в покрытии (DoS) | Цены в (0, 10^36], ошибка `InvalidPrice` | `test_Regression_F05_PriceUpperBound`, `testFuzz_NoOverflowPanicAtExtremes` |
| F-06 | Low | `feeRecipient` мог быть самим Vault. Тогда комиссии смешивались с балансом и не учитывались в резервах | `InvalidFeeRecipient` | `test_Regression_F06_FeeRecipientCannotBeVault` |
| F-07 | Low | `pokeTier` можно было вызвать из хука токена посреди mint/redeem и выпустить событие по промежуточному состоянию | `nonReentrant` | `test_Regression_F07_PokeTierNonReentrant` |
| F-08 | Info | decimals > 18 выявлялись только в `executeStable`, через 9 дней | Проверка перенесена в `proposeStable` | `test_Regression_F08_ProposeValidatesTokenEarly` |
| F-09 | Low | Двойное округление в минте, выкупе и покрытии: потеря точности, расхождение с эталоном до 1 bps | Одно `Math.mulDiv`; покрытие считается как `mulDiv(mulDiv(usd,1e18,P),BPS,supply)` | `testFuzz_Diff_MintMatchesReference`, `testFuzz_Diff_RedeemWithinOneUnitOfExact`, `testFuzz_Diff_CoverageWithinOneBps` |
| F-10 | Info | В событиях не было старых значений и покрытия до/после. Вход и выход из депега не логировались, у конструктора не было событий | Полный набор событий (раздел 8), `StableDepegStatusChanged`, `pokeStable`, `lastDepegged` | `test/unit/Events.t.sol` (26 тестов) |
| T-01 | (тесты) | `invariant_FeesMatchGhost` был тавтологией: ghost брался из фактического прихода в казну. Мутация M4 не ловилась | Ghost считается независимо по формуле. Добавлен `invariant_BalanceEqualsReserves` | мутация M4 теперь ловится (раздел 5) |

Сравнить регрессионные тесты со старым кодом v0.2 напрямую нельзя: изменился ABI (новые ошибки и события), поэтому тесты не компилируются со старым контрактом. Вместо этого каждое исправление закреплено тестом, который проверяет новое поведение.

**Покрытие кода** (`forge coverage --report summary --no-match-coverage '(test|lib|script)/'`):

| Файл | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| BasketToken.sol | 100% (7/7) | 100% (4/4) | 100% (2/2) | 100% (3/3) |
| BasketVault.sol | 100% (319/319) | 99,49% (391/393) | 96,77% (60/62) | 100% (54/54) |
| DateLib.sol | 100% (14/14) | 100% (27/27) | 100% (3/3) | 100% (1/1) |
| **Total** | 100% (340/340) | 99,53% (422/424) | 97,01% (65/67) | 100% (58/58) |

Непокрытые ветки по lcov:
1. `BasketVault.sol:572` — `if (tokensOut == 0) revert ZeroAmount()` в mint. Ветка недостижима при текущих ограничениях: при MAX_PRICE и $50 выпуск ≈ 41 wei (`test_Mint_AtMaxIndex_StillNonZero`). Оставлена как защитная.
2. `BasketVault.sol:795` — `dec > 18` в `_addStable`. Её проверяет `test_Decimals_Above18_Rejected` через откат конструктора (`new BasketVault` с 19-decimal токеном), но forge coverage не засчитывает покрытие откатившегося деплоя. Из `executeStable` ветка недостижима: decimals проверяются ещё в `proposeStable`, если только decimals токена не изменятся за 9 дней.

### 7.1. v0.4: лимит изменения индекса ±11%
Это не находка, а изменение по решению Антона: реализована бывшая рекомендация R-2.

- `MAX_INDEX_CHANGE_BPS = 1100` (константа). `setIndex` принимает только `ceil(old×0,89) ≤ new ≤ floor(old×1,11)`.
- Округление границ — в сторону строгости. Пример: при old = 1e18 + 7 wei
  - min = 0,89e18 + 7;
  - max = 1,11e18 + 7.
- Отказ — `IndexChangeTooLarge(basketId, oldIndex, newIndex, minAllowed, maxAllowed)`. Revert не меняет состояние, поэтому попытка месяца не расходуется.
- Стартовый индекс в `addBasket` не ограничен.
- Рабочая цена ±3% считается от нового индекса.
- Добавлена view `indexBounds(basketId)`.

Тесты — `test/unit/IndexLimit.t.sol` (14 тестов, из них 1 fuzz):

| Тест | Что проверяет |
|---|---|
| `test_Limit_Plus11Exact_Succeeds`, `test_Limit_Minus11Exact_Succeeds` | ровно ±11% разрешено |
| `test_Limit_InsideRange_Succeeds`, `test_Limit_ZeroChange_Succeeds` | внутри диапазона и 0% |
| `test_Limit_Plus11PlusOneWei_Reverts_WithArgs`, `test_Limit_Minus11MinusOneWei_Reverts_WithArgs` | ±1 wei за границей, все аргументы ошибки |
| `test_Limit_LargeJumps_Revert_WithArgs` | ×2, ×0,5, 0,85, 1,2, 1 wei, 1e36 |
| `test_Limit_BoundsRoundTowardStrictness` | нецелые границы: min вверх, max вниз; точные ±11% вне диапазона |
| `test_Limit_SequentialMonths_EachFromNewValue` | каждый месяц лимит от нового значения, включая смену года |
| `test_Limit_RejectionDoesNotBurnMonthAttempt` | после отказа в тот же день проходит; после успеха — `IndexAlreadyUpdatedThisMonth` |
| `test_Limit_InitialIndexUnlimited` | стартовый 5e18 / 1 wei / 1e36; первый `setIndex` — от стартового |
| `test_Limit_WorkingPriceBandFromNewIndex` | ±3% от нового индекса; лимит индекса — от индекса, не от рабочей цены |
| `test_Limit_ConstantAndBoundsView` | константа 1100, `indexBounds`, неизвестная корзина |
| `testFuzz_Limit_SucceedsIffWithinBounds` | проходит ⇔ в пределах ±11% (точная целочисленная проверка); при отказе — ошибка с эталонными границами; попытка не сгорает |

Дополнительно:
- `test_SetIndex_CannotJumpBetweenFullAndSuspendedInOneStep` (Boundaries) — FULL ↔ SUSPENDED одним `setIndex` невозможны.
- `invariant_IndexChangeWithinLimit` (stateful) — handler пробует изменения от −15% до +15%. Для каждого успешного `setIndex` он независимо проверяет лимит. После каждого отказа по лимиту повторяет попытку в том же месяце, и она должна пройти.

Старые тесты с большими скачками переписаны без ослабления проверок:

| Тест | Как теперь |
|---|---|
| `test_Source_SetIndex_AllDirections` | переходы по месяцам шагами ≤ 11% (STD→FULL через 0,89 → 0,85 и т. д.) |
| `test_Transition_ByIndexDrop` | сначала отказ 0,85 с аргументами, затем 0,89 в тот же месяц, затем 0,85 через месяц |
| тесты 115% | индекс 1,2 за два месяца (`_setIndexStepwise`); `assertEq` на 2 шага и покрытие 100% |
| `testFuzz_RedeemNeverLowersCoverage` | диапазон индекса 0,7–1,1 сохранён, достигается по месяцам |
| дифференциальные и экстремальные (индекс до 1e36) | корзина создаётся сразу с нужным стартовым индексом |
| F-05 и «AtMaxIndex» | вторая корзина со стартовым индексом 1e36 |

## 8. События
Каждое изменение состояния выпускает событие (полный список — `SPEC.md`, раздел 4).

**Stack too deep.** У `Minted` и `Redeemed` 11 полей. Если выпускать их прямо в mint/redeem, компилятор падает с `Stack too deep`. Это проверено на копии контракта: ошибка есть и с оптимизатором, и без него (без оптимизатора собирает `forge coverage`). Выбрано решение без `via_ir`:
- данные операции собираются в memory-структуру `OpLog`;
- событие выпускается в отдельной `private`-функции (`_emitMinted` / `_emitRedeemed`).

Почему не `via_ir`: он меняет кодогенерацию всего контракта (результаты тестов и газ перестают быть сопоставимы с текущими), заметно замедляет компиляцию, а `forge coverage` с via-IR работает с ограничениями. Покрытие после операции вычисляется один раз и передаётся в `_syncTierAt`, поэтому газ лишний раз не тратится.

### 8.1. Таблица «действие → событие → параметры → тест»
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


## 9. Ревью CEI и реентрантности
- `redeem`: проверки → `reserves -= gross` → `burn` → переводы комиссии и выплаты. Это CEI плюс `nonReentrant`.
- `mint`: проверки → `_pull` (перевод внутрь до учёта, нужен для fee-on-transfer) → резерв → комиссия → `mint`. Отступление от CEI сделано намеренно и закрыто `nonReentrant`. View-функции, вызванные из хука во время `_pull`, видят состояние до операции (`test/Reentrancy.t.sol`, CEI views).
- `topUpReserve`, `pokeTier`, `pokeStable` — под `nonReentrant`.
- Вредоносный хук-токен, добавленный через таймлок, не может повторно войти ни в одну из функций mint/redeem/topUp/poke: получает `ReentrancyGuardReentrantCall` (7 тестов).
- Переполнения: Solidity 0.8 + `mulDiv` (512-бит). Цены ограничены 10^36, answer фида — 2^128. Fuzz на экстремумах без Panic.

## 10. Оставшиеся риски и рекомендации перед деплоем
Риски, которые остаются при текущем (зафиксированном) дизайне:
1. **Централизация.** Один ключ owner — это:
   - оракул: 28-го индекс можно сдвинуть до ±11% за раз (см. риск 1a);
   - пауза (можно заблокировать выход);
   - добавление стейблов (через 9 дней);
   - смена фида и ручной цены, а значит и объявление депега.

   Админ токена может выдать `MINTER_ROLE` кому угодно и тем самым получить неограниченную эмиссию.
1a. **Накопленный сдвиг индекса (остаточный риск после v0.4).** Лимит ±11% ограничивает один шаг, но не сумму шагов. Owner или скомпрометированный ключ может двигать индекс в одну сторону каждый месяц:

    | Месяцев | Максимальный рост | Максимальное падение |
    |---|---|---|
    | 2 | ×1,2321 (+23,2%) | ×0,7921 (−20,8%) |
    | 3 | ×1,3676 (+36,8%) | ×0,7050 (−29,5%) |
    | 6 | ×1,8704 (+87,0%) | ×0,4970 (−50,3%) |
    | 12 | ×3,4985 (+249,8%) | ×0,2470 (−75,3%) |

    К этому добавляется рабочая цена ±3% от индекса.

    Что даёт лимит:
    - резкий скачок за одну транзакцию невозможен;
    - у держателей и мониторинга есть минимум месяц на реакцию между шагами;
    - переход FULL ↔ SUSPENDED одним `setIndex` невозможен (140/115 ≈ 1,217 > 1,11).

    Чего лимит не даёт: защиты от устойчивого многомесячного дрейфа. Против него нужны multisig и таймлок для оракула (R-1), публичный мониторинг `IndexUpdated` (R-6) и, при желании, годовой «потолок» (R-2b).
2. **Задержка депега.** Ручная цена и фид обновляются не мгновенно. До обновления можно минтить по старой цене.
3. **Граница 140%.** Крупный держатель может небольшим `topUp` «купить» уровень FULL для своего выкупа. Остальным это не вредит (покрытие только растёт), но стоит учесть в коммуникации.
4. **Сэндвич вокруг смены уровня** (индекс, выкупы других). Защищает `minStableOut`, сайт обязан его передавать.
5. **Блэклист USDT/USDC.** Если в блэклист попадёт `feeRecipient` или Vault, минт и выкуп в этом стейбле остановятся.
6. Ребейзящиеся и хук-токены не поддерживаются: их нельзя добавлять как стейблы.
7. `lastTier` и `lastDepegged` отстают от движения фида, пока кто-то не вызовет `pokeTier`/`pokeStable`. Сам запрет минта и выкупа от этого не зависит.
8. Газ `_coverageBps` растёт с числом стейблов, `_syncAllTiers` — с числом корзин.

Рекомендации (требуют решения Антона):
- R-1: owner — multisig (Safe) + таймлок на смену фида, ручной цены и казны.
- ~~R-2: лимит изменения индекса 28-го числа~~ — **реализовано в v0.4**: ±11% за обновление, константа (раздел 7.1).
- R-2b (новое, по желанию): ограничить и накопленное изменение. Варианты: лимит за скользящие 12 месяцев относительно «якоря», двухшаговая фиксация (объявление + исполнение через N дней) или публикация методики индекса и сверка с ней.
- R-3: внешний аудит независимой фирмой перед деплоем с реальными средствами, после него — bug bounty.
- R-4: staleness фида — по heartbeat конкретного фида Chainlink в целевой сети. Добавить L2 sequencer uptime feed, если сеть — L2.
- R-5: админ `BasketToken` — тот же multisig; после настройки рассмотреть отказ от `DEFAULT_ADMIN_ROLE`.
- R-6: мониторинг событий (бот): `CoverageTierChanged`, `StableDepegStatusChanged`, `IndexUpdated`, `Paused`; регулярный `pokeStable`.
- R-7: ограничить максимальное число стейблов и корзин константой.
- R-8: решить вопрос лицензии (сейчас в файлах SPDX MIT, файла `LICENSE` нет).
- R-9: тестнет-деплой и прогон сценариев на форке целевой сети с реальными USDT/USDC и фидами.

## 11. Ограничения этой проверки
- Проверку провёл автор кода. Взгляда со стороны не было.
- Формальная верификация (Halmos/Certora) и Aderyn не применялись.
- Тесты используют моки токенов и фидов. Реальные USDT/USDC и фиды Chainlink на форке не проверялись.
- Экономические атаки (манипуляция оракулом владельцем, bank run) разобраны только качественно.
- Газ не оптимизировался и не профилировался.

**Это внутренний pre-audit, а не внешний аудит.**
