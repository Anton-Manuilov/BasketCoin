#!/usr/bin/env bash
# Сухой прогон на локальном форке Base Sepolia (anvil): деплой скриптом → кран → approve → mint → redeem →
# пауза guardian'ом → таймлок → депег → перемотка на 28-е UTC → UpdateIndex. В реальную сеть ничего не отправляется.
# Требует DEPLOYER_PK в окружении (баланс на форке выставляется через anvil_setBalance).
# Владелец: OWNER_ADDRESS (по умолчанию anvil #1). Его транзакции подписываются через anvil_impersonateAccount
# (--unlocked), поэтому ключ владельца не нужен. FEE_RECIPIENT по умолчанию = OWNER_ADDRESS.
# Ключ anvil #3 ниже — общеизвестный тестовый ключ anvil, не секрет.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEPLOYER_PK:?нужен DEPLOYER_PK}"
PORT="${PORT:-8545}"; R="http://127.0.0.1:$PORT"; FORK="${FORK_URL:-https://sepolia.base.org}"
USR_PK=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6   # anvil #3 → тестировщик
OWN=$(cast to-check-sum-address "${OWNER_ADDRESS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}")
FEE=$(cast to-check-sum-address "${FEE_RECIPIENT:-$OWN}")
GRD=$(cast to-check-sum-address "${GUARDIAN_ADDRESS:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}")   # anvil #2
USR=$(cast wallet address --private-key $USR_PK)
DEP=$(cast wallet address --private-key "$DEPLOYER_PK")
J=deployments/anvil-fork.local.json

anvil --fork-url "$FORK" --port "$PORT" --silent & APID=$!
trap 'kill $APID 2>/dev/null; rm -rf broadcast/Deploy.s.sol/84532 broadcast/UpdateIndex.s.sol/84532 cache/Deploy.s.sol cache/UpdateIndex.s.sol' EXIT
for _ in $(seq 30); do cast chain-id --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
echo "fork chainId=$(cast chain-id --rpc-url $R) block=$(cast block-number --rpc-url $R)"
cast rpc anvil_setBalance "$DEP" 0x8AC7230489E80000 --rpc-url $R >/dev/null
cast rpc anvil_setBalance "$OWN" 0x8AC7230489E80000 --rpc-url $R >/dev/null
cast rpc anvil_impersonateAccount "$OWN" --rpc-url $R >/dev/null
cast rpc anvil_setBalance "$GRD" 0x8AC7230489E80000 --rpc-url $R >/dev/null
cast rpc anvil_impersonateAccount "$GRD" --rpc-url $R >/dev/null
GRD_SIGN=(--unlocked --from "$GRD")
OWN_SIGN=(--unlocked --from "$OWN")   # подпись от имени владельца на форке
echo "deployer=$DEP owner=$OWN feeRecipient=$FEE"

ok(){ local st; st=$(cast send "$@" --rpc-url $R --json | jq -r .status); [ "$st" = "0x1" ] || { echo "FAIL: $*"; exit 1; }; }
expect_revert(){ local sel=$1; shift; local out; out=$(cast send "$@" --rpc-url $R 2>&1 || true); echo "$out" | grep -q "$sel" || { echo "FAIL (ожидался $sel): $out"; exit 1; }; }
call(){ cast call "$@" --rpc-url $R | awk '{print $1}'; }

echo "== deploy"
OWNER_ADDRESS=$OWN FEE_RECIPIENT=$FEE GUARDIAN_ADDRESS=$GRD SEQUENCER_UPTIME_FEED=0x0000000000000000000000000000000000000000 DEPLOYMENTS_FILE=$J forge script script/Deploy.s.sol --rpc-url $R --broadcast 2>&1 \
  | grep -E "TestUSD|BasketToken |BasketVault |Estimated total gas|Estimated amount|COMPLETE"
V=$(jq -r .BasketVault $J); T=$(jq -r .BasketToken $J); U=$(jq -r .TestUSDT $J); C=$(jq -r .TestUSDC $J)

