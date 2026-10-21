# BasketCoin — эксплуатация на Base Sepolia

Тестнет-руководство: деплой, верификация, ежемесячное обновление индекса и операции владельца.
Сеть: **Base Sepolia**, chainId `84532`, RPC `https://sepolia.base.org`,
эксплореры: [Basescan](https://sepolia.basescan.org) и [Blockscout](https://base-sepolia.blockscout.com).

Адреса после деплоя — в `deployments/base-sepolia.json`. Ниже используются переменные:

```bash
export RPC=https://sepolia.base.org
export VAULT=0x...        # BasketVault
export TOKEN=0x...        # BasketToken (BKT)
export USDT=0x...         # TestUSDT
export USDC=0x...         # TestUSDC
export OWNER=0x...        # владелец Vault (оракул)
# или сразу из файла:
# VAULT=$(jq -r .BasketVault deployments/base-sepolia.json); TOKEN=$(jq -r .BasketToken deployments/base-sepolia.json)
# USDT=$(jq -r .TestUSDT deployments/base-sepolia.json);   USDC=$(jq -r .TestUSDC deployments/base-sepolia.json)
```

## 1. Единицы

| Величина | Масштаб | Пример |
|---|---|---|
| Индекс, рабочая цена, ручная цена стейбла | USD × 1e18 | `1.0234` → `1023400000000000000` |
| Минимальный минт | USD × 1e18 | `$50` → `50000000000000000000` |
| Суммы TestUSDT/TestUSDC | 6 знаков | `1000` → `1000000000` |
| BasketCoin (BKT) | 18 знаков | |
| Покрытие | bps | `12000` = 120% |

Перевод: `cast to-wei 1.0234` → `1023400000000000000`; обратно `cast from-wei 1023400000000000000`.

## 2. Деплой

Ключ деплоера хранится вне репозитория (`/home/box/.secrets/basketcoin-deployer.env`, `DEPLOYER_PK`).
Никогда не коммитьте ключ и не печатайте его.

```bash
set -a; . /home/box/.secrets/basketcoin-deployer.env; set +a
# OWNER_ADDRESS    — владелец/оракул (в mainnet — Safe 2-of-3); FEE_RECIPIENT по умолчанию = OWNER_ADDRESS
# GUARDIAN_ADDRESS — отдельный адрес, который может только поставить паузу (по умолчанию — нет)
# SEQUENCER_UPTIME_FEED — Chainlink L2 Sequencer Uptime Feed; в тестнете 0 (по умолчанию),
#                    в Base mainnet — только адрес из официальной документации Chainlink
#                    (на 19.10.2026: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433 — сверить перед деплоем)
OWNER_ADDRESS=<SAFE_ИЛИ_EOA> GUARDIAN_ADDRESS=<GUARDIAN> SEQUENCER_UPTIME_FEED=0x0000000000000000000000000000000000000000 \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --slow
```

Сухой прогон всего сценария на локальном форке (ничего не отправляет в сеть):
```bash
set -a; . /home/box/.secrets/basketcoin-deployer.env; set +a
OWNER_ADDRESS=0x54534F6EE2Da9dC9fb06d64617CE9301253E0F06 script/dry-run-anvil.sh
```

Скрипт деплоит TestUSDT, TestUSDC, BasketToken (BKT), BasketVault, выдаёт Vault роль `MINTER_ROLE`,
создаёт корзину `1` со стартовым индексом `1.00` и записывает адреса в `deployments/base-sepolia.json`.
Фидов у стейблов нет: Vault использует ручную цену `$1` (меняется через таймлок, §6a).

Передача прав:
- **Vault** (Ownable2Step): если `OWNER_ADDRESS` ≠ деплоер, скрипт вызывает `transferOwnership(OWNER)`. Владельцем остаётся
  деплоер, пока OWNER не вызовет `acceptOwnership()` (§7). Проверка: `cast call $VAULT "pendingOwner()(address)" --rpc-url $RPC`.
- **BasketToken** (AccessControl): `DEFAULT_ADMIN_ROLE` всегда получает **сам Vault**, деплоер от неё отказывается.
  Дальше роли токена меняются только через таймлок Vault (`setTokenRole`, 7 дней, §6a). `MINTER_ROLE` — у Vault.
- `guardian` и `sequencerUptimeFeed` задаются в конструкторе; скрипт проверяет их после деплоя и пишет в JSON.

Сухая проверка без отправки: та же команда без `--broadcast` и с `DEPLOYMENTS_FILE=deployments/sim.local.json`
(иначе симуляция перезапишет `deployments/base-sepolia.json` предсказанными адресами). Для симуляции у деплоера
должен быть небольшой баланс ETH.

## 3. Верификация исходников (без API-ключа)

```bash
script/verify.sh                    # Blockscout + Sourcify
DRY_RUN=1 script/verify.sh          # только собрать standard-json и показать команды
```

После этого вкладки **Read / Write contract** доступны на Blockscout
(`https://base-sepolia.blockscout.com/address/$VAULT?tab=write_contract`) и работают с MetaMask.

**Basescan** не принимает верификацию без ключа. Бесплатный ключ Etherscan API v2 (подходит для Base):
```bash
forge verify-contract $VAULT src/BasketVault.sol:BasketVault --chain 84532 --verifier etherscan \
  --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,uint256)" $DEPLOYER $FEE $USDT $USDC 50000000000000000000)
```

## 4. Ежемесячное обновление индекса (`setIndex`)

`setIndex(uint256 basketId, uint256 newIndex)` — только владелец.

Правила (проверяет контракт):
1. Только **28-го числа по UTC** (по времени блока). 28-е 00:00 UTC = 28-е 07:00 по Вьетнаму; окно
   заканчивается 29-го в 06:59 по Вьетнаму.
2. Один раз в календарный месяц (`IndexAlreadyUpdatedThisMonth`). Отклонённая транзакция попытку не тратит.
3. Не дальше **±11%** от предыдущего индекса: `ceil(old × 0,89) ≤ newIndex ≤ floor(old × 1,11)`
   (`IndexChangeTooLarge`).
4. `0 < newIndex ≤ 1e36`. Рабочая цена сбрасывается на новый индекс.

Проверка до отправки:
```bash
cast call $VAULT "indexBounds(uint256)(uint256,uint256)" 1 --rpc-url $RPC        # min, max включительно
cast call $VAULT "baskets(uint256)(address,uint256,uint256,uint256,uint64,bool)" 1 --rpc-url $RPC
date -u -d @$(cast block latest -f timestamp --rpc-url $RPC)                     # дата блока по UTC
```

### Вариант A — скрипт (проверки + отправка)
```bash
# только проверка (ничего не отправляет):
VAULT=$VAULT NEW_INDEX=$(cast to-wei 1.0234) forge script script/UpdateIndex.s.sol --rpc-url $RPC
# отправка с Ledger:
VAULT=$VAULT NEW_INDEX=$(cast to-wei 1.0234) forge script script/UpdateIndex.s.sol --rpc-url $RPC \
  --broadcast --ledger --sender $OWNER
# отправка с ключом, введённым вручную (не сохраняется в истории shell):
VAULT=$VAULT NEW_INDEX=$(cast to-wei 1.0234) forge script script/UpdateIndex.s.sol --rpc-url $RPC \
  --broadcast --interactives 1 --sender $OWNER
# или зашифрованный keystore: cast wallet import owner --interactive; затем --account owner --sender $OWNER
```
Скрипт печатает дату UTC, текущий индекс, допустимые границы и падает до отправки, если правило нарушено.

### Вариант B — cast send
```bash
cast send $VAULT "setIndex(uint256,uint256)" 1 $(cast to-wei 1.0234) --rpc-url $RPC --ledger
cast send $VAULT "setIndex(uint256,uint256)" 1 $(cast to-wei 1.0234) --rpc-url $RPC --interactive
cast send $VAULT "setIndex(uint256,uint256)" 1 $(cast to-wei 1.0234) --rpc-url $RPC --account owner
```

### Вариант C — MetaMask через эксплорер
После верификации: Blockscout (или Basescan, если верифицирован там) → адрес Vault → **Write contract** →
**Connect wallet** (MetaMask, сеть Base Sepolia, аккаунт владельца) → `setIndex`:
`basketId = 1`, `newIndex = 1023400000000000000` (целое число, 18 знаков, без точки) → Write → подтвердить в MetaMask.

### Вариант D — Safe multisig
Если владелец — Safe (`OWNER_ADDRESS` = адрес Safe; Safe поддерживает Base Sepolia на app.safe.global):
1. app.safe.global → Safe → **New transaction → Transaction Builder**.
2. Address: `$VAULT`; ABI — из `out/BasketVault.sol/BasketVault.json` (`jq .abi`) или подтянется
   автоматически после верификации.
3. Метод `setIndex`, `basketId = 1`, `newIndex = 1023400000000000000` → Add → Create batch → подписи владельцев → Execute.
   Исполнение должно попасть в 28-е UTC — соберите подписи заранее и исполните 28-го.
   Либо вставьте готовый calldata: `cast calldata "setIndex(uint256,uint256)" 1 1023400000000000000`.

## 5. Рабочая цена между обновлениями (`setWorkingPrice`, ±3%)

```bash
cast send $VAULT "setWorkingPrice(uint256,uint256)" 1 $(cast to-wei 1.0300) --rpc-url $RPC --ledger
```
Допустимо `index × 0,97 ≤ price ≤ index × 1,03` (включительно), иначе `PriceOutOfBand`. В любой день месяца.

## 6. Пауза

```bash
cast send $VAULT "pause()"   --rpc-url $RPC --ledger      # owner или guardian; останавливает весь минт и выкуп
cast send $VAULT "unpause()" --rpc-url $RPC --ledger      # только owner
cast call $VAULT "paused()(bool)" --rpc-url $RPC
cast call $VAULT "pausedUntil()(uint64)" --rpc-url $RPC   # когда пауза снимется сама
cast send $VAULT "revokeGuardian()" --rpc-url $RPC --ledger   # owner: мгновенно отозвать guardian
```
Правила (код этапа B; в v3 их нет): пауза длится не дольше 30 дней и снимается сама, продлить нельзя (`EnforcedPause`);
новую паузу можно поставить не раньше чем через 3 дня после окончания предыдущей (`PauseCooldown`) — это окно выхода для держателей.

## 6a. Таймлок админских функций (код этапа B)

| Функция | Задержка |
|---|---|
| `setManualPrice`, `setStableFeed`, `setFeeRecipient`, `setGuardian`, `setSequencerUptimeFeed` | 2 дня |
| `setTokenRole(token, role, account, grant)` | 7 дней |

Прямой вызов этих функций ревертится `OnlyTimelock`. Порядок (через Safe — те же два вызова как транзакции Safe):
```bash
DATA=$(cast calldata "setManualPrice(address,uint256)" $USDT $(cast to-wei 0.94))
SALT=0x0000000000000000000000000000000000000000000000000000000000000000
cast send $VAULT "scheduleOp(bytes,bytes32)" $DATA $SALT --rpc-url $RPC --ledger    # шаг 1, событие OpScheduled(id, …, eta)
cast call $VAULT "opEta(bytes32)(uint256)" $(cast call $VAULT "opId(bytes,bytes32)(bytes32)" $DATA $SALT --rpc-url $RPC) --rpc-url $RPC
cast send $VAULT "executeOp(bytes,bytes32)" $DATA $SALT --rpc-url $RPC --ledger     # шаг 2: в окне [eta, eta + 14 дней]
cast send $VAULT "cancelOp(bytes32)" <ID> --rpc-url $RPC --ledger                    # отмена до исполнения
```
`setIndex`, `setWorkingPrice`, `setMinMintUsd`, `addBasket`, `proposeStable`/`executeStable` (свой таймлок 9 дней) — без этого таймлока.

Ручная цена стейбла (USD × 1e18) влияет на `mint`/`redeem` только у стейбла **без** фида. Если фид задан, но недоступен или
устарел, `mint`/`redeem` в этом стейбле ревертят `FeedUnavailable` (откат на ручную цену — только во view и в оценке покрытия).
Экстренная реакция на депег/сбой — пауза (owner или guardian), затем смена фида/цены через таймлок.

## 6b. L2 sequencer (Base)
Если задан `sequencerUptimeFeed`, `mint`/`redeem` ревертят `SequencerDown`, пока секвенсор не работает, и `SequencerGracePeriod`
в течение 1 ч после восстановления. `topUpReserve` и view-функции не зависят от секвенсора. В тестнете фид = 0 (проверка выключена).
Пополнение резерва (`topUpReserve`) и пересчёт уровня (`pokeTier`, `pokeStable`) может вызвать кто угодно.

## 7. Принятие владения

```bash
cast call $VAULT "pendingOwner()(address)" --rpc-url $RPC
cast send $VAULT "acceptOwnership()" --rpc-url $RPC --ledger          # с адреса нового владельца
cast call $VAULT "owner()(address)" --rpc-url $RPC
```
Через MetaMask/Safe — метод `acceptOwnership` без параметров. Отказ от владения (`renounceOwnership`) запрещён контрактом.

## 8. Для тестировщиков: кран → approve → mint → redeem

```bash
cast send $USDT "faucet(uint256)" 10000000000 --rpc-url $RPC --interactive        # 10 000 tUSDT (максимум за вызов)
cast send $USDT "approve(address,uint256)" $VAULT 1000000000 --rpc-url $RPC --interactive
cast call $VAULT "previewMint(uint256,address,uint256)(uint256)" 1 $USDT 1000000000 --rpc-url $RPC
cast send $VAULT "mint(uint256,address,uint256,uint256)" 1 $USDT 1000000000 0 --rpc-url $RPC --interactive
cast call $VAULT "quoteRedeem(uint256,address,uint256)" 1 $USDT <BKT_WEI> --rpc-url $RPC
cast send $VAULT "redeem(uint256,address,uint256,uint256)" 1 $USDT <BKT_WEI> 0 --rpc-url $RPC --interactive
```
`minTokensOut` / `minStableOut` = 0 только для теста; на сайте подставляйте значение из preview с допуском.
Минимальный минт — $50.

## 9. Ошибки (селекторы)

| Селектор | Ошибка |
|---|---|
| `0x94aa9dfd` | `NotIndexDay(uint256)` — не 28-е UTC |
| `0xb265ea12` | `IndexAlreadyUpdatedThisMonth()` |
| `0xac013b6a` | `IndexChangeTooLarge(uint256,uint256,uint256,uint256,uint256)` — вне ±11% |
| `0x3158719a` | `PriceOutOfBand(uint256,uint256)` — рабочая цена вне ±3% |
| `0x52dbbfd2` | `StableDepegged(address,uint256)` |
| `0xd93c0665` | `EnforcedPause()` |
| `0x1c0be90a` | `OnlyTimelock()` — функция только через `scheduleOp`/`executeOp` |
| `0xb92891d9` | `NotTimelockable(bytes4)` |
| `0xe552c2e3` | `OpNotReady(bytes32,uint256)` — задержка не прошла |
| `0x8ac36056` | `OpExpired(bytes32,uint256)` — прошло > 14 дней после eta |
| `0xa1548481` | `OpNotScheduled(bytes32)` |
| `0x4bc38916` | `OpAlreadyScheduled(bytes32)` |
| `0x6b1883f3` | `NotOwnerOrGuardian(address)` |
| `0x40445cac` | `PauseCooldown(uint256)` |
| `0x032b3d00` | `SequencerDown()` |
| `0x02047455` | `SequencerGracePeriod(uint256)` |
| `0xc98b3832` | `SequencerFeedInvalid()` |
| `0x9375b55d` | `FeedUnavailable(address)` |
| `0xddef98d7` | `TokenNotRegistered(address)` |
| `0xace70cbd` | `FaucetAmountInvalid(uint256,uint256)` — кран: 0 или > 10 000 |

Расшифровка любой ошибки: `cast decode-error <data> --sig "<Сигнатура>"` или `cast 4byte <selector>`.
