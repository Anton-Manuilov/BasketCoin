#!/usr/bin/env bash
# Сухой прогон Deploy.s.sol на локальном форке Base MAINNET (anvil). В реальную сеть ничего не отправляется.
# Настоящие USDC/USDT, Chainlink USDC/USD, USDT/USD, L2 Sequencer Uptime. Safe и guardian — заглушки anvil #1/#2.
set -euo pipefail
export PATH=$PATH:$HOME/.foundry/bin   # 1114: cast/forge/anvil не всегда в PATH
cd "$(dirname "$0")/.."
PORT=${PORT:-8547}; R=http://127.0.0.1:$PORT; FORK=${FORK_URL:-https://mainnet.base.org}
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil #0, публичный тестовый ключ
# 1109: DEPLOYER_ENV=<файл от pick-deployer.sh> — прогон с подобранным ключом и сверкой предсказанных адресов (только форк)
PRED_VAULT=; PRED_TOKEN=
if [ -n "${DEPLOYER_ENV:-}" ]; then
  DEPLOYER_PK=$(grep '^DEPLOYER_PK=' "$DEPLOYER_ENV" | cut -d= -f2); PRED_VAULT=$(grep '^PREDICTED_VAULT=' "$DEPLOYER_ENV" | cut -d= -f2)
  PRED_TOKEN=$(grep '^PREDICTED_TOKEN=' "$DEPLOYER_ENV" | cut -d= -f2)
fi
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PK")
SAFE=${SAFE_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}   # заглушка Safe (anvil #1); 1114: SAFE_ADDR=<реальный Safe> (имперсонация)
GRD=${GUARDIAN_ADDR:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}    # заглушка guardian (anvil #2); 1114: GUARDIAN_ADDR=<реальный guardian>
# 1114: FUNDER=<кошелёк А> — резерв/минт/пул с этого адреса его настоящим USDC (имперсонация на форке); иначе USDC от WHALE на SAFE
FUNDER=${FUNDER:-}; RESERVE=${RESERVE:-900000000}; MINT=${MINT:-100000000}; KEEP_FORK=${KEEP_FORK:-0}
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; USDT=0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2
USDC_FEED=0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; USDT_FEED=0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9
SEQ=0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
WHALE=0xd0b53D9277642d899DF5C87A3966A349A798F224   # пул Uniswap v3 WETH/USDC — источник USDC на форке
J=deployments/fork-8453.local.json
anvil --fork-url "$FORK" --port $PORT --chain-id 8453 --silent & APID=$!
# 1114: KEEP_FORK=1 — оставить anvil живым (для теста бота/bktctl), таймлок с перемоткой времени пропускается
if [ "$KEEP_FORK" = 1 ]; then trap 'rm -rf broadcast/Deploy.s.sol/8453' EXIT; echo "anvil pid=$APID (KEEP_FORK)"; else trap 'kill $APID 2>/dev/null; rm -rf broadcast/Deploy.s.sol/8453' EXIT; fi
for _ in $(seq 30); do cast chain-id --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
echo "fork chainId=$(cast chain-id --rpc-url $R) block=$(cast block-number --rpc-url $R)"
cast rpc anvil_setBalance $DEPLOYER 0x8AC7230489E80000 --rpc-url $R >/dev/null
for a in $SAFE $GRD $WHALE; do cast rpc anvil_setBalance $a 0x8AC7230489E80000 --rpc-url $R >/dev/null; cast rpc anvil_impersonateAccount $a --rpc-url $R >/dev/null; done
if [ -n "$FUNDER" ]; then cast rpc anvil_impersonateAccount $FUNDER --rpc-url $R >/dev/null; fi
ok(){ local st; st=$(cast send "$@" --rpc-url $R --json | jq -r .status); [ "$st" = "0x1" ] || { echo "FAIL: $*"; exit 1; }; echo "  ok: ${2:-} ${3:-}"; }
call(){ cast call "$@" --rpc-url $R; }
echo "== deploy"
DEPLOYER_PK=$DEPLOYER_PK OWNER_ADDRESS=$SAFE FEE_RECIPIENT=$SAFE GUARDIAN_ADDRESS=$GRD SEQUENCER_UPTIME_FEED=$SEQ \
USDC_ADDRESS=$USDC USDT_ADDRESS=$USDT USDC_FEED=$USDC_FEED USDT_FEED=$USDT_FEED FEED_STALENESS=90000 \
INITIAL_INDEX=1665800000000000000 MIN_MINT_USD=50000000000000000000 DEPLOYMENTS_FILE=$J \
forge script script/Deploy.s.sol --rpc-url $R --broadcast 2>&1 | grep -E "BasketToken|BasketVault|Estimated|COMPLETE|Error|revert" || true
V=$(jq -r .BasketVault $J); T=$(jq -r .BasketToken $J); echo "vault=$V token=$T"
echo "  deployer ETH spent on fork: $(cast from-wei $((0x8AC7230489E80000 - $(cast balance $DEPLOYER --rpc-url $R))))"
GU=0; for f in broadcast/Deploy.s.sol/8453/run-latest.json; do [ -f $f ] && GU=$(jq -r '.receipts[].gasUsed' $f | python3 -c "import sys; print(sum(int(x,0) for x in sys.stdin.read().split()))"); done; echo "  deployer gasUsed total: $GU"
[ "$(call $V 'owner()(address)')" = "$DEPLOYER" ] && [ "$(call $V 'pendingOwner()(address)')" = "$SAFE" ] && echo "  ok: owner=deployer, pendingOwner=Safe" || { echo "FAIL: owner/pendingOwner"; exit 1; }
ADM=$(call $T 'DEFAULT_ADMIN_ROLE()(bytes32)'); MR=$(call $T 'MINTER_ROLE()(bytes32)')
[ "$(call $T 'hasRole(bytes32,address)(bool)' $ADM $DEPLOYER)$(call $T 'hasRole(bytes32,address)(bool)' $MR $DEPLOYER)" = "falsefalse" ] && echo "  ok: деплоер без ролей токена" || { echo "FAIL: деплоер с ролью токена"; exit 1; }
if [ -n "$PRED_VAULT" ]; then
  [ "$V" = "$PRED_VAULT" ] && [ "$T" = "$PRED_TOKEN" ] || { echo "FAIL: адреса не совпали с pick-deployer ($PRED_VAULT / $PRED_TOKEN)"; exit 1; }
  echo "  ok: адреса = предсказанию pick-deployer.sh"
