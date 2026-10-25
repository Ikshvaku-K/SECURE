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

