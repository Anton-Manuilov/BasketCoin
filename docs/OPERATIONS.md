# BasketCoin — эксплуатация на Base Sepolia

Тестнет-руководство: деплой, верификация, ежемесячное обновление индекса и операции владельца.
Сеть: **Base Sepolia**, chainId `84532`, RPC `https://sepolia.base.org`,
эксплореры: [Basescan](https://sepolia.basescan.org) и [Blockscout](https://base-sepolia.blockscout.com).

Адреса после деплоя — в `deployments/base-sepolia.json`. Ниже используются переменные:

```bash
export RPC=https://sepolia.base.org
export VAULT=0x...        # BasketVault
export TOKEN=0x...        # BasketToken (BSKT)
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
| BasketCoin (BSKT) | 18 знаков | |
| Покрытие | bps | `12000` = 120% |

Перевод: `cast to-wei 1.0234` → `1023400000000000000`; обратно `cast from-wei 1023400000000000000`.

## 2. Деплой

Ключ деплоера хранится вне репозитория (`/home/box/.secrets/basketcoin-deployer.env`, `DEPLOYER_PK`).
Никогда не коммитьте ключ и не печатайте его.

```bash
set -a; . /home/box/.secrets/basketcoin-deployer.env; set +a
# OWNER_ADDRESS — владелец/оракул; FEE_RECIPIENT по умолчанию = OWNER_ADDRESS (без обоих — адрес деплоера)
OWNER_ADDRESS=0x54534F6EE2Da9dC9fb06d64617CE9301253E0F06 \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --slow
```

Сухой прогон всего сценария на локальном форке (ничего не отправляет в сеть):
```bash
set -a; . /home/box/.secrets/basketcoin-deployer.env; set +a
OWNER_ADDRESS=0x54534F6EE2Da9dC9fb06d64617CE9301253E0F06 script/dry-run-anvil.sh
```

Скрипт деплоит TestUSDT, TestUSDC, BasketToken (BSKT), BasketVault, выдаёт Vault роль `MINTER_ROLE`,
создаёт корзину `1` со стартовым индексом `1.00` и записывает адреса в `deployments/base-sepolia.json`.
Фидов у стейблов нет: Vault использует ручную цену `$1` (её можно менять, см. §6).

Если `OWNER_ADDRESS` отличается от деплоера:
- **Vault** (Ownable2Step): скрипт вызывает `transferOwnership(OWNER)`. Владельцем остаётся деплоер,
  пока OWNER не вызовет `acceptOwnership()` (§7). Проверка: `cast call $VAULT "pendingOwner()(address)" --rpc-url $RPC`.
- **BasketToken** (AccessControl): скрипт выдаёт OWNER `DEFAULT_ADMIN_ROLE`, а деплоер отказывается от неё
  (`renounceRole`). Это одношаговая передача — дважды проверьте `OWNER_ADDRESS` (для Safe — адрес Safe на Base Sepolia).
  `MINTER_ROLE` у Vault остаётся.

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

## 6. Пауза и ручная цена стейбла

```bash
cast send $VAULT "pause()"   --rpc-url $RPC --ledger      # останавливает весь минт и выкуп
cast send $VAULT "unpause()" --rpc-url $RPC --ledger
cast call $VAULT "paused()(bool)" --rpc-url $RPC

# ручная цена стейбла (USD × 1e18). Отклонение > ±5% от $1 = депег: минт/выкуп только в этом стейбле останавливаются
cast send $VAULT "setManualPrice(address,uint256)" $USDT $(cast to-wei 0.94) --rpc-url $RPC --ledger
cast call $VAULT "isDepegged(address)(bool)" $USDT --rpc-url $RPC
cast send $VAULT "setManualPrice(address,uint256)" $USDT $(cast to-wei 1) --rpc-url $RPC --ledger
```
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
cast call $VAULT "quoteRedeem(uint256,address,uint256)" 1 $USDT <BSKT_WEI> --rpc-url $RPC
cast send $VAULT "redeem(uint256,address,uint256,uint256)" 1 $USDT <BSKT_WEI> 0 --rpc-url $RPC --interactive
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
| `0xace70cbd` | `FaucetAmountInvalid(uint256,uint256)` — кран: 0 или > 10 000 |

Расшифровка любой ошибки: `cast decode-error <data> --sig "<Сигнатура>"` или `cast 4byte <selector>`.
