# 2. Роли и параметры

## 2.1. Роли

| Контракт | Роль | Кто (целевая схема, этап B) | Тестнет v3 (код до этапа B) | Как передаётся |
|---|---|---|---|---|
| `BasketVault` | `owner` (Ownable2Step) | **Safe 2-of-3**: аппаратный ключ Антона, резервный ключ Антона, третий страховочный ключ | Антон (EOA) | `transferOwnership(new)` → `acceptOwnership()` новым владельцем. `renounceOwnership()` всегда ревертится (`RenounceDisabled`) |
| `BasketVault` | `guardian` | **отдельный адрес** (горячий ключ/бот мониторинга), не владелец | — | назначение — через таймлок (`setGuardian`, 2 дня); отзыв — `revokeGuardian()` owner'ом мгновенно |
| `BasketToken` | `DEFAULT_ADMIN_ROLE` | **сам `BasketVault`** | Антон | только через таймлок Vault: `setTokenRole(token, role, account, grant)`, 7 дней |
| `BasketToken` | `MINTER_ROLE` | только `BasketVault` | только `BasketVault` | через `setTokenRole` (7 дней) |
| — | пользователь | любой адрес | любой адрес | — |

Адреса Safe и guardian — параметры деплоя (`OWNER_ADDRESS`, `GUARDIAN_ADDRESS`), в коде не зашиты.

## 2.2. Функции по ролям

Таймлок встроен в Vault: `scheduleOp(data, salt)` (owner) → ожидание → `executeOp(data, salt)` (owner) в окне
`[eta, eta + 14 дней]`; `cancelOp(id)` (owner) отменяет. `data` — calldata вызова самого Vault; `id = keccak256(abi.encode(data, salt))`.
Функции с таймлоком проверяют `msg.sender == address(this)` (`OnlyTimelock`); прямой вызов даже владельцем ревертится.

| Функция | Кто | Задержка | Ограничения |
|---|---|---|---|
| `setIndex(basketId, newIndex)` | owner | нет (но только 28-го) | 28-е число по UTC; один раз в календарный месяц; `ceil(old·0,89) ≤ new ≤ floor(old·1,11)`; `0 < new ≤ 1e36`; сбрасывает рабочую цену на новый индекс; отказ не тратит попытку |
| `setWorkingPrice(basketId, price)` | owner | нет | `index·0,97 ≤ price ≤ index·1,03` (включительно), любой день |
| `addBasket(basketId, token, initialIndex)` | owner | нет | новый id; токен ещё не привязан ни к одной корзине; `0 < index ≤ 1e36`; правило 28-го не действует |
| `proposeStable(stable, feed, maxStaleness)` | owner | — | `decimals ≤ 18`; не включён; повторное предложение перезапускает таймлок |
| `executeStable(stable)` | owner | **9 дней** после `proposeStable` | есть заявка, таймлок истёк |
| `cancelStable(stable)` | owner | нет | есть заявка |
| `setManualPrice(stable, price)` | таймлок | **2 дня** (`PARAM_DELAY`) | стейбл включён; `0 < price ≤ 1e36` |
| `setStableFeed(stable, feed, maxStaleness)` | таймлок | **2 дня** | стейбл включён; `feed = 0` — отключить |
| `setFeeRecipient(addr)` | таймлок | **2 дня** | не 0 и не сам Vault |
| `setGuardian(addr)` | таймлок | **2 дня** | `0` — без guardian |
| `setSequencerUptimeFeed(addr)` | таймлок | **2 дня** | `0` — проверка секвенсора выключена |
| `setTokenRole(token, role, account, grant)` | таймлок | **7 дней** (`ROLE_DELAY`) | токен зарегистрирован в Vault |
| `revokeGuardian()` | owner | нет | только уменьшает права |
| `setMinMintUsd(newMin)` | owner | нет | `$50 ≤ newMin ≤ $1000` (18 знаков) |
| `pause()` | owner **или guardian** | нет | длится не дольше **30 дней** и снимается сама; продлить нельзя; новая пауза не раньше **3 дней** после окончания предыдущей (`PauseCooldown`) |
| `unpause()` | только owner | нет | досрочно снимает паузу; с этого момента идёт кулдаун 3 дня |
| `scheduleOp` / `executeOp` / `cancelOp` | owner | см. выше | селектор должен быть в списке таймлока (`NotTimelockable`) |
| `transferOwnership` / `acceptOwnership` | owner / новый owner | двухшагово | — |
| `mint(basketId, stable, amount, minTokensOut)` | любой | — | не пауза; секвенсор работает > 1 ч (если фид задан); стейбл включён и не в депеге; если у стейбла есть фид — он валиден (`FeedUnavailable`); `≥ minMintUsd`; `tokensOut ≥ minTokensOut` |
| `redeem(basketId, stable, tokenAmount, minStableOut)` | любой | — | те же проверки паузы/секвенсора/фида; уровень не Suspended; хватает резерва этого стейбла; `out ≥ minStableOut` |
| `topUpReserve(basketId, stable, amount)` | любой | — | работает и на паузе, и при упавшем секвенсоре; токены не выпускаются |
| `pokeTier(basketId)`, `pokeStable(stable)` | любой | — | только пересчёт и события |
| `BasketToken.mint/burn` | `MINTER_ROLE` | — | `burn` без allowance |

