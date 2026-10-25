# WORKLOG

## 2026-10-24 — Project start (Phase 0)

- Created the project with git (branch `main`), README, PRD (verbatim, formatting restored), DESIGN (PRD review and architecture), PHASES and this log.
- Environment: Xcode 27.1 (27A9275), iOS 27.1 SDK, iOS 27.0 simulator runtime, Swift 6.4, macOS 27 on Apple silicon.
  The first `xcrun simctl` call ran Xcode's one-time simulator component install.
- Two UWB-capable test iPhones (different UWB chip generations) are available for Phase 3.
- On-device builds need a signing team in Xcode (Settings ▸ Accounts).
- SDK checks (iOS 27.1):
  - CryptoKit `SecureEnclave` offers P256 (Signing, KeyAgreement), and from iOS 26 MLDSA65/87 and MLKEM768/1024. There is no Curve25519 or Ed25519, so the PRD's "Ed25519 in the Secure Enclave" can't be built (DESIGN §2, D1).
  - NearbyInteraction `NIDeviceCapability` flags: precise distance, direction, camera assistance, extended distance (iOS 17), DL-TDOA (iOS 26) and Bluetooth Channel Sounding (iOS 27, accessory configuration only).
- SQLCipher: the official SPM package `sqlcipher/SQLCipher.swift` 4.19.0 (2026-09-08) is a binary target, `SQLCipher.xcframework.zip` (50.5 MB), with its checksum pinned in the upstream manifest.

## 2026-10-24 — Decisions
- D1: P-256 ECDSA in the Secure Enclave. D2: offline cash (issuer-minted balances; double-spends made hard, provable, capped). D3: core engine first, on the Simulator.
- Approved: fetching SQLCipher through SPM (`sqlcipher/SQLCipher.swift` 4.19.0).

## 2026-10-24 — Phase 1 core engine, Phase 2 approvals

- SPM fetched `SQLCipher.swift` 4.19.0 (repo clone plus the 50.5 MB xcframework, a dynamic framework with iOS, Simulator and macOS slices). The first `swift package resolve` ended with a bare `error: fatalError` after the download; a rerun succeeded with nothing changed.
- `SecureKit` package with three modules. Choices made while building, recorded in DESIGN §5–6:
  - Chain links hash only public data (sequence, direction, transfer ID), so counterparties can recompute links and check double-spend evidence; categories stay private.
  - Receipts are stored outside the chain.
  - One Face ID approval per side per transfer (signing session ≤ 60 s).
  - Secure Enclave key uses `.biometryAny`.
  - Budgets store `anchor` / `start_date` columns instead of `anchor_date`; times are `created_at_ms` integers; all tables are `STRICT`.
- Tests: 69 (52 SecureCore + 17 SecureStore), all passing with `swift test` on macOS and `xcodebuild test` on the iPhone 18 Pro Simulator (iOS 27.0). The first Simulator run failed with "test runner timed out while preparing" on a cold boot; the rerun passed.
  - Covered: encrypted file header, wrong or missing key, append-only triggers, rollback lock, missing anchor, reinstall with old key, interrupted commit repair, idempotent redelivery, acceptance limits, proximity refusal, the PRD budget example.
  - Full restore + double-spend: undetectable on the cheater's own phone (documented limit); caught with signed evidence when the cheater pays the earlier shop again.
- App: hand-written `SECURE.xcodeproj` (objectVersion 77, synchronized `App/` folder, local package). Builds with no warnings for the Simulator and for a generic iOS device (unsigned, arm64, SQLCipher.framework embedded).
- Simulator walkthrough, Face ID driven with `notifyutil` BiometricKit match/nomatch events:
  - receive $500 → pay $150 → pay $30 (the "$180 of $200" alert notification fired) → $25 request notification on the lock screen with the PRD wording;
  - tapping it opened the approval sheet ("$180 → $205 of $200, over budget");
  - a non-matching face was refused and the payment waited; a matching face paid;
  - the "budget exceeded" alert fired;
  - relaunch reopened the encrypted ledger with the chain verified;
  - diagnostics showed SQLCipher 4.19.0 community, file encrypted, 5 entries.
- Not verified yet:
  - the Secure Enclave signer on a real phone (needs signing and Developer Mode);
  - the lock-screen Approve/Deny buttons, which synthetic gestures in the Simulator couldn't open (the categories are registered, and the tap → approval sheet path is verified);
  - UWB (Phase 3).
- Build output lives in `build/` (~830 MB) and `Packages/SecureKit/.build` (~260 MB). Both are git-ignored and safe to delete.

