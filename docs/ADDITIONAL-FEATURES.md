# S.E.C.U.R.E: Additional features

Credit-score access tiers, connected bank accounts, practice markets (stocks and ETFs, prediction markets, sports) and a strategy guide.
As of 2026-10-24. Everything here is **simulated and offline**: fictional banks, fictional instruments, practice money and a self-reported or demo credit score.

Companion documents: [STRATEGIES.md](STRATEGIES.md) (the 27 strategies), [ARCHITECTURE.md](ARCHITECTURE.md) (wallet internals), [FEATURES.md](FEATURES.md) (feature status).

## Contents

1. [The rule: add-ons don't change the core](#1-the-rule-add-ons-dont-change-the-core)
2. [Feature overview](#2-feature-overview)
3. [Credit score and access tiers](#3-credit-score-and-access-tiers)
4. [Connected accounts](#4-connected-accounts)
5. [Practice markets](#5-practice-markets)
6. [Order checks](#6-order-checks)
7. [Responsible play](#7-responsible-play)
8. [Storage and encryption](#8-storage-and-encryption)
9. [Code map](#9-code-map)
10. [Tests](#10-tests)
11. [Limitations and what a real version would need](#11-limitations-and-what-a-real-version-would-need)

---

## 1. The rule: add-ons don't change the core

The wallet (Secure Enclave keys, the hash-chained SQLCipher ledger, budgets, transfers, Face ID approvals) is the core transactions model. The additional features sit beside it and never change it:

| Guarantee | How it is kept |
|---|---|
| Wallet code is untouched | `SecureCore`, `SecureDevice`, `WalletStore`, `LoopbackPayment`, the chain anchor and the wallet screens have no knowledge of credit scores, banks or markets. |
| Separate module | All simulation and rules live in the `SecureConnect` package target, which depends only on `SecureCore` value types (`Money`, canonical encoding). |
| Separate database | `ConnectedStore` owns its own SQLCipher file, `connected.sqlite`, with its own random key under its own Keychain account. The wallet ledger stays append-only and hash-chained; the connected data is mutable and simulated. |
| Credit tiers only limit practice markets | The tier is read inside `ConnectedStore` when a practice order or bet is placed. Wallet transfers never consult it. The test `walletTransfersIgnoreTheCreditScore` sets a score of 320 (Poor: $100 per practice transaction) and then makes a $150 wallet payment, which goes through unchanged. |
| Separate UI state | `ConnectedModel` is its own `@Observable` object, injected beside `AppModel`. The app shows the wallet in the first tab and the add-ons in four more tabs. |

## 2. Feature overview

| Tab | Feature | What it does |
|---|---|---|
| Accounts | Connected accounts | Links fictional banks, imports 60 days of history, syncs new transactions, shows net worth, assets and liabilities, spending by category this month and per-account detail. Large spends and low checking balances raise local notifications. |
| Markets | Stocks & ETFs | Six fictional stocks and two ETFs with a year of simulated daily prices, a bid/ask spread, charts and buy/sell orders. |
| Markets | Prediction markets | Fictional YES/NO events priced 1–99¢. A probability chart, an expected-value slider ("your estimate vs the market") and settlement at 100¢ or 0¢ when the event closes. |
| Markets | Sports | A fictional eight-team league ("Harbor League (simulated)") with moneyline odds, a bet slip that explains implied and fair probabilities and the bookmaker margin, and settlement after each game. |
| Markets | Portfolio | Cash, positions with profit and loss, open bets and full order history. "Next day" advances the simulated market clock; "Reset practice account" starts over with $10,000. |
| Learn | Strategy guide | 27 strategies in four groups, each with how it works, an example, when it is used, risks, complexity, horizon and whether it can be tried in the app ([STRATEGIES.md](STRATEGIES.md)). |
| Learn | Calculators | Expected value (contract price or betting odds), Kelly bet size, a dollar-cost-averaging backtest on simulated prices and a Martingale Monte Carlo simulator (2,000 sessions). |
| Profile | Credit score | Self-reported score (300–850) or one of five demo personas; shows the tier, today's usage and the tier table. |
| Profile | Responsible play | Age confirmation, daily stake limit, 24-hour and 7-day cool-offs and 30-day self-exclusion. |

## 3. Credit score and access tiers

The score follows FICO's published bands. The tier sets how many practice-market transactions the user can make per calendar day and the largest amount any single buy or bet can put at risk.

| Tier | Score | Transactions per day | Max per transaction |
|---|---|---|---|
| Poor | 300–579 | 3 | $100 |
| Fair | 580–669 | 5 | $250 |
| Good | 670–739 | 10 | $500 |
| Very good | 740–799 | 20 | $1,000 |
| Exceptional | 800–850 | 50 | $2,500 |

- **What counts as a transaction:** every buy, sell and bet (`practice_orders` rows with action `open` or `close`). Settlements made by "Next day" don't count.
- **Max per transaction** applies to opening orders (buys and bets) only. Selling reduces risk, so it is never capped by size.
- **The day** is the phone's calendar day (`Calendar.startOfDay`), not the simulated market day, so "Next day" can't be used to reset the allowance.
- **No score, no access:** until a score is set the practice markets are locked. The wallet keeps working.
- **Sources:** `selfReported` (typed in, shown as "unverified") or `demoProfile`. The demo personas are Alex 540 (Poor), Jordan 610 (Fair), Sam 700 (Good), Riley 765 (Very good) and Priya 815 (Exceptional). No credit bureau is contacted.
- **Storage:** the profile is stored in the `meta` table as a versioned canonical encoding (version byte, score `u16`, source `u8`, optional persona label, update time `i64`).

## 4. Connected accounts

`AccountAggregator` is the port for a bank-data provider. The only implementation, `SimulatedAggregator`, generates deterministic history for three fictional institutions:

| Institution | Accounts | Pattern |
|---|---|---|
| Harbor Federal (demo) | Everyday Checking ••4821, High-Yield Savings ••9034 | Payroll $2,150 on the 1st and 15th, rent $1,400 on the 1st, utilities, a card payment, savings transfers and interest |
| Summit Credit Union (demo) | Rewards Card ••1177 | Opens at −$450; card spending and monthly payments |
| Meridian Bank (demo) | Student Checking ••6650 | Smaller payroll ($640), everyday spending |

- **Link** imports the last 60 days for every account at the institution; linking it twice is refused (`alreadyLinked`). **Unlink** deletes its accounts and transactions (cascade).
- **Sync** fetches everything since each account's `synced_through_ms`. Transaction IDs are built from the account, the day and the transaction's position in that day, so syncing is idempotent (`INSERT OR IGNORE`).
- **Alerts** after a sync: any new debit of $500 or more, and, when the sync brought new transactions, any checking balance under $200 (one alert ID per account per day, so it isn't repeated). They are posted as local notifications.
- **Summary:** net worth is the sum of all balances; liabilities are the amounts owed on credit accounts; assets are net worth plus liabilities. Spending by category covers the current calendar month.

## 5. Practice markets

Every user starts with **$10,000 in practice money**. Prices are a pure function of the instrument and the simulated market day, seeded with FNV-1a and generated with SplitMix64 (Box–Muller for normal draws). The same day therefore shows the same prices on every device, and tests can assert exact outcomes. **Next day** advances the market clock by one day and settles anything that closed.

### 5.1 Stocks and ETFs

| Ticker | Name | Type | Sector |
|---|---|---|---|
| ORBT | Orbit Robotics | Stock | Technology |
| QNTA | Quanta Software | Stock | Technology |
| CBLT | Cobalt Energy | Stock | Energy |
| VITA | Vita Health | Stock | Healthcare |
| HLIO | Helio Aerospace | Stock | Industrials |
| HRVS | Harvest Foods | Stock | Consumer staples |
| TMKT | Total Market Index ETF | ETF | Broad market |
| AGGB | Aggregate Bond ETF | ETF | Bonds |

- Prices follow geometric Brownian motion with a per-instrument annual drift and volatility (for example ORBT 12 % and 35 %; `dt = 1/252`), with 252 days of history before day 0 so charts and the DCA backtest have a year of data.
- Orders fill at the ask when buying and the bid when selling; the half-spread is 0.05 % of the price (minimum 1¢).
- Positions track quantity and cost, so profit and loss is shown per holding.

### 5.2 Prediction markets

- Twelve fictional event templates (economics, weather, infrastructure, culture, entertainment, local politics, business and sports). One new event opens each market day and stays open for 3–11 days.
- The mid price drifts toward the eventual outcome as the close day approaches. Quotes are the mid ±1¢, so the YES ask plus the NO ask is 102¢ (the market's spread).
- On the close day each YES or NO contract pays 100¢ if it was right and 0¢ if not.
- The contract screen shows the market's implied chance and lets the user set their own estimate to see the edge per contract for YES and NO.

### 5.3 Sports

- Eight fictional teams with Elo-style ratings; two games are scheduled each market day.
- The win probability is `1 / (1 + 10^((away − home − 60) / 400))` (60 points of home advantage). Moneyline odds add a 4.5 % bookmaker margin.
- The bet slip shows both sides' implied probability, the margin-free "fair" probability and the margin, plus the return if the bet wins.
- Bets settle on the first "Next day" at or after the game day: a win returns stake plus profit at the odds taken; a loss returns nothing.

## 6. Order checks

`PlayGuard.check` runs inside `ConnectedStore` before any order or bet is written, in this order. The first failure is shown to the user with a specific message.

| # | Check | Applies to | Example message |
|---|---|---|---|
| 1 | Self-exclusion active | Buys and bets | Self-excluded from practice markets until *date*. |
| 2 | Cool-off active | Buys and bets | Cooling off until *date*. You can still sell. |
| 3 | Credit score set | All orders | Set a credit score in Profile to unlock practice markets. |
| 4 | Age confirmed (18+ for stocks and predictions, 21+ for sports) | All orders | Sports needs age 21+ (Profile ▸ Responsible play). |
| 5 | Tier transaction count | All orders | The Good tier allows 10 practice transactions a day. |
| 6 | Tier transaction size | Buys and bets | The Good tier allows up to $500.00 per transaction. |
| 7 | Daily stake limit | Buys and bets | Over your daily stake limit of $1,000.00 ($950.00 used today). |
| 8 | Enough practice cash | Buys and bets | Not enough practice cash: $40.00 available. |

Market rules (instrument exists, market open, quantity positive, enough shares or contracts to sell) are checked by the store around these.

## 7. Responsible play

| Control | Behaviour |
|---|---|
| Age confirmation | Self-attested: not confirmed, 18+, or 21+. Stocks and prediction markets need 18+; sports needs 21+, as in most US states. |
| Daily stake limit | $100, $250, $500, $1,000 (default), $2,500 or no limit. Counts money put at risk by today's buys and bets. |
| Cool-off | 24 hours or 7 days. Blocks buys and bets; selling stays possible so a user can reduce risk. |
| Self-exclusion | 30 days. Same effect as a cool-off, shown in red. |
| Can't be shortened | `PlayGuard.validateChange` rejects any settings change that would end an active cool-off or self-exclusion early (`cannotShortenExclusion`). |
| Reset | "Reset practice account" clears practice orders, positions and bets and restarts the market clock, but keeps the credit score and all responsible-play settings. |

The Profile screen points to the National Council on Problem Gambling (ncpgambling.org) for help.

## 8. Storage and encryption

| Item | Value |
|---|---|
| File | `Application Support/Connected/connected.sqlite` |
| Encryption | SQLCipher 4.19.0 with a random 256-bit raw key, the same settings as the wallet ledger ([ARCHITECTURE §6.2](ARCHITECTURE.md#62-sqlcipher)) |
| Key | Keychain generic password, service `com.example.secure`, account `connected.database-key`, `WhenUnlockedThisDeviceOnly`; separate from `wallet.database-key` |
| File protection | Data Protection `complete` on the folder and file; excluded from iCloud and Finder backups |
| Missing key | If the file exists but its key doesn't, opening fails with `databaseKeyMissing`. The store never re-keys or silently replaces data. |
| Migrations | `PRAGMA user_version`, one transaction per upgrade (currently v1) |

**Schema (v1, all tables `STRICT`)**

| Table | Contents |
|---|---|
| `meta` | Credit profile, responsible-play settings, simulated market day |
| `linked_accounts` | Institution, account name, kind (checking, savings, credit), last four digits, currency, opening balance, link and sync times |
| `bank_transactions` | Posted time, signed amount, merchant, category; indexed by account and time; deleted with the account |
| `practice_orders` | Every buy, sell, bet and settlement: market, instrument, side, action (open, close, settle), quantity, price, cash change, note |
| `practice_positions` | Open stock and contract holdings with quantity and cost |
| `practice_bets` | Fixture, selection, stake, odds taken, status (open, won, lost), payout |

Practice cash is not stored; it is $10,000 plus the sum of `cash_delta_minor` over all orders, so the cash balance can't drift from the history.

## 9. Code map

| File | Role |
|---|---|
| [`SecureConnect/CreditTier.swift`](../Packages/SecureKit/Sources/SecureConnect/CreditTier.swift) | `CreditScore`, `CreditTier`, `TierLimits`, `CreditProfile`, demo personas |
| [`SecureConnect/Banking.swift`](../Packages/SecureKit/Sources/SecureConnect/Banking.swift) | Institutions, accounts, transactions, alerts, `AccountAggregator`, `SimulatedAggregator` |
| [`SecureConnect/Markets.swift`](../Packages/SecureKit/Sources/SecureConnect/Markets.swift) | Equities and `EquitySimulator`, prediction events and catalog, teams, fixtures and sports catalog |
| [`SecureConnect/Odds.swift`](../Packages/SecureKit/Sources/SecureConnect/Odds.swift) | American and decimal odds, implied probability, margin; `StrategyMath` (EV, Kelly, DCA, Martingale) |
| [`SecureConnect/ResponsiblePlay.swift`](../Packages/SecureKit/Sources/SecureConnect/ResponsiblePlay.swift) | `AgeConfirmation`, `PlaySettings`, `PlayBlock`, `PlayGuard` |
| [`SecureConnect/StrategyCatalog.swift`](../Packages/SecureKit/Sources/SecureConnect/StrategyCatalog.swift) | The 27 strategies and the disclaimer |
| [`SecureConnect/SimRandom.swift`](../Packages/SecureKit/Sources/SecureConnect/SimRandom.swift) | Deterministic seeding (FNV-1a), SplitMix64, Box–Muller |
| [`SecureStore/Connected/ConnectedStore.swift`](../Packages/SecureKit/Sources/SecureStore/Connected/ConnectedStore.swift) | The `ConnectedStore` actor, schema and encrypted database opener |
| [`App/Connected/ConnectedModel.swift`](../App/Connected/ConnectedModel.swift) | `@Observable` UI state, actions, error text, notifications for account alerts |
| [`App/Connected/AccountsView.swift`](../App/Connected/AccountsView.swift) | Net worth header, spending chart, accounts and transactions, connect sheet |
| [`App/Connected/MarketsView.swift`](../App/Connected/MarketsView.swift) | Practice header, stock, contract and game lists and details, bet slip, portfolio |
| [`App/Connected/LearnView.swift`](../App/Connected/LearnView.swift) | Strategy list and detail, four calculators |
| [`App/Connected/ProfileView.swift`](../App/Connected/ProfileView.swift) | Credit score, tier table, responsible-play controls |
| [`App/Connected/ConnectedComponents.swift`](../App/Connected/ConnectedComponents.swift) | Loading gate, banner, "Simulated" badge, formatting helpers |

## 10. Tests

54 tests for the additional features (of 123 in total), all passing on macOS (`swift test`) and on the iOS Simulator (`xcodebuild test`).

| Suite | Tests | Covers |
|---|---|---|
| `SecureConnectTests` | 42 | Tier bands and limits, profile encoding, demo personas; deterministic simulators (prices, events, fixtures, bank history; advancing days never rewrites history); spreads (contracts total 102¢) and the bookmaker margin; odds conversions, EV and Kelly; DCA and Martingale; every `PlayGuard` rule and its order; exclusions that can be extended but not shortened; strategy catalog completeness and worked examples |
| `SecureStoreTests/ConnectedStoreTests` | 12 | Linking and idempotent sync, net worth, unlinking, alerts, stock orders, contract and bet settlement, tier access, cool-off (blocks buying, allows selling, can't be shortened), reset keeps score and settings, the file is encrypted under its own key, wallet transfers ignore the credit score |

## 11. Limitations and what a real version would need

- **Simulated only.** No real bank, broker, exchange or sportsbook is contacted, and nothing leaves the phone. Real connections would need a server-side aggregator (bank data APIs require registered back ends), which conflicts with the app's offline design.
- **The credit score is unverified.** A real tier system would need a consumer's permission to pull a bureau report, plus compliance with credit-reporting and fair-lending rules.
- **Real money would be regulated.** Securities brokerage, prediction-market (event contract) trading and sports betting each need licences and vary by jurisdiction. The app deliberately uses practice money only.
- **Education, not advice.** The strategy guide and calculators explain general ideas; they are not personal financial advice.
- **The phone's clock** sets the daily allowance window and cool-off end times, and the owner can change it. That is acceptable for practice money and would not be for real money.