MINTER=$(call $T "MINTER_ROLE()(bytes32)"); ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
chk(){ [ "$1" = "$2" ] || { echo "FAIL: $3: '$1' != '$2'"; exit 1; }; echo "   ✓ $3"; }
echo "== до acceptOwnership"
chk "$(call $V 'owner()(address)')" "$DEP" "Vault.owner = деплоер (до принятия)"
chk "$(call $V 'pendingOwner()(address)')" "$OWN" "Vault.pendingOwner = владелец"
chk "$(call $V 'feeRecipient()(address)')" "$FEE" "Vault.feeRecipient"
chk "$(call $T 'hasRole(bytes32,address)(bool)' $ADMIN $V)" true "токен: DEFAULT_ADMIN_ROLE у Vault (роли — через таймлок 7 дней)"
chk "$(call $T 'hasRole(bytes32,address)(bool)' $ADMIN $OWN)" false "токен: у владельца нет DEFAULT_ADMIN_ROLE"
chk "$(call $V 'guardian()(address)')" "$GRD" "Vault.guardian"
chk "$(call $V 'sequencerUptimeFeed()(address)')" 0x0000000000000000000000000000000000000000 "Vault.sequencerUptimeFeed = 0 (тестнет)"
chk "$(call $T 'hasRole(bytes32,address)(bool)' $MINTER $V)" true "токен: MINTER_ROLE у Vault"
expect_revert 0x118cdaa7 $V "acceptOwnership()" --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер не может принять владение за владельца"
echo "== acceptOwnership от владельца (impersonate)"; ok $V "acceptOwnership()" "${OWN_SIGN[@]}"
echo "== права деплоера после передачи"
chk "$(call $V 'owner()(address)')" "$OWN" "Vault.owner = владелец"
chk "$(call $V 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000 "Vault.pendingOwner = 0"
chk "$(call $T 'hasRole(bytes32,address)(bool)' $ADMIN $DEP)" false "токен: у деплоера нет DEFAULT_ADMIN_ROLE"
chk "$(call $T 'hasRole(bytes32,address)(bool)' $MINTER $DEP)" false "токен: у деплоера нет MINTER_ROLE"
expect_revert 0x6b1883f3 $V "pause()" --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: pause → NotOwnerOrGuardian"
expect_revert 0x118cdaa7 $V "scheduleOp(bytes,bytes32)" 0x12 0x0000000000000000000000000000000000000000000000000000000000000000 --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: scheduleOp → OwnableUnauthorizedAccount"
expect_revert 0x118cdaa7 $V "setMinMintUsd(uint256)" 60000000000000000000 --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: setMinMintUsd → OwnableUnauthorizedAccount"
expect_revert 0x118cdaa7 $V "transferOwnership(address)" "$DEP" --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: transferOwnership → OwnableUnauthorizedAccount"
expect_revert 0xe2517d3f $T "grantRole(bytes32,address)" $MINTER "$DEP" --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: token.grantRole → AccessControlUnauthorizedAccount"
expect_revert 0xe2517d3f $T "mint(address,uint256)" "$DEP" 1 --private-key "$DEPLOYER_PK"; echo "   ✓ деплоер: token.mint → AccessControlUnauthorizedAccount"
echo "== faucet / limit"; ok $U "faucet(uint256)" 10000000000 --private-key $USR_PK
expect_revert 0xace70cbd $U "faucet(uint256)" 10000000001 --private-key $USR_PK; echo "   >10000 → FaucetAmountInvalid ✓"
echo "== approve + mint 1000 tUSDT"; ok $U "approve(address,uint256)" $V 1000000000 --private-key $USR_PK
ok $V "mint(uint256,address,uint256,uint256)" 1 $U 1000000000 0 --private-key $USR_PK
BAL=$(call $T "balanceOf(address)(uint256)" $USR)
echo "   BKT=$BAL coverage=$(call $V 'collateralRatioBps(uint256)(uint256)' 1)bps fee→treasury=$(call $U 'balanceOf(address)(uint256)' $FEE)"
HALF=$(python3 -c "print($BAL//2)")   # bash-арифметика переполняется на 1e20+
echo "== redeem half ($HALF)"; echo "   quote payoutNow/fee: $(cast call $V 'previewRedeem(uint256,address,uint256)(uint256,uint256)' 1 $U $HALF --rpc-url $R | awk '{print $1}' | tr '\n' ' ')"
ok $V "redeem(uint256,address,uint256,uint256)" 1 $U $HALF 0 --private-key $USR_PK
echo "   BKT=$(call $T 'balanceOf(address)(uint256)' $USR) tUSDT=$(call $U 'balanceOf(address)(uint256)' $USR) coverage=$(call $V 'collateralRatioBps(uint256)(uint256)' 1)bps"
echo "== pause guardian'ом"; ok $V "pause()" "${GRD_SIGN[@]}"
expect_revert 0xd93c0665 $V "mint(uint256,address,uint256,uint256)" 1 $U 100000000 0 --private-key $USR_PK; echo "   mint на паузе → EnforcedPause ✓"
expect_revert 0x118cdaa7 $V "unpause()" "${GRD_SIGN[@]}"; echo "   guardian: unpause → OwnableUnauthorizedAccount ✓"
ok $V "unpause()" "${OWN_SIGN[@]}"
expect_revert 0x40445cac $V "pause()" "${GRD_SIGN[@]}"; echo "   повторная пауза сразу → PauseCooldown ✓"
SALT=0x0000000000000000000000000000000000000000000000000000000000000000
D1=$(cast calldata "setManualPrice(address,uint256)" $U 940000000000000000)
expect_revert 0x1c0be90a $V "setManualPrice(address,uint256)" $U 940000000000000000 "${OWN_SIGN[@]}"; echo "   setManualPrice напрямую → OnlyTimelock ✓"
echo "== depeg tUSDT (manual 0.94) через таймлок 2 дня"; ok $V "scheduleOp(bytes,bytes32)" $D1 $SALT "${OWN_SIGN[@]}"
expect_revert 0xe552c2e3 $V "executeOp(bytes,bytes32)" $D1 $SALT "${OWN_SIGN[@]}"; echo "   executeOp сразу → OpNotReady ✓"
cast rpc evm_increaseTime 172800 --rpc-url $R >/dev/null; cast rpc evm_mine --rpc-url $R >/dev/null
ok $V "executeOp(bytes,bytes32)" $D1 $SALT "${OWN_SIGN[@]}"
expect_revert 0x52dbbfd2 $V "redeem(uint256,address,uint256,uint256)" 1 $U 1000000000000000000 0 --private-key $USR_PK
echo "   tUSDT depegged=$(call $V 'isDepegged(address)(bool)' $U) tUSDC depegged=$(call $V 'isDepegged(address)(bool)' $C) → redeem tUSDT StableDepegged ✓"
D2=$(cast calldata "setManualPrice(address,uint256)" $U 1000000000000000000)
ok $V "scheduleOp(bytes,bytes32)" $D2 $SALT "${OWN_SIGN[@]}"
cast rpc evm_increaseTime 172800 --rpc-url $R >/dev/null; cast rpc evm_mine --rpc-url $R >/dev/null
ok $V "executeOp(bytes,bytes32)" $D2 $SALT "${OWN_SIGN[@]}"
expect_revert 0x94aa9dfd $V "setIndex(uint256,uint256)" 1 1020000000000000000 "${OWN_SIGN[@]}"; echo "   setIndex не 28-го → NotIndexDay ✓"

