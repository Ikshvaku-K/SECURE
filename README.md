# S.E.C.U.R.E

**Spatial Enclave Cryptography for Untethered Reserves & Expenses**

An offline-first iOS wallet. It signs transactions with a key held in the Secure Enclave, keeps an encrypted, hash-chained local ledger with category budgets, and pays phone to phone, with the distance between the phones measured by Ultra-Wideband and signed into every payment. It needs no internet connection and no servers.

Alongside the wallet, the app has a set of **simulated** add-ons: credit-score access tiers, connected bank accounts in one dashboard, practice markets (stocks and ETFs, prediction markets, sports) and a guide to 27 trading, investing and betting strategies. They run in their own module and their own encrypted database and **don't change the wallet's transaction model**.

> **Prototype.** Every bank, instrument, team and price in the add-ons is fictional, and the markets use practice money only. Nothing connects to a real bank, broker, exchange or sportsbook. The strategy guide is general education, not financial advice.

## Features

**Wallet (core)**
- P-256 signing key created inside the Secure Enclave; every signature needs Face ID (`.biometryAny`), enforced by the hardware.
- SQLCipher 4.19.0 database with a random 256-bit key in the Keychain (`WhenUnlockedThisDeviceOnly`), Data Protection `complete`, excluded from backups.
- Append-only, hash-chained ledger with a Keychain anchor that detects database rollbacks, plus signed evidence when an offline double-spend is attempted.
- Category budgets (monthly, weekly, rolling, custom) with 80 % and 100 % alerts, soft caps with an explicit override, and hard caps.
- Local notifications with Approve and Deny actions; a payment request opens an approval sheet.
- **Phone-to-phone payments:** both people open *Pay or get paid nearby*. The phones find each other over Bluetooth and peer-to-peer Wi-Fi (MultipeerConnectivity), measure each other with UWB (NearbyInteraction), and both approve with Face ID. The payee checks everything before the payer commits, and the payer keeps a countersigned receipt. If the link drops after the payer commits, **Retry** re-sends the same signed payment; it can't be credited twice.
- **Payment requests:** the payee can ask a nearby phone for an amount, with a note. The payer picks a category, sees its budget check and pays with Face ID, or declines.
- Transfer protocol with a mutual spatial proof: each phone signs its own distance reading, and a payment needs both within 1 m and in agreement.

**Additional features (simulated)**
- **Credit tiers:** a self-reported or demo credit score (300–850) sets how many practice-market transactions are allowed per day (3 to 50) and the largest single transaction ($100 to $2,500). Wallet transfers are never limited by the score.
- **Connected accounts:** link three fictional banks, import and sync their history, and see net worth, assets, liabilities and spending by category in one place, with alerts for large spends and low balances.
- **Practice markets:** $10,000 of practice money across stocks and ETFs (bid/ask spread, price charts) and prediction markets (YES/NO contracts with an expected-value slider), with a portfolio and a simulated market clock. Sports betting is built but **switched off for now** (`AppFeatures.sportsBetting`).
- **Learn:** 27 strategies with how they work, examples, risks and complexity ([docs/STRATEGIES.md](docs/STRATEGIES.md)), plus expected-value, Kelly, DCA-backtest and Martingale calculators.
- **Responsible play:** age confirmation (18+, or 21+ for sports), a daily stake limit, 24-hour and 7-day cool-offs, and a 30-day self-exclusion that can't be shortened.

## Status

| Part | State |
|---|---|
| Phase 1: core engine | Done; runs on the iOS Simulator |
| Phase 2: approvals | Implemented; Secure Enclave signing is waiting for a first run on a real iPhone |
| Additional features | Done; simulated |
| Phases 3–4: phone-to-phone payments with UWB | Implemented and verified on two Simulators; first run on two iPhones pending |
| Phases 5–7: UI polish, hardening, distribution | Planned |

Tests: **144** (Swift Testing), passing on macOS and on the iOS Simulator.

## Documentation