Почему `setIndex`/`setWorkingPrice` без таймлока: объявленный заранее индекс — бесплатный опцион против резервов
(купить до роста, выкупить до падения; угроза T4). Их защищают константы ±11%/±3%, правило «28-го, раз в месяц» и Safe 2-of-3.
`addBasket` и `setMinMintUsd` без таймлока: не затрагивают существующих держателей и ограничены константами.

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
| `PARAM_DELAY` | 2 дня | таймлок параметров (ручная цена, фид, казна, guardian, фид секвенсора) |
| `ROLE_DELAY` | 7 дней | таймлок ролей токена |
| `OP_EXPIRY` | 14 дней | окно исполнения операции после `eta` |
| `MAX_PAUSE_DURATION` | 30 дней | максимум одной паузы |
| `PAUSE_COOLDOWN` | 3 дня | минимальный промежуток между паузами (окно выхода) |
| `SEQUENCER_GRACE_PERIOD` | 3600 с | ожидание после восстановления секвенсора L2 |
| `MIN_MINT_LOWER` / `MIN_MINT_UPPER` | $50 / $1000 | допустимый диапазон `minMintUsd` |
| `FULL_REDEEM_COVERAGE_BPS` | 14000 (140%) | порог уровня Full |
| `MIN_REDEEM_COVERAGE_BPS` | 11500 (115%) | порог приостановки выкупа |
| `FEED_GAS_LIMIT` | 100 000 | газ на чтение фида |
| `MAX_FEED_ANSWER` | 2^128 − 1 | максимум ответа фида |
| `MAX_PRICE` | 1e36 | максимум индекса и ручной цены |

## 2.4. Изменяемые параметры

| Параметр | Тестнет v3 | Целевое значение (mainnet) | Пределы | Кто меняет |
|---|---|---|---|---|
| `minMintUsd` | $50 | $50 | $50–$1000 | owner |
| `feeRecipient` | Антон `0x5453…0F06` | казна (решает Антон) | ≠0, ≠Vault | таймлок 2 дня |
| `guardian` | — (в v3 нет) | отдельный адрес | любой или 0 | таймлок 2 дня / мгновенный отзыв |
| `sequencerUptimeFeed` | — (в v3 нет; в v4 — 0) | Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` (документация Chainlink, сверить перед деплоем) | любой или 0 | таймлок 2 дня |
| индекс корзины 1 | 1,6658 (`1665800000000000000`) | по методике | ±11% за обновление, 28-го | owner |
| рабочая цена корзины 1 | 1,6658 | — | ±3% от индекса | owner |
| ручная цена стейбла | $1 (`1e18`) | $1 | (0, 1e36] | таймлок 2 дня |
| фид стейбла | нет (`address(0)`) | Chainlink USDT/USD, USDC/USD | любой адрес или 0 | таймлок 2 дня |
| v5: `mintLimits.floorBps` | — | 15 000 (150%) | 14 000–20 000 | таймлок 2 дня |
| v5: `mintLimits.taperBps` | — | 16 000 (160%) | floor…floor+3 000 | таймлок 2 дня |
| v5: `mintLimits.hourCapBps` | — | 1 000 (10% резерва/ч) | 100–5 000 | таймлок 2 дня |
| v5: `mintLimits.blockCapBps` | — | 500 (5% резерва/блок) | 10…hourCap | таймлок 2 дня |

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
