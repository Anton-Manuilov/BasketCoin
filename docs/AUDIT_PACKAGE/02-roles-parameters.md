# 2. Роли и параметры

## 2.1. Роли

| Контракт | Роль | Кто сейчас (тестнет) | Как передаётся |
|---|---|---|---|
| `BasketVault` | `owner` (Ownable2Step) | деплоер до `acceptOwnership`, затем Антон | `transferOwnership(new)` → `acceptOwnership()` новым владельцем. `renounceOwnership()` всегда ревертится (`RenounceDisabled`) |
| `BasketToken` | `DEFAULT_ADMIN_ROLE` | Антон | `grantRole`/`revokeRole`/`renounceRole` (OpenZeppelin AccessControl, одношагово) |
| `BasketToken` | `MINTER_ROLE` | только `BasketVault` | выдаёт админ токена |
| — | пользователь | любой адрес | — |

## 2.2. Функции по ролям

| Функция | Кто | Задержка | Ограничения |
|---|---|---|---|
| `setIndex(basketId, newIndex)` | owner | нет (но только 28-го) | 28-е число по UTC; один раз в календарный месяц; `ceil(old·0,89) ≤ new ≤ floor(old·1,11)`; `0 < new ≤ 1e36`; сбрасывает рабочую цену на новый индекс; отказ не тратит попытку |
| `setWorkingPrice(basketId, price)` | owner | нет | `index·0,97 ≤ price ≤ index·1,03` (включительно), любой день |
| `addBasket(basketId, token, initialIndex)` | owner | нет | новый id; токен ещё не привязан ни к одной корзине; `0 < index ≤ 1e36`; правило 28-го не действует |
| `proposeStable(stable, feed, maxStaleness)` | owner | — | `decimals ≤ 18`; не включён; повторное предложение перезапускает таймлок |
| `executeStable(stable)` | owner | **9 дней** после `proposeStable` | есть заявка, таймлок истёк |
| `cancelStable(stable)` | owner | нет | есть заявка |
| `setManualPrice(stable, price)` | owner | нет | стейбл включён; `0 < price ≤ 1e36` |
| `setStableFeed(stable, feed, maxStaleness)` | owner | нет | стейбл включён; `feed = 0` — отключить |
| `setMinMintUsd(newMin)` | owner | нет | `$50 ≤ newMin ≤ $1000` (18 знаков) |
| `setFeeRecipient(addr)` | owner | нет | не 0 и не сам Vault |
| `pause()` / `unpause()` | owner | нет | останавливает `mint` и `redeem` (не `topUpReserve`/`poke*`) |
| `transferOwnership` / `acceptOwnership` | owner / новый owner | двухшагово | — |
| `mint(basketId, stable, amount, minTokensOut)` | любой | — | не пауза; стейбл включён и не в депеге; `≥ minMintUsd` (по `min(p,$1)` до комиссии); `tokensOut ≥ minTokensOut` |
| `redeem(basketId, stable, tokenAmount, minStableOut)` | любой | — | не пауза; не депег; уровень не Suspended; хватает резерва этого стейбла; `out ≥ minStableOut` |
| `topUpReserve(basketId, stable, amount)` | любой | — | работает и на паузе; токены не выпускаются |
| `pokeTier(basketId)`, `pokeStable(stable)` | любой | — | только пересчёт и события |
| `BasketToken.mint/burn` | `MINTER_ROLE` | — | `burn` без allowance |

## 2.3. Константы (в коде, менять нельзя)

| Константа | Значение | Смысл |
|---|---|---|
| `FEE_BPS` | 30 (0,3%) | комиссия минта и выкупа, `ceil`, уходит на `feeRecipient` |
| `BUFFER_BPS` | 2000 (20%) | переколлатерализация: при минте `tokens = net·min(p,$1) / (P·1,2)` |
| `MAX_DRIFT_BPS` | 300 (±3%) | коридор рабочей цены вокруг индекса |
| `MAX_INDEX_CHANGE_BPS` | 1100 (±11%) | лимит изменения индекса за одно обновление |
| `INDEX_UPDATE_DAY` | 28 | день обновления (UTC) |
| `DEPEG_BPS` | 500 (±5%) | порог депега стейбла относительно $1 |
| `STABLE_TIMELOCK` | 9 дней | таймлок добавления стейбла |
| `MIN_MINT_LOWER` / `MIN_MINT_UPPER` | $50 / $1000 | допустимый диапазон `minMintUsd` |
| `FULL_REDEEM_COVERAGE_BPS` | 14000 (140%) | порог уровня Full |
| `MIN_REDEEM_COVERAGE_BPS` | 11500 (115%) | порог приостановки выкупа |
| `FEED_GAS_LIMIT` | 100 000 | газ на чтение фида |
| `MAX_FEED_ANSWER` | 2^128 − 1 | максимум ответа фида |
| `MAX_PRICE` | 1e36 | максимум индекса и ручной цены |

## 2.4. Изменяемые параметры

| Параметр | Сейчас (тестнет v3) | Пределы | Кто меняет |
|---|---|---|---|
| `minMintUsd` | $50 | $50–$1000 | owner |
| `feeRecipient` | Антон `0x5453…0F06` | ≠0, ≠Vault | owner |
| индекс корзины 1 | 1,6658 (`1665800000000000000`) | ±11% за обновление, 28-го | owner |
| рабочая цена корзины 1 | 1,6658 | ±3% от индекса | owner |
| ручная цена стейбла | $1 (`1e18`) | (0, 1e36] | owner |
| фид стейбла | нет (`address(0)`) | любой адрес или 0 | owner |

## 2.5. Уровни выкупа (`redeemTier(basketId)`)

Покрытие `coverage = Σ reserve_i·min(p_i,$1) / (totalSupply·P)`, в bps, округление вниз; при нулевом supply — бесконечное (Full).
Уровень определяется по покрытию **до** операции.

| Значение | Уровень | Покрытие | Выкуп |
|---|---|---|---|
| 0 | `Suspended` | < 115% | запрещён (`RedemptionSuspended`), снимается автоматически |
| 1 | `Standard` | 115% ≤ c < 140% | `tokens·P` в USD — без буфера |
| 2 | `Full` | ≥ 140% | `tokens·P·1,2` — с буфером |

Границы: ровно 115% → Standard, ровно 140% → Full. Выплата в стейбле `gross = floor(usd / max(p,$1))`, комиссия `ceil(gross·0,3%)`.
Сразу после первого минта покрытие = 120% (Standard).

## 2.6. События
Полная таблица «действие → событие → параметры → тест» — `AUDIT_REPORT.md` §8.1.
