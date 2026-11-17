#!/usr/bin/env python3
"""1109: стартовая цена пула Uniswap v3 BKT/USDC 0,3% на Base и calldata для NPM.

token0 = USDC (6 знаков), token1 = BKT (18 знаков, OZ ERC20 по умолчанию) — так требует бот (pick-deployer.sh гарантирует BKT > USDC).
Цена Uniswap = token1/token0 в сырых единицах = (1/ref) * 1e18/1e6 = 1e12/ref;  sqrtPriceX96 = sqrt(1e12/ref) * 2^96
(то же, что usd_to_sqrt() в basketcoin-mm/v52/bkt_mm.py и hb/setup_pool.py, здесь — точной целочисленной арифметикой).
ref = workingPrice * ref_multiplier (1,2 = 1 + BUFFER 20%, как ref_price() бота).

  script/pool-init.py --bkt 0x... [--index 1.6658 | --vault 0x... --rpc URL] [--mult 1.2] [--core-usd 200]
Ничего не отправляет: печатает числа и calldata. Отправка — вручную (cast send / Basescan Write) после сверки.
"""
import argparse, json, math, subprocess, sys
from decimal import Decimal, getcontext
getcontext().prec = 80

USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
NPM = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1"
FACTORY = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD"
FEE, SPACING = 3000, 60
Q96 = 2 ** 96

def cast(*a):
    return subprocess.check_output(["cast", *a], text=True).strip()

def sqrt_x96(ref_wei):
    # sqrt( 1e12 / (ref_wei/1e18) ) * 2^96 = isqrt( 1e30 * 2^192 / ref_wei )
    return math.isqrt(10**30 * Q96 * Q96 // ref_wei)

def tick_of(sqrtp):
    return math.floor(math.log((sqrtp / Q96) ** 2) / math.log(1.0001))

def usd_of_tick(t): return 1e12 / (1.0001 ** t)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bkt", required=True)
    ap.add_argument("--index", help="workingPrice в USD, напр. 1.6658 (если не задан --vault)")
    ap.add_argument("--vault"); ap.add_argument("--rpc", default="https://mainnet.base.org")
    ap.add_argument("--basket", type=int, default=1)
    ap.add_argument("--mult", default="1.2")
    ap.add_argument("--core-usd", type=float, default=200.0, help="справочно: core-позиция бота ($/сторону)")
    ap.add_argument("--spread-pct", type=float, default=0.5)
    ap.add_argument("--recipient", default="<кошелёк бота>")
    a = ap.parse_args()

    bkt = cast("to-check-sum-address", a.bkt)
    if int(bkt, 16) <= int(USDC, 16):
        sys.exit(f"СТОП: BKT {bkt} < USDC — token0 будет BKT, бот не работает. Деплоить с другого адреса (pick-deployer.sh).")
    if a.vault:
        out = cast("call", a.vault, "baskets(uint256)(address,uint256,uint256,uint256,uint64,bool)", str(a.basket), "--rpc-url", a.rpc).split("\n")
        wp_wei = int(out[2].split()[0]); src = f"vault.baskets({a.basket}).workingPrice"
    else:
        if not a.index: sys.exit("нужен --index или --vault")
        wp_wei = int(Decimal(a.index) * 10**18); src = "--index"
    ref_wei = int(Decimal(wp_wei) * Decimal(a.mult))
    ref = ref_wei / 1e18
    s = sqrt_x96(ref_wei)
    s_float = int(math.sqrt(1e12 / ref) * 2**96)           # формула бота (float)
    back = 1e12 / ((s / Q96) ** 2)
    tick = tick_of(s)
    print(f"workingPrice = {wp_wei/1e18:.6f}  ({src});  ref = wp x {a.mult} = {ref:.6f} USDC/BKT")
    print(f"token0 = USDC {USDC} (6)\ntoken1 = BKT  {bkt} (18)\nfee = {FEE}, tickSpacing = {SPACING}")
    print(f"sqrtPriceX96 = {s}")
    print(f"  сверка с bkt_mm.usd_to_sqrt(): {s_float}  (отн. разница {abs(s - s_float)/s:.2e})")
    print(f"  обратно в цену: {back:.6f} USDC/BKT; tick = {tick}")
    assert abs(back / ref - 1) < 1e-9 and abs(s - s_float) / s < 1e-9
    cd = cast("calldata", "createAndInitializePoolIfNecessary(address,address,uint24,uint160)", USDC, bkt, str(FEE), str(s))
    print("\n== 1) NPM.createAndInitializePoolIfNecessary  (to =", NPM, ")")
    print(f"params: token0={USDC} token1={bkt} fee={FEE} sqrtPriceX96={s}")
    print("calldata:", cd)
    print(f"cast send {NPM} 'createAndInitializePoolIfNecessary(address,address,uint24,uint160)' {USDC} {bkt} {FEE} {s} --rpc-url $RPC --private-key $MM_PK")
    print(f"проверка: cast call {FACTORY} 'getPool(address,address,uint24)(address)' {USDC} {bkt} {FEE};  slot0().sqrtPriceX96 == {s}")

    # справочно: core-позиция (её кладёт сам бот, place_core(): ref ± spread, тики кратны 60)
    t_ask_lo = math.floor(math.log(1e12 / (ref * (1 + a.spread_pct / 100))) / math.log(1.0001) / SPACING) * SPACING
    t_bid_hi = math.ceil(math.log(1e12 / (ref * (1 - a.spread_pct / 100))) / math.log(1.0001) / SPACING) * SPACING
    a0 = int(a.core_usd * 1e6); a1 = int(a.core_usd / ref * 1e18)
    print("\n== 2) справочно: NPM.mint для core (ПОЗИЦИИ КЛАДЁТ БОТ, вручную не нужно)")
    print(f"tickLower={t_ask_lo} (≈{usd_of_tick(t_ask_lo):.5f})  tickUpper={t_bid_hi} (≈{usd_of_tick(t_bid_hi):.5f})  current tick={tick}")
    print(f"amount0Desired={a0} (USDC ${a.core_usd:.0f})  amount1Desired={a1} (BKT ≈{a1/1e18:.4f})  min=0,0  recipient={a.recipient}")
    print(f"mint tuple: ({USDC},{bkt},{FEE},{t_ask_lo},{t_bid_hi},{a0},{a1},0,0,{a.recipient},<deadline>)")

if __name__ == "__main__":
    main()
