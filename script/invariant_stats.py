#!/usr/bin/env python3
"""Агрегирует статистику handler'а (invariant-stats/*.csv) по всем прогонам:
вызовы, успехи, доля откатов и причины откатов (по селектору ошибки)."""
import collections, glob, os
from hashlib import new as _h

try:
    from Crypto.Hash import keccak  # pycryptodome (ставится вместе со slither)

    def k4(sig):
        return "0x" + keccak.new(digest_bits=256, data=sig.encode()).hexdigest()[:8]
except ImportError:  # без pycryptodome — покажем сырые селекторы
    def k4(sig):
        return None

ERRORS = [
    "ZeroAddress()", "ZeroAmount()", "UnknownBasket(uint256)", "BasketExists(uint256)", "TokenAlreadyRegistered(address)",
    "StableNotEnabled(address)", "StableAlreadyEnabled(address)", "StableDepegged(address,uint256)",
    "NoPendingStable(address)", "TimelockNotExpired(uint256)", "UnsupportedDecimals(uint8)", "NotIndexDay(uint256)",
    "IndexAlreadyUpdatedThisMonth()", "PriceOutOfBand(uint256,uint256)", "InvalidPrice()", "InvalidFeeRecipient(address)",
    "MinMintOutOfRange(uint256)", "BelowMinMint(uint256,uint256)", "Slippage(uint256,uint256)",
    "InsufficientReserve(uint256,uint256)", "RenounceDisabled()", "RedemptionSuspended(uint256,uint256,uint256)",
    "EnforcedPause()", "IndexChangeTooLarge(uint256,uint256,uint256,uint256,uint256)", "ERC20InsufficientBalance(address,uint256,uint256)", "ReentrancyGuardReentrantCall()",
]
NAMES = {k4(e): e.split("(")[0] for e in ERRORS if k4(e)}

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "invariant-stats")
for path in sorted(glob.glob(os.path.join(root, "*.csv"))):
    agg = collections.OrderedDict()
    reasons = collections.defaultdict(collections.Counter)
    metrics = collections.Counter()
    for line in open(path):
        name, c, s = line.strip().split(",")
        if name.startswith("metric:"):
            metrics[name[len("metric:"):]] += int(c)
            continue
        if name.startswith("reason:"):
            _, action, sel = name.split(":")
            reasons[action][sel[:10]] += int(c)
            continue
        a = agg.setdefault(name, [0, 0])
        a[0] += int(c)
        a[1] += int(s)
    tc = sum(v[0] for v in agg.values())
    ts = sum(v[1] for v in agg.values())
    print(f"== {os.path.basename(path)}")
    print(f"{'action':<16}{'calls':>10}{'ok':>10}{'reverted':>10}{'revert%':>9}")
    for k, (c, s) in agg.items():
        if c == 0:
            continue
        print(f"{k:<16}{c:>10}{s:>10}{c-s:>10}{(c-s)*100/c:>8.1f}%")
    print(f"{'TOTAL':<16}{tc:>10}{ts:>10}{tc-ts:>10}{(tc-ts)*100/max(tc,1):>8.1f}%")
    for action, cnt in reasons.items():
        parts = ", ".join(f"{NAMES.get(sel, sel)}={n}" for sel, n in cnt.most_common())
        print(f"  revert reasons [{action}]: {parts}")
    for k, v in metrics.items():
        print(f"  metric {k}: {v}")