fi
python3 -c "import sys; sys.exit(0 if int('$T',16) > int('$USDC',16) else 1)" && echo "  ok: BKT > USDC (token0 = USDC)" || echo "  WARN: BKT < USDC — с этим деплоером пул/бот не годятся"
echo "== guardian: freezeStableMint(USDT)"
ok $V "freezeStableMint(address)" $USDT --unlocked --from $GRD
[ "$(call $V 'stableMintFrozen(address)(bool)' $USDT)" = "true" ] && echo "  stableMintFrozen(USDT)=true"
echo "== ownership"; ok $V "acceptOwnership()" --unlocked --from $SAFE
[ "$(call $V 'owner()(address)')" = "$SAFE" ] && echo "  owner=Safe"
echo "  guardian=$(call $V 'guardian()(address)')"; [ "$(call $V 'guardian()(address)')" = "$GRD" ] || { echo "FAIL: guardian"; exit 1; }
[ "$(call $V 'pendingOwner()(address)')" = 0x0000000000000000000000000000000000000000 ] && echo "  ok: pendingOwner=0"
cast rpc anvil_impersonateAccount $DEPLOYER --rpc-url $R >/dev/null
if cast send $V "pause()" --unlocked --from $DEPLOYER --rpc-url $R >/dev/null 2>&1; then echo "FAIL: деплоер смог pause()"; exit 1; else echo "  ok: деплоер без прав (pause revert)"; fi
echo "== резерв $RESERVE + минт $MINT (USDC 6 зн.)"
if [ -n "$FUNDER" ]; then U=$FUNDER; echo "  funder=$U USDC=$(call $USDC 'balanceOf(address)(uint256)' $U)"
else U=$SAFE; ok $USDC "transfer(address,uint256)" $SAFE $((RESERVE+MINT)) --unlocked --from $WHALE; fi
ok $USDC "approve(address,uint256)" $V $((RESERVE+MINT)) --unlocked --from $U
if cast send $V "mint(uint256,address,uint256,uint256)" 1 $USDC $MINT 0 --unlocked --from $U --rpc-url $R >/dev/null 2>&1; then echo "FAIL: минт до резерва прошёл"; exit 1; else echo "  ok: минт до topUpReserve -> revert"; fi
ok $V "topUpReserve(uint256,address,uint256)" 1 $USDC $RESERVE --unlocked --from $U   # генезис: сначала резерв
PV=$(call $V 'previewMint(uint256,address,uint256)(uint256)' 1 $USDC $MINT | awk '{print $1}'); MO=$(python3 -c "print($PV*995//1000)")
echo "  preview=$PV minOut(0,995)=$MO"
ok $V "mint(uint256,address,uint256,uint256)" 1 $USDC $MINT $MO --unlocked --from $U
echo "  BKT=$(call $T 'balanceOf(address)(uint256)' $U) cov=$(call $V 'collateralRatioBps(uint256)(uint256)' 1) tier=$(call $V 'redeemTier(uint256)' 1 2>/dev/null || echo ?)"
echo "  capacity=$(call $V 'mintCapacity(uint256)' 1)"
echo "== пул BKT/USDC 0,3% (script/pool-init.py)"
if python3 -c "import sys; sys.exit(0 if int('$T',16) > int('$USDC',16) else 1)"; then
  SQ=$(python3 script/pool-init.py --bkt $T --vault $V --rpc $R | awk '/^sqrtPriceX96 =/{print $3}')
  NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; FAC=0x33128a8fC17869897dcE68Ed026d694621f6FDfD
  ok $NPM "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" $USDC $T 3000 $SQ --unlocked --from $U
  POOL=$(call $FAC 'getPool(address,address,uint24)(address)' $USDC $T 3000)
  S0=$(call $POOL 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | head -1 | awk '{print $1}')
  [ "$S0" = "$SQ" ] && echo "  ok: pool=$POOL sqrtPriceX96=$S0 ($(python3 -c "print(round(1e12/(($S0/2**96)**2),6))") USDC/BKT)" || { echo "FAIL: slot0 $S0 != $SQ"; exit 1; }