## 2026-10-24 — Features and architecture docs

- Added `docs/FEATURES.md`: 96 features across 9 areas with status (Done / Done · device check / Partial / Planned), evidence and code links, plus PRD coverage, a phase plan and known limitations. Summary counts were recounted from the tables.
- Added `docs/ARCHITECTURE.md` (~1,060 lines): stack and toolchain, module and file map, startup and concurrency, cryptography (primitives, key inventory, Secure Enclave lifecycle, signatures, domain tags, byte layouts), encryption at rest (SQLCipher, Data Protection, Keychain, backups), schema, chain and anchor states, protocol, double-spend evidence, budgets, notifications, data map, build and tests, planned NearbyInteraction/CoreBluetooth design.
- Facts measured for the docs with throwaway tests (deleted afterwards):
  - SQLCipher PRAGMAs: 4.19.0 community, `commoncrypto` provider, 4096-byte pages, HMAC_SHA512, PBKDF2_HMAC_SHA512 with kdf_iter 256000 (unused with the raw key), fast_kdf_iter 2, plaintext header 0, memory security 0, SQLite 3.53.4, compile options THREADSAFE=1 / TEMP_STORE=2. A random 16-byte salt opens the file and no plaintext was found in it.
  - Canonical message sizes: key 38, measurement 122–125, proof 389, transfer 204 (signed 276), receipt 119 (signed 191), claims 281/196, fork evidence 570, anchor 73.
  - A transfer's ID equals the SHA-256 digest that its ECDSA signature covers.
- Link check: every relative link and anchor in both docs resolves.

## 2026-10-24 — Additional features (simulated)

- Added credit-score access tiers, connected bank accounts, practice markets (stocks and ETFs, prediction markets, sports), a strategy guide with calculators, and responsible-play controls. Choices: fully simulated, all three market types, self-reported or demo score.
- Rule: the add-ons don't change the core transactions model. A first version put a transaction-count limit in the budget engine and a credit profile in `WalletStore`; it was reverted exactly (line counts checked, the original 69 tests passing) and rebuilt as a separate `SecureConnect` module plus a `ConnectedStore` with its own SQLCipher file and Keychain key. The credit tier limits practice-market activity only; `walletTransfersIgnoreTheCreditScore` checks that a $150 wallet payment goes through at the lowest tier.
- Deterministic simulators (FNV-1a seeds, SplitMix64, Box–Muller): GBM stock prices with 252 days of history and a 0.05 % half-spread; prediction events quoted at mid ±1¢; an Elo-style league with 60 points of home advantage and a 4.5 % margin; 60 days of bank history.
- Tests: 54 new (42 SecureConnect, 12 ConnectedStore); 123 in total, all passing with `swift test`. App builds with no warnings.
- Fixed during the Simulator walkthrough:
  - net worth was wrong when a card balance was positive (it is now the sum of all balances);
  - banners didn't appear on screens opened after another tab, because a cancelled `try? Task.sleep` let the timer clear the banner at once (now `do { try await Task.sleep(...) } catch { return }`);
  - the Good tier's yellow text had low contrast (now a darker gold);
  - price charts had padded x-axes (`chartXScale`).
- Known, not fixed: the wallet's own banner in `HomeView.swift` uses the same `try? Task.sleep` pattern, so it can disappear early if its screen is hidden. Left alone to keep wallet code unchanged by the add-ons.
- Simulator walkthrough: Wallet tab unchanged; Profile locked until a score is set, then the Sam persona (700, Good) and age 21+; fictional banks linked with the dashboard and spending chart; a stock bought, the market day advanced, a $512.50 order refused by the Good tier's $500 limit; a prediction event with its probability chart and EV slider; the sports bet slip with implied and fair odds and the margin.

## 2026-10-24 — Public repository preparation

- Personal details removed: the bundle identifier and Keychain service are now the placeholder `com.example.secure` (README explains how to set your own), and personal hardware details were replaced with generic requirements.
- Scanned for secrets before the first commit: no keys, tokens, passwords, signing files, email addresses or device identifiers. Build output (`build/`, `.build/`), user data and `*.sqlite` stay git-ignored.
- After the rename: 123 tests pass on macOS and on the iPhone 18 Pro Simulator; the app builds.
- Added `docs/ADDITIONAL-FEATURES.md`, `docs/STRATEGIES.md` (generated from `StrategyCatalog` by a throwaway test, so it matches the app word for word), the MIT `LICENSE`, and updated README, DESIGN, FEATURES, ARCHITECTURE and PHASES for the add-ons.

