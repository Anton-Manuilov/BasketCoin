# Chainlink price feeds for USDT / USDC (v5.2+)

Source: Chainlink reference data directory (data.chain.link / docs.chain.link). Each address was checked on-chain with
`cast call` on 25.10.2026: `description()`, `decimals()` and `latestRoundData()` return valid values (answer ≈ $0.998–1.000).

| Network | Pair | Proxy address | Decimals | Heartbeat | Deviation |
|---|---|---|---|---|---|
| Base mainnet (8453) | USDC / USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | 8 | 86400 s (24 h) | 0.3% |
| Base mainnet (8453) | USDT / USD | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` | 8 | 86400 s (24 h) | 0.3% |
| Base Sepolia (84532) | USDC / USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` | 8 | 86400 s (24 h) | 0.1% |
| Base Sepolia (84532) | USDT / USD | `0x3ec8593F930EA45ea58c968260e6e9FF53FC934f` | 8 | 86400 s (24 h) | 0.1% |

Note: the directory also lists other USDC/USD and USDT/USD entries on Base mainnet (e.g. 18-decimal variants
`0xd0Dc8c91…33Ad`, `0xE6c6bf78…B00d` and `0x458138Fc…9061`, `0xE5fa3A4e…1A70`). Use the standard 8-decimal proxies above.

Deploy settings (`script/Deploy.s.sol`): `USDT_FEED`, `USDC_FEED`, `FEED_STALENESS=90000` (25 h = heartbeat + 1 h margin).
Mainnet also requires `SEQUENCER_UPTIME_FEED` (Chainlink L2 Sequencer Uptime Feed for Base; take it from docs.chain.link).

If a feed stops updating or returns an invalid answer, mint/redeem in that stable revert (`FeedUnavailable`) and its
reserve is excluded from coverage. Backup: owner/guardian `freezeStableMint(stable)` (instant), changing the feed —
`setStableFeed` via the 2-day timelock.
