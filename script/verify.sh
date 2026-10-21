#!/usr/bin/env bash
# Верификация исходников BasketCoin на Base Sepolia БЕЗ API-ключа: Blockscout и/или Sourcify.
# Адреса и параметры конструкторов берутся из deployments/base-sepolia.json (его пишет script/Deploy.s.sol).
#
#   script/verify.sh                 # Blockscout + Sourcify
#   VERIFIERS=blockscout script/verify.sh
#   DRY_RUN=1 script/verify.sh       # только напечатать команды и проверить, что standard-json собирается
#
# Basescan (вкладка Write Contract на basescan.org) Blockscout/Sourcify не видит: для него нужен бесплатный
# ключ Etherscan API v2 — см. раздел «Basescan» в docs/OPERATIONS.md. Вкладка Write Contract на
# https://base-sepolia.blockscout.com работает с MetaMask сразу после верификации на Blockscout.
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${DEPLOYMENTS_FILE:-deployments/base-sepolia.json}"
CHAIN=84532
BLOCKSCOUT_URL="${BLOCKSCOUT_URL:-https://base-sepolia.blockscout.com/api/}"
VERIFIERS="${VERIFIERS:-blockscout sourcify}"
DRY_RUN="${DRY_RUN:-0}"

[ -f "$FILE" ] || { echo "нет $FILE — сначала задеплойте (script/Deploy.s.sol)"; exit 1; }
j() { jq -r "$1" "$FILE"; }
USDT=$(j .TestUSDT); USDC=$(j .TestUSDC); TOKEN=$(j .BasketToken); VAULT=$(j .BasketVault)
DEPLOYER=$(j .deployer); FEE=$(j .feeRecipient); MINMINT=$(j .minMintUsd)

# Аргументы конструкторов ровно такие, как в script/Deploy.s.sol:
#   BasketVault(deployer, feeRecipient, TestUSDT, TestUSDC, minMintUsd, guardian, sequencerUptimeFeed)  — v4+ (этап B)
#   BasketVault(deployer, feeRecipient, TestUSDT, TestUSDC, minMintUsd)                                 — v1–v3
#   BasketToken("BasketCoin", "BKT", deployer)
# Для v1–v3 (в JSON нет поля guardian) проверять нужно коммит до этапа B, иначе байткод не совпадёт.
if [ "$(j 'has("guardian")')" = "true" ]; then
  VAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256,address,address)" \
    "$DEPLOYER" "$FEE" "$USDT" "$USDC" "$MINMINT" "$(j .guardian)" "$(j .sequencerUptimeFeed)")
else
  VAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256)" "$DEPLOYER" "$FEE" "$USDT" "$USDC" "$MINMINT")
fi
TOKEN_ARGS=$(cast abi-encode "constructor(string,string,address)" "BasketCoin" "BKT" "$DEPLOYER")

# адрес | контракт | аргументы конструктора
TARGETS=(
  "$USDT|src/testnet/TestStablecoins.sol:TestUSDT|"
  "$USDC|src/testnet/TestStablecoins.sol:TestUSDC|"
  "$TOKEN|src/BasketToken.sol:BasketToken|$TOKEN_ARGS"
  "$VAULT|src/BasketVault.sol:BasketVault|$VAULT_ARGS"
)

for v in $VERIFIERS; do
  case "$v" in
    blockscout) VFLAGS=(--verifier blockscout --verifier-url "$BLOCKSCOUT_URL") ;;
    sourcify)   VFLAGS=(--verifier sourcify) ;;
    *) echo "неизвестный verifier: $v"; exit 1 ;;
  esac
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r addr contract args <<<"$t"
    cmd=(forge verify-contract "$addr" "$contract" --chain "$CHAIN" "${VFLAGS[@]}" --watch)
    [ -n "$args" ] && cmd+=(--constructor-args "$args")
    echo "+ ${cmd[*]}"
    if [ "$DRY_RUN" = "1" ]; then
      # Сухая проверка: forge собирает standard-json-input (синтаксис, путь контракта, компилятор) и ничего не отправляет.
      "${cmd[@]}" --show-standard-json-input >/dev/null && echo "  ok (standard-json собран, не отправлено)"
    else
      "${cmd[@]}" || echo "  !! $v: $contract не верифицирован (возможно, уже верифицирован или индексатор не успел — повторите)"
    fi
  done
done
