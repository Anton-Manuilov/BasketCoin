# 4. Покрытие тестами и Slither

Коммит `ab144a7` (этап B; хеши — `appendix/scope.sha256`), прогон 19.10.2026 на forge 1.8.5 / solc 0.8.24. Сырые выводы: [`appendix/coverage.txt`](appendix/coverage.txt),
[`appendix/slither.txt`](appendix/slither.txt).

## 4.1. Тесты
- 230 тестов в 16 наборах (из них 26 — `test/unit/StageB.t.sol`: guardian, истечение и кулдаун паузы, таймлок, роли токена, sequencer) — все проходят в обычном режиме (fuzz 256) и в профиле `ci` (fuzz 10 000, инварианты 1000 прогонов × 200 вызовов).
- Типы: unit-тесты граничных случаев (ровно 115%/140%, ±11%, ±3%, $50/$1000, 9 дней, 28-е/29.02), fuzz, 12 stateful-инвариантов
  (покрытие, «нет прибыли от цикла», учёт резервов и др.), дифференциальные тесты (`Math.mulDiv`, BokkyPooBah DateTime),
  тест реентрантности токеном с хуком, тесты всех событий со всеми параметрами, тесты скрипта деплоя.
- Мутационная проверка и список исправленных проблем — `AUDIT_REPORT.md` §5 и §7.

## 4.2. Покрытие (`forge coverage`, без test/lib/script)

| Файл | Строки | Операторы | Ветвления | Функции |
|---|---|---|---|---|
| `src/BasketToken.sol` | 100% (7/7) | 100% (4/4) | 100% (2/2) | 100% (3/3) |
| `src/BasketVault.sol` | 100% (394/394) | 99,60% (499/501) | 97,67% (84/86) | 100% (67/67) |
| `src/libraries/DateLib.sol` | 100% (14/14) | 100% (27/27) | 100% (3/3) | 100% (1/1) |
| `src/testnet/TestStablecoins.sol` (вне scope) | 100% (9/9) | 100% (7/7) | 100% (1/1) | 100% (5/5) |
| **Итого** | **100% (424/424)** | **99,63% (537/539)** | **97,83% (90/92)** | **100% (76/76)** |

Две непокрытые ветви:

| Строка | Код | Разбор |
|---|---|---|
| `BasketVault.sol:777` | `if (tokensOut == 0) revert ZeroAmount();` в `mint` | Защитная проверка, **недостижима** при текущих константах: минимальный минт ≥ $50, индекс ≤ 1e36, поэтому `tokensOut ≥ 50e18·1e18/(1e36·1,2) ≈ 41 > 0`. Оставлена на случай изменения констант |
| `BasketVault.sol:999` | `if (stables[stable].enabled) revert StableAlreadyEnabled(stable);` в `_addStable` | Достижима только из конструктора (USDT = USDC). Тест есть: `test/unit/Admin.t.sol::test_Constructor_ZeroAndDuplicateStables`. Forge не засчитывает ветви в отменённом (revert) конструкторе — это артефакт инструмента. Из `executeStable` ветвь недостижима: `proposeStable` отклоняет уже включённый стейбл, а включить стейбл в обход заявки нельзя |

## 4.3. Slither 0.11.6

Команда: `slither . --filter-paths "lib/|test/|script/" --exclude-dependencies`.
Итог: **0 High, 0 Medium**, 13 Low, 2 Informational (15 результатов; было 10). `missing-zero-check` для `setGuardian`/`setSequencerUptimeFeed` подавлен: `0` означает «выключено». В коде есть точечные подавления `slither-disable-next-line`
с обоснованием (в той же строке комментария); они перечислены в `AUDIT_REPORT.md` §6.

| # | Детектор | Уровень | Где | Разбор | Решение |
|---|---|---|---|---|---|
| 1–3 | `calls-loop` | Low | `_coverageBps` вызывает `token.totalSupply()` в цикле `_syncAllTiers` (из `setManualPrice`, `setStableFeed`, `pokeStable`) | `totalSupply` — view доверенного `BasketToken`; цикл по корзинам, их добавляет только owner. Риск — только газ при большом числе корзин | Принято. Рекомендация R-7: константный максимум корзин и стейблов |
| 4 | `reentrancy-benign` | Low | `mint`: после `b.token.mint` пишутся `lastDepegged`, `lastTier` | Функция под `nonReentrant`; вызов к доверенному токену без хуков; поля только для событий, на расчёты не влияют. Перевод стейбла от пользователя (`_pull`) идёт до эффектов, потому что нужно учесть фактически полученную сумму | Принято |
| 5 | `reentrancy-benign` | Low | `redeem`: после `b.token.burn` пишутся `lastDepegged`, `lastTier` | Резерв уменьшен и токены сожжены до переводов (CEI); `nonReentrant`; поля только для событий | Принято |
| 6a | `timestamp` | Low | `pause`, `paused` | Истечение паузы (30 дней) и кулдаун (3 дня); сдвиг в секунды несущественен | Принято |
| 6b | `timestamp` | Low | `executeOp` | Окно `[eta, eta+14 дней]`, задержки 2/7 дней | Принято |
| 6c | `timestamp` | Low | `_checkSequencer` | Grace 3600 с от `startedAt` фида секвенсора — по рекомендации Chainlink | Принято |
| 6d | `timestamp` | Low | `quoteRedeem` | Через `paused()` (истечение паузы) | Принято |
| 6 | `timestamp` | Low | `_readFeed`: проверка `updatedAt` против `block.timestamp` | Проверка свежести фида требует времени блока; сдвиг валидатором — секунды при `maxFeedStaleness` в часах | Принято |
| 7 | `timestamp` | Low | `executeStable`: `block.timestamp < executeAfter` | Таймлок 9 дней; сдвиг в секунды несущественен | Принято |
| 8 | `timestamp` | Low | `setIndex`: день месяца и ключ месяца из `block.timestamp` | Правило «28-го UTC» по определению зависит от времени блока; окно — сутки | Принято |
| 9–10 | `assembly` | Info | `_staticcallWords5`, `_staticcallWord` | Намеренно: чтение фида без «return bomb», с лимитом газа и фиксированным буфером ответа. Покрыто тестами со сломанными фидами (`test/unit/Oracle.t.sol`) | Принято, просим аудиторов проверить отдельно |

## 4.4. Что просим проверить в первую очередь
1. Математика покрытия и уровней (`_coverageBps`, `_tierOf`, `_quoteRedeem`) и утверждение «разрешённый выкуп не уменьшает покрытие остальных».
2. Цена стейбла: `min(p,$1)` при минте и в покрытии, `max(p,$1)` при выкупе; строгий фид в `mint`/`redeem` и откат на ручную цену только во view/покрытии.
2a. Таймлок: `executeOp` → `Address.functionCall(address(this), data)`, белый список селекторов `opDelay`, `onlyTimelock`; пауза с истечением и кулдауном (переопределён `paused()`); `_checkSequencer`.
3. Ассемблер чтения фида.
4. `DateLib` и правило 28-го.
5. Централизация (раздел 1, T1–T2) и план перехода (раздел 5).
