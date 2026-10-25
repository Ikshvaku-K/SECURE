# S.E.C.U.R.E: Features

As of 2026-10-25. Phase 1 (core engine) is complete. Phase 2 (approvals) is implemented and needs its first run on a real iPhone. Phone-to-phone payments (Phases 3–4) are implemented and verified on two Simulators; their first run on two iPhones is pending. Phases 5–7 are planned.
Companion documents: [ARCHITECTURE.md](ARCHITECTURE.md) (how it works), [DESIGN.md](DESIGN.md) (PRD review and decisions), [PRD.md](PRD.md) (original requirements), [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md) and [STRATEGIES.md](STRATEGIES.md) (credit tiers, accounts, practice markets, strategies), [../PHASES.md](../PHASES.md) (plan).

**Status labels**

| Label | Meaning |
|---|---|
| **Done** | Built, covered by automated tests or the Simulator walkthrough, or both |
| **Done · device check** | Built and compiles for iPhone; behaviour only provable on real hardware (Secure Enclave, Data Protection), not yet run on a phone |
| **Partial** | Engine or API exists; a piece (usually UI) is missing |
| **Planned · Pn** | Scheduled for phase *n* in [PHASES.md](../PHASES.md) |

## At a glance

| Area | Done | Done · device check | Partial | Planned |
|---|---|---|---|---|
| 1. Wallet identity and keys | 7 | 2 | 0 | 2 |
| 2. Encrypted storage | 6 | 2 | 0 | 0 |
| 3. Ledger and tamper evidence | 9 | 0 | 1 | 0 |
| 4. Budgets | 9 | 0 | 3 | 0 |
| 5. Transfers and proximity | 14 | 4 | 0 | 1 |
| 6. Double-spend detection | 5 | 0 | 0 | 1 |
| 7. Approvals and notifications | 8 | 0 | 1 | 1 |
| 8. App screens | 10 | 0 | 2 | 0 |
| 9. Developer tooling and quality | 8 | 0 | 0 | 2 |
| 10. Additional features (simulated) | 12 | 0 | 0 | 0 |

---