## 2026-10-25 — Sports switched off; phone-to-phone payments

- **Sports betting switched off for now** (user request). `AppFeatures.sportsBetting = false` hides the Sports segment, the six sports strategies and the bet history; `ConnectedStore(enabledMarkets:)` refuses bets with `.marketClosed`. The engine and its tests stay; new test `aSwitchedOffMarketRefusesOrders`.
- **Phone-to-phone payments** (user decisions: MultipeerConnectivity as the link; the first milestone is a full payment, not a distance-only spike).
  - New package module `SecurePeer`: `PeerMessage` (versioned canonical encoding), `PeerConnection` (payer and payee steps, mailbox with timeouts, one payment per link, offer withdrawal, re-delivery), `PeerRanger`, `PeerText`. It uses only `WalletStore`'s public steps; no wallet code changed.
  - Safety rules added while building: the payee's `ready` repeats the agreed amount, and the payer won't commit if it differs; the payee checks that the transfer's proof and amount match the offer before accepting; if the payer stops waiting, it withdraws the offer so the payee's prompt closes.
  - App: `MultipeerLink` (auto-connects to nearby phones while the Nearby screen is open; tie-break on a random instance ID so only one side invites), `NearbyRanger` (one `NISession` per phone, tokens in the `hello`, live distance, ≥10 fresh samples or 3 over 1.5 s per payment), `NearbyModel`, `NearbyView` (phones with wallet code and live distance, pay sheet with budget check, incoming-offer sheet, progress card, "Waiting for confirmation" with Retry). `Config/Info.plist` adds the NearbyInteraction, local-network and Bonjour keys. Wallet tab gets a *Pay or get paid nearby* row; `AppModel` exposes the wallet and signer to it and names peers from the `hello`.
  - Tests: 13 in `SecurePeerTests` (all passing 20 times in a row), 137 in total, passing on macOS and the iPhone 18 Pro Simulator. The app builds with no warnings for the Simulator and for a generic iOS device.
- Two-Simulator walkthrough (iPhone 18 Pro and iPhone 18 Pro Max):
  - **MultipeerConnectivity can't connect two Simulators on one Mac.** Each found the other, but invitations timed out (the listener logged `Failed to set SO_NOSIGPIPE` on the accepted socket). Added `LoopbackLink`, a Simulator-only loopback TCP link with the same interface; it is compiled out of device builds.
  - **The Simulator emulates NearbyInteraction** (`supportsPreciseDistanceMeasurement` is true, distance 0 m). Its readings were first treated as real UWB, which a release build would have accepted; they are now flagged `.simulated`, so the real ranger code runs in the Simulator but only debug builds accept the result.
  - Result: both phones listed each other with matching wallet codes and live (simulated) distance; $25 sent from the first to the second; the payee saw the offer, both approved with Face ID (`notifyutil` match events); the payer's entry shows *Receipt: Countersigned* and a spatial proof with 10 samples per side; balances $295 and $25, both chains verified.
- Not verified yet: Multipeer and UWB on two real iPhones, and the distance thresholds against a tape measure.

## 2026-10-25 — Payment requests from the payee

- New `request` message (payee → payer): amount and an optional note of up to 60 characters. The payer's phone shows it with a category picker and the live budget check; **Pay with Face ID** runs the normal payment, with the offer reusing the request's ID. **Decline** sends a `failure`.
- The payee's phone accepts the answering offer without a second prompt **only** if it matches its own outstanding request (same ID, exact amount). It still approves with Face ID, because it signs its distance reading and the receipt. An offer for a different amount gets the normal "Accept?" prompt.
- A request times out after 90 s and is withdrawn, so the payer's prompt closes. One payment or request at a time per link. A budget or balance stop on the payer's side reaches the requester as a plain-language reason.
- Engine: `PeerConnection.request(amount:note:)`, a `decideRequest` callback, `paid` / `payFailed` events; the decision prompts are now generic, with a fallback answer on timeout or withdrawal. App: a Pay / Request switch on the send sheet and an incoming-request sheet.
- Tests: 7 new (approve, decline, payer's budget stops it, approved over budget, a changed amount is not pre-approved, withdrawn request, one at a time) plus encoding checks; 20 phone-to-phone tests passed 20 times in a row; 144 in total.
- Two-Simulator walkthrough: the second phone requested $10 "Coffee"; the first saw the request, picked Clothing (budget check "Near the limit, $180 → $190 of $200") and paid with Face ID; the requester approved with Face ID without an extra prompt. Balances went $295 → $285 and $25 → $35, and Clothing shows $190 of $200.

