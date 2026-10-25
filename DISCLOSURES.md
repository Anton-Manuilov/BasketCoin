# BasketCoin v5.2 — раскрытие рисков / Risk Disclosures

> При расхождении версий приоритет у русской. / The Russian text is authoritative in case of discrepancy.

## RU

### D-1 (M2). Права владельца на цену
Владелец (owner, планируется Safe 2-of-3) без таймлока может:
- менять рабочую цену `setWorkingPrice` в пределах ±3% от индекса в любой день;
- фиксировать индекс `setIndex` 28-го числа в пределах ±11% от предыдущего.

Злоупотребление ключом владельца (кража, сговор) позволяет цикл «снизить цену → заминтить → поднять → выкупить» и извлечь
до ~3% (в любой день) или до ~11% (28-го) за цикл из резерва за счёт остальных держателей. Ограничения: жёсткие коридоры
±3%/±11% в коде, лимиты минта (пол покрытия 150%, часовой и блоковый лимиты), заморозка минта перед 28-м (v5.1),
публичные события `WorkingPriceUpdated` / `IndexUpdated`, которые можно отслеживать. Права на эмиссию токена
(`setTokenRole`) меняются только через таймлок 7 дней; параметры — через таймлок 2 дня.

**Сэндвич вокруг смены рабочей цены (AuditAgent AA-3).** С v5.2 в коде: один вызов `setWorkingPrice` меняет рабочую
цену не больше чем на 0,5% от текущей и не чаще раза в час на корзину. 0,5% меньше суммы комиссий (0,6%), поэтому
сэндвич одного шага убыточен; движение на 3% занимает ~6 ч публичных шагов. `setIndex` 28-го этим ограничением не
затронут (сбрасывает рабочую цену на новый индекс, ±11%; защищён заморозкой минта перед 28-м). Остаточный риск —
позиция, удерживаемая через несколько шагов; он ограничен лимитами минта и мониторингом.

### D-2 (M4). Выбор стейбла при выкупе
Покрытие считается по корзине в целом, а выплата идёт из резерва выбранного стейбла. Если один стейбл (например, USDT)
теряет привязку, выкуп в нём блокируется, но выкуп в другом стейбле (USDC) возможен, пока общее покрытие выше порогов.
Те, кто выкупает первыми, забирают «здоровый» стейбл; оставшимся держателям достаётся больше депегнутого. Если фид
стейбла сломан или устарел, с v5.1 его резерв не засчитывается в покрытие, что снижает этот эффект, но не устраняет
его при «медленном» депеге внутри коридора ±5%.

### D-3. Риски эмитентов стейблкоинов
- **Заморозка/блокировка.** Tether и Circle могут заблокировать адрес Vault или отдельных пользователей; заблокированный
  резерв нельзя выплатить.
- **Апгрейд контракта токена.** USDT и USDC — обновляемые контракты; эмитент может изменить логику (комиссии, паузу).
- **Потеря привязки.** Исторически USDC опускался до ~$0,87 (март 2023), USDT — до ~$0,95 (май 2022). При цене вне
  $0,95–$1,05 минт и выкуп в этом стейбле блокируются; покрытие считается по min(p, $1).
- **Регуляторные риски.** Эмитент может прекратить поддержку сети или юрисдикции.
- **Оракул.** Цены стейблов берутся из Chainlink-совместимых фидов; при сбое фида операции с этим стейблом
  останавливаются, а его резерв временно не засчитывается в покрытие.
- **Сеть Base.** При остановке секвенсора и в течение 1 часа после восстановления минт и выкуп запрещены (если задан фид
  L2 Sequencer Uptime).

### D-4. Выкуп перед снижением индекса
Заморозка v5.1 закрывает только минт. Выкуп перед 28-м остаётся открытым, чтобы держатели могли выйти в любой момент.
Держатель, который ожидает снижения индекса, может выкупить по старой цене. Это осознанный выбор в пользу права на выход.

### D-5. Стейблы без фида (AuditAgent AA-1)
С v5.2 USDT и USDC подключены к Chainlink-фидам USDT/USD и USDC/USD сразу при деплое (адреса — `config/chainlink-feeds.md`):
депег, устаревший или сломанный фид блокируют операции в этом стейбле автоматически. Резервная мера:  owner или guardian **мгновенно** (без
таймлока) запрещают минт в этом стейбле (`freezeStableMint`); снять запрет можно только через таймлок 2 дня
(`unfreezeStableMint`). Выкуп в этом стейбле не блокируется. Защита зависит от того, насколько быстро guardian заметит
депег (мониторинг). В mainnet для USDT/USDC рекомендуется подключить Chainlink-фиды (`setStableFeed`, таймлок 2 дня),
тогда депег блокирует операции автоматически. Резерв уже внесённого депегнутого стейбла до смены ручной цены
учитывается в покрытии по $1 (см. D-2).

