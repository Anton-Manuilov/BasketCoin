# BasketCoin v5.2 — репетиция запуска Base mainnet на форке, 14.11.2026 (UTC+7)
Антон одобрил 14.11 18:22 (UTC+7) начать репетицию раньше плана 18.11. Запуск по-прежнему **19.11**. В реальный Base mainnet **ничего не отправлялось**: все транзакции шли только в локальные форки anvil (127.0.0.1:8547 / :8548), там же имперсонировались Safe и кошелёк А. Код: HEAD 00f84e1 (v5.2), `src/` не менялся.

## Ключи (раздел 0.2–0.3 runbook). Наружу только адреса
| Роль | Адрес | Файл (600, каталог ~/.secrets 700) | Нонс в mainnet |
|---|---|---|---|
| Деплоер (одноразовый, pick-deployer.sh, CHECK_RPC) | `0xCaAB4491Fa9702Cb6A118cf43a96D95F447D4E47` | `~/.secrets/basketcoin-mainnet-deployer.env` | 0 |
| Предсказанный Vault (нонс 0) | `0xf1CA2eee2ab96290C799Df2006E41197B71244c9` | | |
| Предсказанный BKT (нонс 1), > USDC ✓ | `0xa6FfD6B4b0c99F4c1750D4D411802A757Df14cA2` | | |
| Guardian | `0xE2bD7b7b10A177546FB8EB668128EA3082448B8c` | `~/.secrets/basketcoin-mainnet-guardian.env` (GUARDIAN_PK, GUARDIAN_ADDRESS) | 0 |
| MM-бот | `0xF94ec91516EbC87308238D3B75e6E43534231528` | `~/.secrets/basketcoin-mainnet-bot.env` (MM_PK, MM_ADDRESS, BKT_RPC) | 0 |
BKT_RPC в файле бота пока `https://mainnet.base.org`; перед запуском заменить на Alchemy (runbook 7.1).

## Результаты
| Шаг | Итог |
|---|---|
| 0.2 pick-deployer.sh | PASS: адреса совпали с предсказанием на форке |
| 0.4 fork-mainnet.sh (реальные Safe, guardian, деплоер, кошелёк А) | **ALL OK** (`fork-results-1114.txt`, форк на блоке 57325757) |
| Верификация: standard-json офлайн (DRY_RUN=1, blockscout/sourcify/etherscan, без ETHERSCAN_API_KEY) | PASS: `deployments/rehearsal-1114-standard-json/`, solc v0.8.24+commit.e11b9ed9, optimizer 200 |
| 0.5 bktctl.sh: start, kill -9 run.sh+бот, watchdog поднял через 60 с, kill watchdog, ensure поднял, stop (STOP) | PASS: бот снял 7 позиций и вышел за 14 с |
| Пробный тик бота (`bkt_mm.py 1 20`) на форке | PASS: core/bid/ask/sbid/sask/fbid/fask RANGE_PLACED |
| forge test | **283/283** PASS |

Что было на форке: деплой → owner=деплоер, pendingOwner=Safe, у деплоера нет ролей токена → guardian `freezeStableMint(USDT)` = true → Safe `acceptOwnership` → owner=Safe, pendingOwner=0, деплоер `pause()` ревертится → минт до резерва ревертится → А: approve 2200, `topUpReserve` 1000, `mint` 1200 с minOut = preview·0,995 → **598,364 BKT**, покрытие 22 030 bps, tier FULL → лимиты по умолчанию 1000/500 bps (10%/ч, 5%/блок), capacity $217,6/ч и $108,8/блок → пул 0,3% `0x3ED1…666F` (адрес только для форка), sqrtPriceX96 = 56037342578411322285942487683251328 (1,99896 USDC/BKT) → redeem 10 BKT → пауза guardian / снятие паузы Safe → таймлок: до 2 дней revert, после исполняется.

## Газ (mainnet сейчас: base fee 0,005 gwei, tip 0,001 gwei)
- Деплой: 7 078 341 газа, на форке ушло 0,00011 ETH. Пополнение по runbook **0,007 ETH**, запас огромный на случай скачка газа. Остаток после запуска возвращается А.
- Бот: **0,01 ETH**. На форке 23 tx съели 0,0045 ETH, но только потому, что anvil ставит tip 1 gwei. В mainnet при tip 0,001 gwei это около 1e-6 ETH за tx.
- Guardian: **0,002 ETH**, на одну `freezeStableMint` и экстренный запас.

## Найденные проблемы и правки (только helper-скрипты, бэкапы `*.bak-1114`)
1. `script/fork-mainnet.sh`: Safe и guardian были заглушками anvil, резерв и минт шли 900/100 с whale на Safe, а не с кошелька А. Добавлены env-параметры `SAFE_ADDR`, `GUARDIAN_ADDR`, `FUNDER`, `RESERVE`, `MINT`, `KEEP_FORK` (старое поведение по умолчанию не изменилось). Добавлены проверки: owner/pendingOwner до и после, роли деплоера, `pause()` деплоера → revert, минт до резерва → revert, minOut 0,995, учёт газа деплоера. Также добавлен `PATH` к ~/.foundry/bin.
2. `script/verify-mainnet.sh`: добавлен `PATH` к ~/.foundry/bin (без него cast/forge не находятся).
3. `autostart/bktctl.sh`: **не было каталога `autostart/enabled/`**. Из-за этого `start`/`enable` падали на `touch`, и watchdog никого не перезапускал. Добавлен `mkdir -p enabled run logs`.
4. Важно для mainnet: в `config.mainnet.yml` в `rpc_backup` стоит `https://mainnet.base.org`. Для теста на форке сделана копия `basketcoin-mm/fork-1114/` (config.fork.yml с `rpc_backup: []`, свой run.sh с BKT_RPC=форк, профиль `autostart/profiles/fork-1114.conf.off` выключен), чтобы бот при failover не ушёл в реальную сеть. Mainnet-конфиг не трогали.
5. `deployments/fork-8453.local.json` перезаписан данными форка (файл только для форка).

## Состояние после репетиции
anvil, бот и watchdog остановлены, ничего не запущено. Профиль `mainnet`: enabled=n, `config.mainnet.yml` по-прежнему TBD. Ключи в репозитории, логах и /tmp не найдены (проверено поиском). Ничего не закоммичено.

## Осталось на 18–19.11
Пополнение: А → деплоер 0,007 и бот 0,01, М → guardian 0,002. Перед деплоем ещё раз проверить нонс 0 у деплоера. Вписать адреса в `config.mainnet.yml` и монитор, поставить Alchemy в BKT_RPC. После запуска удалить `fork-1114/`.
