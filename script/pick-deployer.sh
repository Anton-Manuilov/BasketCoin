#!/usr/bin/env bash
# 1109: одноразовый деплоер Base mainnet. Генерирует свежий ключ, пока адрес BKT (нонс 1) > USDC,
# чтобы в пуле Uniswap v3 token0 = USDC (бот это требует: bkt_mm.py assert T0 == quote).
# Порядок нонсов из script/Deploy.s.sol при заданных USDC_ADDRESS/USDT_ADDRESS (тестовые стейблы НЕ создаются):
#   нонс 0 -> new BasketVault, нонс 1 -> new BasketToken, дальше grantRole/addBasket/... (вызовы, не контракты).
# Ключ пишется ТОЛЬКО в файл с правами 600 (по умолчанию ~/.secrets/basketcoin-mainnet-deployer.env), в stdout — только адреса.
#   script/pick-deployer.sh [OUT_FILE]
# Деплоер обязан быть НОВЫМ (нонс 0 в сети) — иначе предсказание неверно; скрипт это проверяет, если задан CHECK_RPC.
set -euo pipefail
export PATH=$PATH:$HOME/.foundry/bin
OUT="${1:-$HOME/.secrets/basketcoin-mainnet-deployer.env}"
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
MAX_TRIES=${MAX_TRIES:-64}
[ -e "$OUT" ] && { echo "уже есть $OUT — не перезаписываю (удалите вручную, если ключ не использован)"; exit 1; }
mkdir -p "$(dirname "$OUT")"; chmod 700 "$(dirname "$OUT")"
umask 077
lc(){ tr 'A-F' 'a-f' <<<"${1#0x}"; }
for i in $(seq "$MAX_TRIES"); do
  W=$(cast wallet new --json)                       # ключ только в переменной, не печатается
  ADDR=$(jq -r '(.data? // .)[0].address' <<<"$W"); PK=$(jq -r '(.data? // .)[0].private_key' <<<"$W"); unset W
  [[ "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ && ${#PK} -ge 64 ]] || { echo "cast wallet new: неожиданный формат"; exit 1; }
  VAULT=$(cast compute-address "$ADDR" --nonce 0 | awk '{print $NF}')
  TOKEN=$(cast compute-address "$ADDR" --nonce 1 | awk '{print $NF}')
  # сравнение 160-битных адресов как hex-строк одинаковой длины = числовое сравнение
  if [[ "$(lc "$TOKEN")" > "$(lc "$USDC")" ]]; then
    if [ -n "${CHECK_RPC:-}" ]; then n=$(cast nonce "$ADDR" --rpc-url "$CHECK_RPC"); [ "$n" = 0 ] || { unset PK; continue; }; fi
    printf 'DEPLOYER_PK=%s\nDEPLOYER_ADDRESS=%s\nPREDICTED_VAULT=%s\nPREDICTED_TOKEN=%s\n# created %s by pick-deployer.sh, attempt %s\n' \
      "$PK" "$ADDR" "$VAULT" "$TOKEN" "$(date '+%F %T %Z')" "$i" > "$OUT"
    unset PK; chmod 600 "$OUT"
    echo "deployer=$ADDR"
    echo "vault(nonce0)=$VAULT"
    echo "token(nonce1)=$TOKEN  > USDC ✓ (token0 = USDC)"
    echo "key file: $OUT (600)"
    exit 0
  fi
  unset PK
done
echo "не нашёл за $MAX_TRIES попыток"; exit 1