## 1. Wallet identity and keys

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 1.1 | Hardware wallet key | A P-256 key pair is generated inside the Secure Enclave. The private key never leaves the chip; the app stores only an encrypted blob that this phone's Secure Enclave alone can use. | Done · device check | `SecureEnclaveSigner` in [Signers.swift](../Packages/SecureKit/Sources/SecureDevice/Signers.swift); iPhone build compiles |
| 1.2 | Face ID on every signature, enforced by hardware | The key's access control is `.privateKeyUsage + .biometryAny`, so the Secure Enclave won't sign without a fresh Face ID match. App code can't skip it and there is no passcode fallback. | Done · device check | Same file, `makeAccessControl()` |
| 1.3 | One approval per transfer | One Face ID match opens a signing session of at most 60 seconds, which signs that side's distance measurement and its transfer or receipt. The user sees one prompt per payment, not three. | Done | Simulator walkthrough; `SecureEnclaveSession.lifetime = 60` |
| 1.4 | Enrollment-safe key policy | Uses `.biometryAny` rather than `.biometryCurrentSet`, so adding a face to Face ID doesn't destroy the key and with it a balance that can't leave the phone. | Done | [DESIGN §3.1](DESIGN.md#31-what-it-protects-against) |
| 1.5 | No software fallback on phones | On a real device, a missing Secure Enclave means no wallet. Software keys exist only in Simulator and test builds. | Done | `WalletSigners.loadOrCreate` |
| 1.6 | Simulator signer, clearly labelled | On the Simulator (which has no Secure Enclave), a software P-256 key is unlocked by an app-level Face ID check. The Security screen says so explicitly. | Done | Simulator: Diagnostics shows "Simulator: software key + Face ID check" |
| 1.7 | Wallet fingerprint | The first 8 bytes of SHA-256 over the public key, shown as four hex groups (e.g. `5e66-4609-9d06-7594`) for comparing identities by eye. | Done | `WalletPublicKey.fingerprint` |
| 1.8 | Fresh identity on reinstall | If the database is gone (app deleted), the app deletes the old key, anchor and database key and starts a new identity. Reusing an old key from sequence 0 would look like a double-spend to every former peer. | Done | `WalletBootstrap.open`; test `aReinstallMustNotReuseTheOldKey` proves the reuse would be caught |
| 1.9 | Algorithm agility | Every public key and payload carries an algorithm byte (1 = P-256 ECDSA), so post-quantum ML-DSA can be added without a format break. | Done (P-256 only) | `SignatureAlgorithm` in [Keys.swift](../Packages/SecureKit/Sources/SecureCore/Keys.swift) |
| 1.10 | Two-key identity (identity key endorses a spending key) | Lets Face ID-bound spending keys be replaced after biometric changes without losing the wallet identity. | Planned · P6 | [DESIGN §3.1](DESIGN.md#31-what-it-protects-against) |
| 1.11 | ML-DSA-65 post-quantum signatures in the Secure Enclave | Optional second algorithm (iOS 26+). | Planned (optional) | D1 alternative in [DESIGN §9](DESIGN.md#9-decisions) |

## 2. Encrypted storage

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 2.1 | SQLCipher-encrypted database | Every 4,096-byte database page is encrypted with AES-256 and authenticated with HMAC-SHA512, using SQLCipher 4.19.0 on Apple's CommonCrypto. Schema, indexes and data are all encrypted; there is no plaintext header. | Done | Test `databaseFileIsEncrypted`; a PRAGMA probe found no plaintext in the file |
| 2.2 | Random 256-bit database key | Generated with CryptoKit and used as a raw key (no password, no KDF). Stored in the Keychain, readable only while the phone is unlocked and never migrated to another device. | Done | `WalletStore.init`; [KeychainSecretStore.swift](../Packages/SecureKit/Sources/SecureDevice/KeychainSecretStore.swift) |
| 2.3 | Data Protection "Complete" | The wallet folder and database file use iOS file protection class Complete: the OS keeps them encrypted and unreadable while the phone is locked. | Done · device check | `WalletLocation` in [ChainAnchor.swift](../Packages/SecureKit/Sources/SecureStore/ChainAnchor.swift) (no effect on the Simulator) |
| 2.4 | Excluded from backups | Folder and file are excluded from iCloud and computer backups, so restoring a backup can't bring back spent balances. | Done · device check | Same |
| 2.5 | Wrong or missing key handling | A wrong key fails when the database opens, not later. A missing key is reported (`databaseKeyMissing`) and never silently replaced with a new one. | Done | Tests `wrongKeyCannotOpenTheDatabase`, `missingKeyIsReportedNotReplaced` |
| 2.6 | Refuses unencrypted SQLite | On open the store checks `PRAGMA cipher_version`. If plain SQLite were linked by mistake, the wallet refuses to open rather than store data unencrypted. | Done | [SQLiteDatabase.swift](../Packages/SecureKit/Sources/SecureStore/SQLiteDatabase.swift) |
| 2.7 | Type-safe schema | All tables are `STRICT` (SQLite enforces column types, so money can't become floating point), foreign keys are on, and CHECK constraints guard periods, percentages and amounts. | Done | [Schema.swift](../Packages/SecureKit/Sources/SecureStore/Schema.swift); test `ledgerIsAppendOnlyInTheDatabaseItself` (rejects an invalid budget) |
| 2.8 | Temporary data stays in memory | The SQLCipher build keeps temporary tables and indexes in memory (`TEMP_STORE=2`) rather than spilling them to disk. | Done | PRAGMA probe (compile options) |

## 3. Ledger and tamper evidence

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 3.1 | Append-only hash chain | Every committed event (genesis, mint, debit, credit) is one ledger row linked to the previous one by SHA-256. The first link commits to the wallet's public key. | Done | [ChainTests.swift](../Packages/SecureKit/Tests/SecureCoreTests/ChainTests.swift) (10 tests) |
| 3.2 | Append-only enforced by the database | SQLite triggers reject any `UPDATE` or `DELETE` on the ledger and any insert that doesn't extend the sequence by exactly one. | Done | Test `ledgerIsAppendOnlyInTheDatabaseItself` |
| 3.3 | Full verification on every open | Recomputes every link and checks every transfer signature, every debit's claimed position, amounts, proof hashes and running balances. | Done | `ChainVerifier.verify` |
| 3.4 | Keychain anchor and rollback lock | The chain tip (sequence + link) is also kept in the Keychain. A database older than the anchor, a history that contradicts it, or a missing anchor locks the wallet. | Done | Tests `restoringAnOlderDatabaseLocksTheWallet`, `aMissingAnchorLocksAWalletWithHistory` |
| 3.5 | Crash-safe anchor repair | If the app stops between the database commit and the Keychain write, the next open finds the database one step ahead, verifies it and moves the anchor forward. | Done | Test `anInterruptedCommitIsRepaired` |
| 3.6 | Read-only locked mode | A locked wallet still shows its data but refuses every payment, receipt and commit. The home screen shows "Locked: integrity check failed". | Done | `ensureUnlocked()`; home badge |
| 3.7 | Re-verify on demand | The Security screen re-runs full verification and the anchor comparison. | Done | `WalletStore.reverify()` |
| 3.8 | Integer money, multiple currencies | Amounts are `Int64` minor units with an ISO currency code and overflow-checked arithmetic. Zero-decimal currencies (JPY, KRW …) are handled. Each currency has its own balance. | Done | [Money.swift](../Packages/SecureKit/Sources/SecureCore/Money.swift); 6 money tests (17 cases) |
| 3.9 | Balance computed from the ledger | No stored balance to tamper with: credits plus mints minus debits, recomputed on open. | Done | `ChainSummary` |
| 3.10 | Clock-regression flag | Detects when the device clock is earlier than the previous entry's time. | Partial (detected, not yet shown in UI) | `WalletStore.clockWentBackwards` |

## 4. Budgets

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 4.1 | Categories | Food, Clothing and Transport (with SF Symbols icons) on first launch; add new ones from the budget editor. | Done | `AppModel.seedIfNeeded` |
| 4.2 | Archiving categories | Categories already used in the ledger can't be deleted (the ledger is append-only), only archived. | Partial (API only, no UI) | `setCategoryArchived` |
| 4.3 | Multiple budgets per category | e.g. a weekly and a monthly cap on Food. | Done | Schema allows it; engine checks all |
| 4.4 | Four period types | **Monthly** from an anchor day (clamped: day 31 becomes 30 or 28/29), **weekly** from a chosen weekday, **rolling** last *N* days, **custom** repeating blocks of *N* days from a start date. | Done | [BudgetTests.swift](../Packages/SecureKit/Tests/SecureCoreTests/BudgetTests.swift), including a daylight-saving week of 169 h |
| 4.5 | Soft caps with explicit override | Going over a cap shows an over-budget warning. Paying anyway takes a deliberate "Pay anyway" plus Face ID. | Done | Simulator walkthrough ($180 → $205 of $200) |
| 4.6 | Hard caps | Optional per budget: blocks instead of warning. | Done | Test `hardCapsAndBalanceBlockBeforeAnyApproval` |
| 4.7 | Alert threshold | Default 80 % of the cap, adjustable from 50 to 100 % in 5 % steps. | Done | Simulator: "$180.00 spent of $200.00 limit" |
| 4.8 | Live budget preview | While typing an amount, the pay sheet shows each affected budget as before → after against the cap, coloured green, orange or red. | Done | Simulator |
| 4.9 | Race-free enforcement | Budgets are checked before the Face ID prompt and again inside the database write transaction, so two simultaneous payments can't both slip under a cap. | Done | `commitDebit` |
| 4.10 | Category privacy | The category is stored only in your own ledger. It isn't in the signed transfer and isn't part of the chain hash, so payees never learn it. | Done | Tests `transferCarriesNoCategory`, `budgetsFollowThePRDExample` |
| 4.11 | Own spending limits (per transfer / per day) | Caps your own offline spending regardless of category. | Partial (engine and configuration; no settings UI) | `WalletConfiguration.spendingLimits` |
| 4.12 | Budget editing | Create budgets; delete with a swipe. | Partial (editing an existing budget isn't in the UI yet) | [BudgetEditorView.swift](../App/BudgetEditorView.swift) |

## 5. Transfers and proximity

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 5.1 | Offline cash model | Balances are spendable value minted by an issuer key. Wallets pin trusted issuer keys; incoming transfers from them are recorded as mints, others as credits. Issuers may go negative (outstanding issuance). | Done | Test `mintFromAPinnedIssuerCreditsTheMember` |
| 5.2 | Joint session nonce | Both phones contribute 16 random bytes, hashed together, so neither side can choose or precompute the session ID. | Done | `SessionNonce.derive` |
| 5.3 | Mutual spatial proof | Each phone signs its own distance measurement of the same session. A proof needs both signatures, so neither phone can fake it alone. | Done | [ProtocolTests.swift](../Packages/SecureKit/Tests/SecureCoreTests/ProtocolTests.swift) (8 proof tests) |
| 5.4 | Proximity policy | Accepts only if both measurements are ≤ 100 cm and agree within 25 cm or 20 %. Optional "direction required". Real-device policy rejects measurements flagged as simulated. | Done | Tests `rejectsPhonesTooFarApart`, `rejectsMeasurementsThatDisagree`, `realDevicesRejectSimulatedMeasurements` |
| 5.5 | Signed transfer | The payer signs payee, amount, session nonce, its own sequence number and previous chain link, the proof hash and a timestamp. The category is never included. | Done | `Transfer` in [Messages.swift](../Packages/SecureKit/Sources/SecureCore/Messages.swift) |
| 5.6 | Payee "Ready" check before the payer signs | The payee validates the proof, its limits and the payer's record first, so a valid transfer is never refused after the payer's debit. | Done | `preflightIncoming` |
| 5.7 | Debit before handover | The payer commits the debit before releasing the signed transfer, so the same funds can never be signed twice. | Done | `commitDebit` |
| 5.8 | Countersigned receipts | The payee signs "I recorded transfer T at position *n* of my chain"; the payer keeps it. | Done | Issuer receipt check in `mintFromAPinnedIssuerCreditsTheMember` |
| 5.9 | Idempotent re-delivery | Delivering the same signed transfer again returns the original entry and receipt; nothing is recorded twice. | Done | Test `redeliveryIsIdempotent` |
| 5.10 | Acceptance limit | Largest amount a wallet accepts from a peer in one offline transfer, capping exposure to a double-spender. | Done | Test `acceptanceLimitCapsExposure` |
| 5.11 | Refused before debit | Budget, balance, limit and proximity failures all happen before the payer's debit, leaving the payer's balance untouched. | Done | Tests assert unchanged balances |
| 5.12 | Simulated ranging | Stand-in for UWB on the Simulator and in tests: seeded noise, median and spread, always flagged `simulated`. | Done | `SimulatedRanging` |
| 5.13 | In-flight transfers | A payment whose receipt never arrived is listed under "Waiting for confirmation" and re-sent from the payer's ledger with Retry. The payee confirms with Face ID and countersigns; it is never credited twice. | Done | Tests `aTamperedTransferIsRefusedAndRedeliveredIntact`, `aLostReceiptIsRecoveredWithoutPayingTwice`; `PeerConnection.redeliver` |
| 5.14 | UWB ranging (NearbyInteraction) | One `NISession` per nearby phone; discovery tokens travel in the link's `hello`. Live distance on screen; each payment summarises fresh samples (median, spread, direction when available) and signs them into the proof. | Done · device check | [NearbyRanger.swift](../App/Peer/NearbyRanger.swift); runs on the Simulator's NearbyInteraction emulation, flagged simulated |
| 5.15 | Peer link (MultipeerConnectivity) | Finds nearby phones running the app over Bluetooth and peer-to-peer Wi-Fi, with no internet, and keeps an encrypted session with each. Untrusted: every payment message is signed. Two Simulators use a loopback stand-in. | Done · device check | [MultipeerLink.swift](../App/Peer/MultipeerLink.swift), [LoopbackLink.swift](../App/Peer/LoopbackLink.swift) |
| 5.16 | Phone-to-phone transfers | The DESIGN §6 steps with each side on its own phone: offer, payee decision and Face ID, joint nonce, both measure and sign, payee "ready" for the exact amount, payer commits, transfer, countersigned receipt. | Done · device check | 13 tests in `SecurePeerTests`; two-Simulator walkthrough ($25, receipt countersigned); [PeerConnection.swift](../Packages/SecureKit/Sources/SecurePeer/PeerConnection.swift) |
| 5.17 | Issuer mode in the app | One phone acts as the issuer and mints to others in person. | Planned · P4 | Demo Issuer covers it in-process today |
| 5.18 | Nearby screen | Lists nearby phones with name, wallet code and live distance; pay sheet with budget check; incoming-offer sheet with Accept / Decline; step-by-step progress. | Done | [NearbyView.swift](../App/Peer/NearbyView.swift); Simulator walkthrough |
| 5.19 | Payment requests | The payee asks a nearby phone for an amount, with an optional note. The payer sees the request with a category picker and live budget check, then pays with Face ID or declines. The payee's phone accepts the answering payment without asking again, only for exactly the requested amount, and still signs with Face ID. | Done · device check | 7 tests in `PaymentRequestTests`; two-Simulator walkthrough ($10 "Coffee" charged to Clothing) |

## 6. Double-spend detection

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 6.1 | Peer chain tracking | For every counterparty, the wallet keeps the most recent signed claim about that peer's chain: its transfer (as payer) or its receipt (as payee). | Done | `peers` table; `advancePeer` |
| 6.2 | Continuity verdicts | Each incoming transfer or receipt is classified as first contact, contiguous, gap, out-of-order, duplicate or **fork**. | Done | `Continuity.check`; 5 continuity tests |
| 6.3 | Fork evidence | Two signed claims by the same wallet that can't both belong to one honest chain. Anyone can verify them with no trusted party. | Done | `ForkEvidence.isValid` |
| 6.4 | Cheaters refused afterwards | Once a wallet holds valid fork evidence against a peer, it refuses all further transfers from that peer. | Done | Test `aFullRestoreIsCaughtWhenTheCheaterMeetsAnEarlierPayee` |
| 6.5 | Evidence from receipts too | A payee who later spends at a sequence number it already used for a receipt is caught the same way. | Done | Test `receiptsExtendTheSameRecord` |
| 6.6 | Evidence exchange between wallets | Wallets swap fork evidence when they meet, so a cheater is flagged beyond the wallets it cheated directly. | Planned · P4 | — |

## 7. Approvals and notifications

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 7.1 | Face ID prompt with context | The prompt names the amount and counterparty, e.g. "Pay $25.00 to Demo Shop" or "Receive $500.00 from Demo Issuer". | Done | `LoopbackPayment.run` |
| 7.2 | Budget alerts | Local notification when a payment reaches a budget's alert threshold ("Clothing budget alert: $180.00 spent of $200.00 limit.") and when it exceeds the cap ("Clothing budget exceeded"). | Done | Simulator walkthrough |
| 7.3 | Alerts once per window | Each alert level fires at most once per budget per period. | Done | `postedBudgetAlerts` keys and notification identifiers |
| 7.4 | Payment-request notifications | PRD wording ("Clothing: $180.00 spent of $200.00 limit. Approve $25.00 transaction?") with **Approve** (opens the app, requires unlock) and **Deny** (handled in the background). | Done (buttons registered; the Simulator couldn't open them with synthetic gestures) | `NotificationService`; Simulator walkthrough (lock screen) |
| 7.5 | Tap-to-approve sheet | Tapping the notification itself opens an approval sheet with the budget check, then Face ID. | Done | Simulator walkthrough |
| 7.6 | Failed Face ID blocks payment | A non-matching face is refused and the payment waits; nothing is signed or debited. | Done | Simulator walkthrough (`pearl.nomatch`) |
| 7.7 | Notifications while the app is open | Banners show in the foreground too. | Done | Simulator |
| 7.8 | No lost taps on cold launch | A notification tap that launches the app is queued until the wallet has opened. | Done | `NotificationService.pendingActions` |
| 7.9 | Time-sensitive requests | Requests are marked `.timeSensitive` so they can break through Focus. | Partial (needs the Time Sensitive Notifications capability added to the app) | — |
| 7.10 | Requests from a backgrounded phone over Bluetooth | A Bluetooth request wakes the app and posts the notification. | Planned · P4 | [DESIGN §8](DESIGN.md#8-approvals) |

## 8. App screens

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 8.1 | Home | Balance with animated digits, integrity badge, wallet fingerprint, actions, budgets and activity. Pull to refresh. | Done | [HomeView.swift](../App/HomeView.swift) |
| 8.2 | Demo actions | "Pay Demo Shop", "Receive $500 from Demo Issuer", "Simulate a payment request" (arrives after 5 s so you can lock the phone). | Done | — |
| 8.3 | Budget list | Progress bar coloured by state, period label, hard-cap icon; swipe to delete. | Done | — |
| 8.4 | Activity list | Direction icon (sparkles for mints), counterparty, time, category and measured distance. | Done | — |
| 8.5 | Transfer detail | Amount, counterparty, private category, receipt status; both signed measurements with capability flags; proof hash, sequence, links, transfer ID and signature validity. | Done | [DetailViews.swift](../App/DetailViews.swift) |
| 8.6 | Pay sheet | Amount on the decimal pad (parsed with your locale), category picker, payee, proximity, live budget check, Face ID button, over-budget confirmation. | Done | [PayView.swift](../App/PayView.swift) |
| 8.7 | Budget editor | Category (existing or new), limit, period type and its parameters, alert %, hard cap. | Done | [BudgetEditorView.swift](../App/BudgetEditorView.swift) |
| 8.8 | Approval sheet | Request amount, category, proximity, budget check, Approve with Face ID, Deny. | Done | [ApprovalSheet.swift](../App/ApprovalSheet.swift) |
| 8.9 | Security screen | Signer type, wallet key, Face ID availability, SQLCipher version, file-encryption check (reads the file header), backup exclusion, integrity, entry count, tip link, re-verify, proximity policy. | Done | `DiagnosticsView` |
| 8.10 | Status banners | Success and error messages that dismiss themselves after 4 s. | Done | `BannerView` |
| 8.11 | Accessibility and appearance | System fonts (Dynamic Type), system colours (dark mode), a combined VoiceOver element for the balance, labelled icon buttons. | Partial (full VoiceOver and Dynamic Type audit in P5) | — |
| 8.12 | Proximity view, send/request to real people | Paying and requesting with a nearby person, with live distance, are done (5.18, 5.19). Still to come: a radar view with direction. | Partial | [NearbyView.swift](../App/Peer/NearbyView.swift) |

## 9. Developer tooling and quality

| # | Feature | What it does | Status | Evidence / code |
|---|---|---|---|---|
| 9.1 | 144 automated tests | Swift Testing: 52 core, 30 store (encryption, integrity, budgets, rollback, double-spend, connected store), 20 phone-to-phone (payments, requests, messages) and 42 for the simulated add-ons. | Done | `swift test` (macOS) and `xcodebuild test` (iOS Simulator) both pass |
| 9.2 | Runs on Mac and Simulator | The same suites run on macOS (fast) and on the iOS Simulator (real iOS SQLCipher binary). | Done | [README](../README.md) commands |
| 9.3 | Attack simulations in tests | Tests copy and restore the database file and the "Keychain" to stage rollbacks, reinstalls, crashes and a full-restore double-spend. | Done | [StoreTestSupport.swift](../Packages/SecureKit/Tests/SecureStoreTests/StoreTestSupport.swift) |
| 9.4 | Pinned dependency | The only third-party code is SQLCipher, pinned to exactly 4.19.0. The binary's checksum is pinned in its manifest and `Package.resolved` is kept. | Done | [Package.swift](../Packages/SecureKit/Package.swift) |
| 9.5 | Swift 6 strict concurrency | Data-race safety checked by the compiler. Storage is isolated in an actor and the UI on the main actor. | Done | Builds with no warnings |
| 9.6 | Hand-written Xcode project | Xcode 16+ format with a synchronized `App/` folder: new files are picked up automatically and there's no generator tool to install. | Done | [project.pbxproj](../SECURE.xcodeproj/project.pbxproj) |
| 9.7 | Scriptable Face ID on the Simulator | Enroll and match/no-match faces from the command line for repeatable walkthroughs. | Done | [ARCHITECTURE §12.4](ARCHITECTURE.md#124-simulator-face-id-automation) |
| 9.8 | Living documentation | PRD, design review, architecture, features, phase plan and work log kept with the code. | Done | `docs/`, `PHASES.md`, `WORKLOG.md` |
| 9.9 | Tamper and fuzz hardening suite | Oversized and forged payloads, replay and timing tests with measured numbers. | Planned · P6 | — |
| 9.10 | TestFlight distribution | Needs the paid Apple Developer Program. | Planned · P7 | — |

---

## 10. Additional features (simulated)

Added after the PRD. They run beside the wallet in their own module (`SecureConnect`) and their own encrypted database (`connected.sqlite`), and **don't change the core transactions model**: the credit tier limits practice-market activity only, never wallet transfers. Full design: [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md).

| # | Feature | What it does | Status | Evidence and code |
|---|---|---|---|---|
| 10.1 | Credit score and tiers | Self-reported score (300–850) or one of five demo personas; five FICO-style tiers set practice transactions per day (3 to 50) and the largest single transaction ($100 to $2,500) | Done | `CreditTierTests`, `creditScoreSetsTransactionAccess`; [CreditTier.swift](../Packages/SecureKit/Sources/SecureConnect/CreditTier.swift) |
| 10.2 | Wallet isolation | Wallet transfers never consult the credit score | Done | `walletTransfersIgnoreTheCreditScore` |
| 10.3 | Connected accounts | Link three fictional banks, import 60 days of history, idempotent sync, unlink | Done | `linkingImportsHistoryAndSyncIsIdempotent`, `unlinkingRemovesAccountsAndTheirTransactions`; [Banking.swift](../Packages/SecureKit/Sources/SecureConnect/Banking.swift) |
| 10.4 | Central dashboard | Net worth, assets, liabilities, spending by category this month, per-account detail | Done | `netWorthAddsUpEveryAccount`; Simulator walkthrough; [AccountsView.swift](../App/Connected/AccountsView.swift) |
| 10.5 | Account alerts | Local notifications for debits of $500 or more and checking balances under $200 | Done | `largeTransactionsRaiseAlerts` |
| 10.6 | Practice stocks and ETFs | Eight fictional instruments, a year of simulated prices, spread, charts, buy and sell | Done | `equityOrdersMoveCashAndPositions`, `SimulatorTests`; Simulator walkthrough |
| 10.7 | Practice prediction markets | YES/NO contracts, probability chart, expected-value slider, settlement at 100¢ / 0¢ | Done | `contractsSettleOnTheirCloseDay`; Simulator walkthrough |
| 10.8 | Practice sports betting | Fictional league, moneyline odds with a 4.5 % margin, bet slip explaining implied and fair odds, settlement | Done · switched off for now (`AppFeatures.sportsBetting`) | `betsSettleAfterTheGame`; Simulator walkthrough (bet slip) |
| 10.9 | Order checks | Self-exclusion, cool-off, score, age, tier count, tier size, daily stake limit, cash, in that order | Done | `MathAndPlayTests`; [ResponsiblePlay.swift](../Packages/SecureKit/Sources/SecureConnect/ResponsiblePlay.swift) |
| 10.10 | Responsible play | Age confirmation, daily stake limit, 24-hour and 7-day cool-offs, 30-day self-exclusion that can't be shortened | Done | `coolOffBlocksBuyingButAllowsSellingAndCantBeShortened`, `exclusionsCanBeExtendedButNotShortened` |
| 10.11 | Strategy guide | 27 strategies in four groups with how it works, example, when used, risks, complexity and availability | Done | `everyStrategyIsComplete`; [STRATEGIES.md](STRATEGIES.md) |
| 10.12 | Calculators | Expected value, Kelly bet size, DCA backtest, Martingale simulator | Done | `kellyFractions`, `dollarCostAveragingBuysMoreOnDips`, `martingaleUsuallyEndsInRuinAndIsReproducible`; [LearnView.swift](../App/Connected/LearnView.swift) |

## PRD coverage

Each requirement from [PRD.md](PRD.md), what was built and how it differs. Reasons for each change are in [DESIGN §2](DESIGN.md#2-prd-corrections).

| PRD requirement | Built as | Status |
|---|---|---|
| Ed25519 key pairs stored in the Secure Enclave | P-256 ECDSA in the Secure Enclave (the Secure Enclave has no Ed25519) | Done · device check (changed by decision D1) |
| SQLCipher with AES-256-GCM | SQLCipher 4.19.0: AES-256 pages with HMAC-SHA512 (authenticated, not GCM), plus iOS Data Protection | Done (wording corrected) |
| State-locking: hash chain / hardware counter against rollback | Hash chain, Keychain anchor, rollback lock and fork evidence. A complete restore can't be stopped offline, only caught and limited. | Done (limit documented) |
| UWB peer ranging with NearbyInteraction and CoreBluetooth | NearbyInteraction ranging plus a MultipeerConnectivity link (Bluetooth and peer-to-peer Wi-Fi) instead of raw CoreBluetooth | Done · device check (transport changed, DESIGN §12) |
| Spatial vector proof (azimuth, distance, sender, recipient, nonce, timestamp) | Mutual signed measurements: distance (median and spread), optional azimuth and vertical estimate, both keys, joint nonce, capability flags; the timestamp is on the signed transfer | Done (simulated input) |
| Categories with monthly or rolling caps | Monthly, weekly, rolling and custom periods; soft and hard caps; multiple per category | Done |
| Check balance and budget before signing | Before the Face ID prompt, and again inside the write transaction | Done |
| Atomically decrement caps and balance | Caps never change; spending and balance are computed from the ledger and the append is one atomic transaction | Done (approach changed) |
| Local budget alerts ("$180 spent of $200 … Approve $25?") | Budget alerts and request notifications with the PRD wording | Done |
| Approve/Deny on the lock screen | Registered actions plus a tap-to-approve sheet | Done (lock-screen buttons unverified on Simulator) |
| Face ID / Touch ID via LAContext before signing | Enforced by the Secure Enclave key itself; `LAContext` only provides the prompt and session | Done · device check (strengthened) |
| Schema: Categories, Budgets, Transactions | Schema v2: integer money, per-sender nonces, append-only chain, receipts, peers, pending transfers | Done |
| Flow: initiate → budget → spatial → alert/Face ID → sign → mutate | Same steps; Face ID comes before ranging so one approval covers every signature | Done |

## Planned features by phase

| Phase | Features |
|---|---|
| **P3: Proximity spike** | Bluetooth link for discovery tokens; NearbyInteraction ranging between two UWB iPhones; a capability report (direction, camera assistance, extended range); tape-measure accuracy runs that set the real proof thresholds |
| **P4: Transfer protocol on two phones** | Phone-to-phone transfers and receipts; in-flight handling; Bluetooth background wake-up for requests; issuer mode; fork-evidence exchange |
| **P5: App UI** | Proximity view, choosing real counterparties, budget editing, settings for limits, VoiceOver and Dynamic Type audit |
| **P6: Hardening and evaluation** | Tamper and fuzz suite, measured threat model, performance (Secure Enclave signing, time to proof, commit time), two-key identity scheme |
| **P7: Distribution** | TestFlight, a legal check if tokens represent real money |

## Known limitations

- **Offline double-spending can't be prevented, only made hard, provable and limited.** A complete restore of an old app state (database and Keychain together) is undetectable on the cheater's own phone. It is caught when the cheater meets a wallet holding a later claim. See [ARCHITECTURE §7.6](ARCHITECTURE.md#76-double-spend-evidence).
- **A lost phone means a lost balance.** Keys can't leave the Secure Enclave and there is no server to restore from (decision D2).
- **A payee can't verify the payer's balance offline.** It trusts the payer's signed chain position and caps its exposure with acceptance limits.
- **The spatial proof only shows that both phones agreed they were close**, not where they were. Two colluding phones can both lie.
- **Real UWB only on iPhones.** Phone-to-phone payments measure real distance with NearbyInteraction. The Simulator's readings and the Demo Shop flow are flagged simulated: debug builds accept them, release builds don't.
- **Both people keep the Nearby screen open.** Phone-to-phone UWB ranging only runs in the foreground, and the link only runs while that screen is visible.
- **Names on the Nearby screen are self-chosen.** Compare the wallet code (fingerprint) with the other person before paying.
- **The UWB reading isn't yet bound to the wallet key.** A phone measures the device holding the discovery token it was given; an honest payee far away still can't complete a payment, but two colluding phones can (see the spatial-proof limit above).
- **Budget windows use the phone's clock**, which the owner can change. Ordering and integrity use sequence numbers, not time.
- **Demo payment requests are held in memory** and lost if the app is terminated. Unconfirmed phone-to-phone payments are safe: they are rebuilt from the ledger and re-sent with Retry.
- **Notification text (amounts, category names) can appear on the lock screen**, depending on the phone's notification preview setting.