else echo "  пропуск: BKT < USDC"; fi
echo "== redeem 10 BKT"
ok $V "redeem(uint256,address,uint256,uint256)" 1 $USDC 10000000000000000000 0 --unlocked --from $U
echo "== pause guardian / unpause Safe"
ok $V "pause()" --unlocked --from $GRD; echo "  paused=$(call $V 'paused()(bool)')"
ok $V "unpause()" --unlocked --from $SAFE; echo "  paused=$(call $V 'paused()(bool)')"
if [ "$KEEP_FORK" = 1 ]; then echo "fork kept: rpc=$R vault=$V token=$T pool=${POOL:-} anvil=$APID"; echo "ALL OK (без таймлока, KEEP_FORK)"; exit 0; fi
echo "== timelock setMintLimits(15000,16000,300,100)"
D=$(cast calldata "setMintLimits(uint256,uint256,uint256,uint256)" 15000 16000 300 100); S=0x$(printf '%064x' 1)
ok $V "scheduleOp(bytes,bytes32)" $D $S --unlocked --from $SAFE
if cast send $V "executeOp(bytes,bytes32)" $D $S --unlocked --from $SAFE --rpc-url $R >/dev/null 2>&1; then echo "FAIL: исполнилось раньше таймлока"; exit 1; else echo "  ok: до 2 дней — revert"; fi
cast rpc evm_increaseTime 172801 --rpc-url $R >/dev/null; cast rpc evm_mine --rpc-url $R >/dev/null
ok $V "executeOp(bytes,bytes32)" $D $S --unlocked --from $SAFE
echo "  mintLimits=$(call $V 'mintLimits()(uint32,uint32,uint32,uint32)' | tr '\n' ' ')"
echo "ALL OK"