| Doc | Contents |
|---|---|
| [docs/PRD.md](docs/PRD.md) | Original product requirements |
| [docs/DESIGN.md](docs/DESIGN.md) | PRD review against the iOS 27.1 SDK, threat model, architecture, transfer protocol, schema, decisions |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Technical reference: stack, modules, runtime, cryptography, encryption at rest, protocol, data map, build and tests |
| [docs/FEATURES.md](docs/FEATURES.md) | Every feature with status, evidence and code location; PRD coverage; known limitations |
| [docs/ADDITIONAL-FEATURES.md](docs/ADDITIONAL-FEATURES.md) | Credit tiers, connected accounts, practice markets, order checks, responsible play, storage |
| [docs/STRATEGIES.md](docs/STRATEGIES.md) | The 27 strategies, generated from the app's catalog |
| [PHASES.md](PHASES.md) | Phase checklist |
| [WORKLOG.md](WORKLOG.md) | Development log |

## Requirements

- Xcode 27.1 with the iOS 27.1 SDK and Swift 6.4 (the code uses Swift 6 language mode)
- Deployment target: iOS 26.0
- The Simulator covers the ledger, budgets, notifications, a simulated Face ID prompt and all the additional features. Secure Enclave keys, Bluetooth and UWB need real devices, and UWB ranging needs two UWB-capable iPhones.
- The first build downloads SQLCipher through Swift Package Manager (`sqlcipher/SQLCipher.swift` 4.19.0, a 50.5 MB binary framework verified by checksum).

## Layout

| Path | Contents |
|---|---|
| `SECURE.xcodeproj`, `App/` | SwiftUI app: the Wallet tab (balance, budgets, pay / receive / request flows, chain explorer, security diagnostics) |
| `App/Peer/` | Phone-to-phone payments: Nearby screen, MultipeerConnectivity link, NearbyInteraction ranger (and a loopback link for two Simulators) |
| `Config/Info.plist` | Nearby Interaction, local network and Bonjour keys |
| `App/Connected/` | The Accounts, Markets, Learn and Profile tabs |
| `Packages/SecureKit/Sources/SecureCore` | Money, canonical encoding, hash chain, signed messages, spatial proof, budget engine, double-spend evidence (pure Swift) |
| `Packages/SecureKit/Sources/SecureStore` | SQLCipher ledger (`WalletStore`), schema, Keychain chain anchor, in-process payment flow; `Connected/ConnectedStore` for the add-ons |
| `Packages/SecureKit/Sources/SecureDevice` | Keychain, Secure Enclave signer, Simulator signer, notifications |
| `Packages/SecureKit/Sources/SecurePeer` | The phone-to-phone payment protocol over any message link: messages, payer and payee steps, requests, re-delivery |
| `Packages/SecureKit/Sources/SecureConnect` | Credit tiers, simulated banks and markets, odds and strategy maths, responsible-play rules, strategy catalog |
| `Packages/SecureKit/Tests` | 144 tests: SecureCore 52, SecureStore 30, SecurePeer 20, SecureConnect 42 |

Each phone also has two in-process demo counterparties: "Demo Issuer" mints funds and "Demo Shop" receives payments, each with its own encrypted ledger and a simulated 0.40 m distance. That's how a single phone gets money to send to another.

## Build, test, run

Package tests on the Mac (fast):

```bash
cd Packages/SecureKit && swift test
```

Package tests on the iOS Simulator:

```bash
cd Packages/SecureKit && xcodebuild test -scheme SecureKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

App build for the Simulator:

```bash
xcodebuild -project SECURE.xcodeproj -scheme SECURE -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData build
```

**Try a phone-to-phone payment:** on each device, Wallet ▸ *Receive $500 from Demo Issuer* (for the payer), then Wallet ▸ *Pay or get paid nearby*. Tap the other phone, enter an amount and tap Send (or switch to **Request** to ask them for money). The other phone shows the offer or request; both approve with Face ID. Two Simulators on one Mac work too (they connect over loopback instead of Multipeer, and their distance readings are flagged simulated, which only debug builds accept).

Or open `SECURE.xcodeproj` in Xcode and run. On the Simulator, enroll Face ID first (Features ▸ Face ID ▸ Enrolled), then use Matching Face to approve payments. To try the practice markets, set a score in the Profile tab (or pick a demo persona) and confirm your age.

**Running on an iPhone:** the bundle identifier is the placeholder `com.example.secure`. Change `PRODUCT_BUNDLE_IDENTIFIER` in the project to your own reverse-DNS identifier, and the Keychain service in `App/AppModel.swift` and `App/Connected/ConnectedModel.swift` to match. Then choose your team under Signing & Capabilities and turn on Developer Mode on the phone.

## License

[MIT](LICENSE). SQLCipher Community Edition is distributed by Zetetic under its own BSD-style licence.