echo "== warp → следующее 28-е 01:00 UTC"
NOW=$(cast block latest -f timestamp --rpc-url $R)
T28=$(python3 - "$NOW" <<'PY'
import sys,datetime as d
n=d.datetime.fromtimestamp(int(sys.argv[1]),d.timezone.utc); y,m=n.year,n.month
t=d.datetime(y,m,28,1,tzinfo=d.timezone.utc)
if t<=n: y,m=(y+1,1) if m==12 else (y,m+1); t=d.datetime(y,m,28,1,tzinfo=d.timezone.utc)
print(int(t.timestamp()))
PY
)
cast rpc evm_setNextBlockTimestamp $T28 --rpc-url $R >/dev/null; cast rpc evm_mine --rpc-url $R >/dev/null
echo "   block UTC: $(date -u -d @"$(cast block latest -f timestamp --rpc-url $R)")"
if VAULT=$V NEW_INDEX=1120000000000000000 forge script script/UpdateIndex.s.sol --rpc-url $R >/dev/null 2>&1; then echo "FAIL: 1.12 прошёл"; exit 1; fi
echo "   UpdateIndex 1.12 → отклонён проверкой до отправки (±11%) ✓"
VAULT=$V NEW_INDEX=1020000000000000000 forge script script/UpdateIndex.s.sol --rpc-url $R --broadcast \
  --unlocked --sender $OWN 2>&1 | grep -E "allowed|new index|index after|COMPLETE"
expect_revert 0xb265ea12 $V "setIndex(uint256,uint256)" 1 1030000000000000000 "${OWN_SIGN[@]}"; echo "   второй setIndex за месяц → IndexAlreadyUpdatedThisMonth ✓"
ok $V "setWorkingPrice(uint256,uint256)" 1 1050600000000000000 "${OWN_SIGN[@]}"
expect_revert 0x3158719a $V "setWorkingPrice(uint256,uint256)" 1 1050600000000000001 "${OWN_SIGN[@]}"; echo "   workingPrice 1.0506 ✓ (+3%), 1.0506…01 → PriceOutOfBand ✓"
echo "== mint tUSDC после нового индекса"; ok $C "faucet(uint256)" 500000000 --private-key $USR_PK; ok $C "approve(address,uint256)" $V 500000000 --private-key $USR_PK
ok $V "mint(uint256,address,uint256,uint256)" 1 $C 500000000 0 --private-key $USR_PK
echo "   BKT=$(call $T 'balanceOf(address)(uint256)' $USR) coverage=$(call $V 'collateralRatioBps(uint256)(uint256)' 1)bps"
echo "DRY RUN OK"