## EN

### D-1 (M2). Owner price powers
The owner (planned: Safe 2-of-3) can, without a timelock:
- move the working price (`setWorkingPrice`) within ±3% of the index on any day;
- set the index (`setIndex`) on the 28th within ±11% of the previous one.

Abuse of the owner key (theft or collusion) allows a "lower price → mint → raise price → redeem" loop. It extracts up
to ~3% (any day) or up to ~11% (on the 28th) per cycle from the reserve, at the expense of other holders. Mitigations:
hard-coded ±3%/±11% bands, mint limiter (150% coverage floor, hourly and per-block caps), the pre-index mint freeze
(v5.1), and public `WorkingPriceUpdated` / `IndexUpdated` events for monitoring. Token minting rights (`setTokenRole`)
change only through a 7-day timelock; parameters change through a 2-day timelock.

**Sandwich around a working-price change (AuditAgent AA-3).** Since v5.2, enforced in code: one `setWorkingPrice`
call moves the working price by at most 0.5% of its current value, at most once per hour per basket. 0.5% is below the
0.6% round-trip fee, so a single-step sandwich loses money; a 3% move takes ~6 hours of public steps. `setIndex` on the
28th is not affected (it resets the working price to the new index within ±11% and is protected by the pre-index mint
freeze). Residual risk — a position held across several steps — is bounded by the mint limiter and monitoring.

### D-2 (M4). Stablecoin choice on redemption
Coverage is computed per basket, while each payout comes from the reserve of the chosen stablecoin. If one stablecoin
(e.g. USDT) depegs, redemption in it is blocked. Redemption in the other one (USDC) stays open while total coverage
remains above the thresholds. Early redeemers take the healthy stablecoin, and remaining holders end up with a larger
share of the depegged one. Since v5.1, the reserve of a stablecoin whose feed is broken or stale is excluded from
coverage. This reduces the effect but does not remove it for a slow depeg inside the ±5% band.

### D-3. Stablecoin issuer risks
- **Freezing/blacklisting.** Tether and Circle can blacklist the Vault or individual users; frozen reserves cannot be paid.
- **Token upgrades.** USDT and USDC are upgradeable; the issuer can change their behaviour (fees, pause).
- **Depeg.** Historically USDC fell to ~$0.87 (March 2023) and USDT to ~$0.95 (May 2022). Outside $0.95–$1.05, minting
  and redemption in that stablecoin are blocked; coverage uses min(p, $1).
- **Regulatory.** An issuer may drop support for a network or jurisdiction.
- **Oracle.** Stablecoin prices come from Chainlink-compatible feeds. If a feed fails, operations in that stablecoin
  stop and its reserve is temporarily excluded from coverage.
- **Base network.** While the sequencer is down, and for 1 hour after it recovers, minting and redemption are
  disabled (when an L2 Sequencer Uptime feed is configured).

### D-4. Redemption before an index decrease
The v5.1 freeze covers minting only. Redemption stays open before the 28th so that holders can always exit.
A holder who expects the index to fall can redeem at the old price. This is a deliberate choice in favour of the right to exit.

### D-5. Feedless stablecoins (AuditAgent AA-1)
Since v5.2 USDT and USDC use Chainlink USDT/USD and USDC/USD feeds from deployment (addresses in
`config/chainlink-feeds.md`): a depeg or a stale/broken feed blocks operations in that stablecoin automatically. Backup: the owner or guardian can **instantly** (no
timelock) disable minting with that stablecoin (`freezeStableMint`); lifting it requires the 2-day timelock
(`unfreezeStableMint`). Redemption in that stablecoin stays open. Protection depends on how quickly the guardian
detects the depeg (monitoring). On mainnet, Chainlink feeds for USDT/USDC are recommended (`setStableFeed`, 2-day
timelock) so that a depeg blocks operations automatically. Reserves of the depegged stablecoin already deposited are
still valued at $1 in coverage until the manual price is changed (see D-2).
