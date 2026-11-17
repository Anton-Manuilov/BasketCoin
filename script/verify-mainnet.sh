#!/usr/bin/env bash
# Верификация BasketToken + BasketVault на Base mainnet (chain 8453): Blockscout + Sourcify (по умолчанию)
# + файлы standard-json для РУЧНОЙ формы Basescan Verify & Publish (бесплатный план Etherscan API не покрывает Base 8453).
# Данные — из deployments/8453.json (пишет script/Deploy.s.sol). USDC/USDT настоящие — их не верифицируем.
#   script/verify-mainnet.sh                    # standard-json в deployments/basescan-standard-json/ + Blockscout + Sourcify
#   DRY_RUN=1 script/verify-mainnet.sh          # только собрать standard-json, ничего не отправлять
#   VERIFIERS="etherscan" ETHERSCAN_API_KEY=... script/verify-mainnet.sh   # только при платном плане Etherscan
# Ключ читается ТОЛЬКО из env ETHERSCAN_API_KEY, в файлы/логи не пишется.
set -euo pipefail
export PATH=$PATH:$HOME/.foundry/bin   # 1114: cast/forge не всегда в PATH
cd "$(dirname "$0")/.."
FILE="${DEPLOYMENTS_FILE:-deployments/8453.json}"
CHAIN=8453
BLOCKSCOUT_URL="${BLOCKSCOUT_URL:-https://base.blockscout.com/api/}"
ETHERSCAN_URL="${ETHERSCAN_URL:-https://api.etherscan.io/v2/api?chainid=8453}"
VERIFIERS="${VERIFIERS:-blockscout sourcify}"
SJ_DIR="${SJ_DIR:-deployments/basescan-standard-json}"
DRY_RUN="${DRY_RUN:-0}"
[ -f "$FILE" ] || { echo "нет $FILE — сначала деплой (script/Deploy.s.sol)"; exit 1; }
j() { jq -r "$1" "$FILE"; }
[ "$(j .chainId)" = "$CHAIN" ] || { echo "в $FILE chainId=$(j .chainId), ожидался $CHAIN"; exit 1; }
USDT=$(j .TestUSDT); USDC=$(j .TestUSDC); TOKEN=$(j .BasketToken); VAULT=$(j .BasketVault)
DEPLOYER=$(j .deployer); FEE=$(j .feeRecipient); MINMINT=$(j .minMintUsd)
VAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256,address,address,address,address,uint256)" \
  "$DEPLOYER" "$FEE" "$USDT" "$USDC" "$MINMINT" "$(j .guardian)" "$(j .sequencerUptimeFeed)" "$(j .usdtFeed)" "$(j .usdcFeed)" "$(j .feedStaleness)")
TOKEN_ARGS=$(cast abi-encode "constructor(string,string,address)" "BasketCoin" "BKT" "$DEPLOYER")
TARGETS=("$TOKEN|src/BasketToken.sol:BasketToken|$TOKEN_ARGS" "$VAULT|src/BasketVault.sol:BasketVault|$VAULT_ARGS")

# --- 1109: standard-json + памятка для ручной формы Basescan (сохраняется всегда, до отправки верификаторам) ---
mkdir -p "$SJ_DIR"
SOLC=$(grep -E '^solc_version' foundry.toml | cut -d'"' -f2); RUNS=$(grep -E '^optimizer_runs' foundry.toml | grep -oE '[0-9]+')
NOTE="$SJ_DIR/BASESCAN_FORM.txt"
{ echo "Basescan -> адрес контракта -> Contract -> Verify & Publish (одинаково для обоих контрактов)"
  echo "  Compiler Type:    Solidity (Standard-Json-Input)"
  SOLC_FULL=$( (ls "$HOME/.local/share/svm/$SOLC/solc-$SOLC" >/dev/null 2>&1 && "$HOME/.local/share/svm/$SOLC/solc-$SOLC" --version | grep -oE "[0-9.]+\+commit\.[0-9a-f]+") || echo "$SOLC+commit.?")
  echo "  Compiler Version: v$SOLC_FULL"
  echo "  EVM Version:      cancun (внутри JSON)"
  echo "  License:          MIT License (MIT)"
  echo "  Optimizer:        enabled, runs=$RUNS (уже внутри JSON, отдельно не вводится)"
  echo "  Файл:             загрузить <Contract>.json из этого каталога"
  echo "  Constructor Arguments ABI-encoded: строка ниже БЕЗ 0x"
  echo; } > "$NOTE"
for t in "${TARGETS[@]}"; do
  IFS='|' read -r addr contract args <<<"$t"; name=${contract##*:}
  forge verify-contract "$addr" "$contract" --chain "$CHAIN" --constructor-args "$args" --show-standard-json-input > "$SJ_DIR/$name.json"
  jq -e '.settings.optimizer.enabled == true' "$SJ_DIR/$name.json" >/dev/null || { echo "!! $name.json: нет optimizer в standard-json"; exit 1; }
  { echo "== $name  $addr"; echo "  файл: $SJ_DIR/$name.json"; echo "  constructor args: ${args#0x}"; echo; } >> "$NOTE"
  echo "  saved $SJ_DIR/$name.json ($(wc -c <"$SJ_DIR/$name.json") байт)"
done
echo "  памятка: $NOTE"
for v in $VERIFIERS; do
  case "$v" in
    etherscan)
      if [ "$DRY_RUN" != "1" ]; then : "${ETHERSCAN_API_KEY:?нужен ETHERSCAN_API_KEY в env (бесплатный ключ Etherscan API v2)}"; fi
      VFLAGS=(--verifier etherscan --verifier-url "$ETHERSCAN_URL" --etherscan-api-key "${ETHERSCAN_API_KEY:-dry}") ;;
    blockscout) VFLAGS=(--verifier blockscout --verifier-url "$BLOCKSCOUT_URL") ;;
    sourcify)   VFLAGS=(--verifier sourcify) ;;
    *) echo "неизвестный verifier: $v"; exit 1 ;;
  esac
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r addr contract args <<<"$t"
    cmd=(forge verify-contract "$addr" "$contract" --chain "$CHAIN" "${VFLAGS[@]}" --watch --constructor-args "$args")
    echo "+ forge verify-contract $addr $contract --chain $CHAIN --verifier $v"
    if [ "$DRY_RUN" = "1" ]; then
      "${cmd[@]}" --show-standard-json-input >/dev/null && echo "  ok (standard-json собран, не отправлено)"
    else
      "${cmd[@]}" || echo "  !! $v: $contract не верифицирован — повторите позже"
    fi
  done
done
