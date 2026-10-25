# S.E.C.U.R.E: Architecture

As built on 2026-10-24: Phase 1 complete, Phase 2 implemented. Parts not yet built are marked **planned** and described in [§13](#13-planned-architecture-phases-34).

This document explains every tool, technology and cryptographic mechanism in the app, and how they fit together.
- Feature list and status: [FEATURES.md](FEATURES.md)
- PRD review, threat model and decisions: [DESIGN.md](DESIGN.md)
- Original requirements: [PRD.md](PRD.md)
- Additional features (credit tiers, connected accounts, practice markets, strategies): [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md), [STRATEGIES.md](STRATEGIES.md)

Two sets of facts were measured, not taken from documentation: SQLCipher's configuration in [§6.2](#62-sqlcipher) (read from the built binary through its `PRAGMA` interface), and the message sizes in [§5.8](#58-canonical-binary-encoding) (from the encoder).

## Contents

1. [System overview](#1-system-overview)
2. [Technology stack](#2-technology-stack)
3. [Code organization](#3-code-organization)
4. [Runtime architecture](#4-runtime-architecture)
5. [Cryptography](#5-cryptography)
6. [Encryption at rest](#6-encryption-at-rest)
7. [Ledger and transfer protocol](#7-ledger-and-transfer-protocol)
8. [Budget engine](#8-budget-engine)
9. [Approvals and notifications](#9-approvals-and-notifications)
10. [Application layer](#10-application-layer)
11. [On-device data map](#11-on-device-data-map)
12. [Build, test and tooling](#12-build-test-and-tooling)
13. [Planned architecture (Phases 3–4)](#13-planned-architecture-phases-34)
14. [Security properties and limitations](#14-security-properties-and-limitations)
15. [Glossary](#15-glossary)

---

## 1. System overview

### 1.1 What the system is

S.E.C.U.R.E is an iOS app built on a Swift package called **SecureKit**. Every iPhone is a self-contained wallet:

- **Keys:** the wallet's signing key lives in the phone's **Secure Enclave**, and a Face ID match is required for every signature.
- **Ledger:** an append-only, hash-chained ledger stored in a **SQLCipher**-encrypted database.
- **Budgets:** evaluated locally before anything is signed.
- **Transfers:** two phones that are physically close sign matching distance measurements and exchange a signed transfer and a countersigned receipt.

There are no servers, no accounts and no network code.

In Phase 1 both sides of a transfer run in one process (`LoopbackPayment`) against two built-in counterparties, "Demo Issuer" and "Demo Shop". Each has its own encrypted ledger and key. Phases 3–4 move the counterparty onto a second iPhone, connected over Bluetooth and Ultra-Wideband.

### 1.2 Design principles

| Principle | How it shows up in the code |
|---|---|
| **Offline by construction** | No networking API is imported anywhere. Every check (signatures, chain, budgets, proofs) runs locally. |
| **Hardware root of trust** | The wallet key is generated and used inside the Secure Enclave. Face ID is enforced by the key's access control, not by an `if` in app code. |
| **Defense in depth** | The ledger sits behind four independent layers: tamper-evident chain, SQLCipher, iOS Data Protection, backup exclusion ([§6.1](#61-layers)). |
| **Fail closed** | Integrity doubts lock the wallet read-only. There's no software key fallback on real phones. The store refuses to open if SQLCipher isn't linked. |
| **Evidence over trust** | Every claim is signed. A double-spend leaves signed proof anyone can verify ([§7.6](#76-double-spend-evidence)). |
| **Privacy by default** | Spending categories never leave the phone. Transfers carry only what the payee needs. |
| **Testable without hardware** | Each hardware dependency sits behind a protocol with a Simulator/test implementation ([§3.3](#33-ports-and-adapters)). |

### 1.3 System context

```
┌───────────────────────── iPhone A ──────────────────────────┐            ┌──────── iPhone B ────────┐
│  S.E.C.U.R.E app (SwiftUI)                                  │            │  S.E.C.U.R.E app          │
│   ├─ SecureKit: SecureCore · SecureStore · SecureDevice     │  Bluetooth │  (same stack)             │
│   ├─ Secure Enclave ─ P-256 wallet key · Face ID matching   │◄──────────►│                           │
│   ├─ Keychain ─────── database key · chain anchor · key blob│    UWB     │                           │
│   └─ App container ── Wallet/wallet.sqlite (SQLCipher)      │◄══════════►│                           │
└─────────────────────────────────────────────────────────────┘  (planned  └───────────────────────────┘
                                                                  P3–P4)
                         No servers · no internet · no cloud sync · no analytics
```

---

## 2. Technology stack

### 2.1 Languages, frameworks and libraries

| Technology | Version | What it is | What S.E.C.U.R.E uses it for | Where |
|---|---|---|---|---|
| **Swift** | 6.4 compiler, Swift 6 language mode | Apple's systems language; Swift 6 mode turns data-race safety into compile errors | All code | everywhere |
| **SwiftUI** | iOS 26 SDK | Declarative UI framework | Every screen, sheet and banner | `App/*.swift` |
| **Observation** | iOS 17+ | `@Observable` / `@Bindable` macros that drive SwiftUI updates | `AppModel` state → views | [AppModel.swift](../App/AppModel.swift) |
| **Swift Concurrency** | Swift 6 | `async`/`await`, actors, `Sendable`, `Task.detached` | `WalletStore` actor, async signing sessions, startup off the main thread | [§4.2](#42-concurrency-model) |
| **CryptoKit** | iOS 26 SDK | Apple's Swift cryptography framework | `SHA256`; `P256.Signing` (software keys, all verification); `SecureEnclave.P256.Signing` (device keys); `SymmetricKey` (database key generation) | `SecureCore/Hashing`, `Keys`, `Signing`; `SecureDevice/Signers`; `SecureStore/WalletStore` |
| **Secure Enclave** | hardware (A-series SoC) | Isolated security coprocessor with its own boot, memory encryption and key storage | Creates and uses the wallet's P-256 key; performs the Face ID match | via CryptoKit, [§5.3](#53-secure-enclave-signing-key) |
| **Security framework** | iOS 26 SDK | Keychain Services and access control | `SecItemAdd/Update/CopyMatching/Delete` for secrets; `SecAccessControlCreateWithFlags` for the key's biometric policy | [KeychainSecretStore.swift](../Packages/SecureKit/Sources/SecureDevice/KeychainSecretStore.swift), [Signers.swift](../Packages/SecureKit/Sources/SecureDevice/Signers.swift) |
| **LocalAuthentication** | iOS 26 SDK | `LAContext`: Face ID / Touch ID prompts | `evaluateAccessControl(_:operation: .useKeySign, …)` on device; `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, …)` on the Simulator; reports biometry type | [Signers.swift](../Packages/SecureKit/Sources/SecureDevice/Signers.swift) |
| **UserNotifications** | iOS 26 SDK | Local notifications, categories, action buttons | Budget alerts, payment requests with Approve/Deny, foreground banners | [NotificationService.swift](../Packages/SecureKit/Sources/SecureDevice/NotificationService.swift) |
| **Swift Charts** | iOS 26 SDK | Declarative charts for SwiftUI | Additional features: spending by category, price history, prediction-market probability | [AccountsView.swift](../App/Connected/AccountsView.swift), [MarketsView.swift](../App/Connected/MarketsView.swift) |
| **UIKit** (minimal) | iOS 26 SDK | App lifecycle | `UIApplicationDelegateAdaptor`, so notifications are configured before launch completes | [SecureApp.swift](../App/SecureApp.swift) |
| **Foundation** | iOS 26 SDK | Base library | `FileManager` (file protection, folders), `URLResourceValues` (backup exclusion), `Calendar` (budget windows, time zones, DST), `Decimal` + `FormatStyle` (money display), `UserDefaults` (alert de-duplication), `NSLock` | throughout |
| **SQLCipher** | 4.19.0 community, on SQLite 3.53.4 | SQLite with transparent, authenticated page encryption; by Zetetic, BSD-style licence | The wallet database; used through SQLite's C API (`import SQLCipher`) | [SQLiteDatabase.swift](../Packages/SecureKit/Sources/SecureStore/SQLiteDatabase.swift), [§6.2](#62-sqlcipher) |
| **CommonCrypto** | system | Apple's C crypto library | SQLCipher's crypto provider: AES, HMAC, PBKDF2, random IVs (measured: `cipher_provider = commoncrypto`) | indirect |
| **Swift Testing** | Xcode 27.1 | `import Testing`, `@Test`, `#expect`, parameterized tests | 144 tests | `Packages/SecureKit/Tests` |
| **Swift Package Manager** | tools version 6.2 | Package and dependency manager | `SecureKit` modules; pins SQLCipher | [Package.swift](../Packages/SecureKit/Package.swift) |
| NearbyInteraction | iOS 27.1 SDK | UWB ranging between devices | **Planned (P3)**: real distance and direction | [§13.1](#131-uwb-ranging-with-nearbyinteraction) |
| CoreBluetooth | iOS 27.1 SDK | Bluetooth LE GATT and L2CAP | **Planned (P3–P4)**: discovery-token exchange and protocol messages | [§13.2](#132-bluetooth-transport-with-corebluetooth) |
| ARKit | iOS 27.1 SDK | Camera-based tracking | **Planned, optional**: NearbyInteraction "camera assistance" for direction on models that need it | [§13.1](#131-uwb-ranging-with-nearbyinteraction) |

### 2.2 Toolchain

| Tool | Version | Role |
|---|---|---|
| Xcode | 27.1 (27A9275) | IDE, compilers, `xcodebuild`, Simulator |
| iOS SDK | 27.1 | Build SDK |
| Deployment target | iOS 26.0 | Oldest supported iOS (keeps ML-DSA in the Secure Enclave available as a future option) |
| Simulator runtime | iOS 27.0, iPhone 18 Pro | Automated tests and walkthroughs |
| `xcrun simctl` / `devicectl` | Xcode 27.1 | Simulator control and Face ID automation; listing connected iPhones |
| Development Mac | macOS 27 on Apple silicon | Build host |
| Test devices (Phase 3) | Two UWB-capable iPhones (iPhone 11 or later, except the SE models) | Peer ranging needs two physical phones |

### 2.3 Deliberately not used

| Not used | Why |
|---|---|
| `URLSession`, Network framework, any server SDK | The product is offline by definition; no code path can send data anywhere |
| Third-party cryptography | CryptoKit and the Secure Enclave cover every primitive; SQLCipher's crypto runs on Apple's CommonCrypto |
| Core Data / SwiftData | Needed transparent page encryption, raw SQL, `STRICT` tables and triggers that enforce an append-only ledger |
| JSON or property lists for signed data | Not canonical: the same value can serialize to different bytes. Signed messages use a fixed binary encoding ([§5.8](#58-canonical-binary-encoding)) |
| MultipeerConnectivity | Can't wake a backgrounded app; payment requests to a locked phone need CoreBluetooth background modes |
| CloudKit / iCloud Keychain sync | Keys and the ledger must never leave the device (`ThisDeviceOnly` everywhere) |
| Analytics or crash SDKs | No data leaves the phone |
| Code generators (XcodeGen, Tuist, CocoaPods) | Not installed on the build Mac; the Xcode project is hand-written in the Xcode 16+ format ([§12.1](#121-xcode-project)) |

---

## 3. Code organization

### 3.1 Repository layout

```
secure/
├─ SECURE.xcodeproj/                  Xcode project (objectVersion 77, synchronized App/ folder)
├─ App/                               SwiftUI app target "SECURE" (display name S.E.C.U.R.E)
│  ├─ SecureApp.swift                 @main, AppDelegate, root view switch
│  ├─ AppModel.swift                  app state, actions, bootstrap, demo peers
│  ├─ HomeView.swift                  home screen, balance header, budget/activity rows, banners
│  ├─ PayView.swift                   pay sheet + budget verdict view
│  ├─ ApprovalSheet.swift             approve/deny a payment request
│  ├─ BudgetEditorView.swift          create budgets and categories
│  ├─ DetailViews.swift               transfer detail, measurement rows, Security screen
│  ├─ Connected/                      additional features: Accounts, Markets, Learn, Profile tabs
│  └─ Peer/                           phone-to-phone payments: Nearby screen, Multipeer link, UWB ranger
├─ Config/Info.plist                  NearbyInteraction, local-network and Bonjour keys (merged with generated ones)
├─ Packages/SecureKit/                Swift package (tools 6.2)
│  ├─ Package.swift                   5 libraries, 4 test targets, SQLCipher 4.19.0 (exact)
│  ├─ Package.resolved                pinned dependency state (committed)
│  ├─ Sources/SecureCore/             pure logic: Foundation + CryptoKit only
│  ├─ Sources/SecureStore/            SQLCipher persistence and the payment flow
│  │  └─ Connected/                   ConnectedStore: the additional features' own encrypted database
│  ├─ Sources/SecureDevice/           Keychain, Secure Enclave, Face ID, notifications
│  ├─ Sources/SecureConnect/          additional features: credit tiers, simulated banks and markets, strategies
│  ├─ Sources/SecurePeer/             phone-to-phone payment protocol over any message link
│  └─ Tests/                          SecureCoreTests (52), SecureConnectTests (42), SecureStoreTests (30), SecurePeerTests (20)
├─ docs/                              PRD, DESIGN, ARCHITECTURE, FEATURES, ADDITIONAL-FEATURES, STRATEGIES
├─ PHASES.md · WORKLOG.md · README.md
└─ .gitignore                         excludes build/, .build/, DerivedData, xcuserdata, secrets, *.sqlite
```

### 3.2 Module dependencies

```
                ┌──────────────────────────┐
                │  App (SwiftUI, MainActor) │
                └──┬───────────┬────────┬──┘
                   │           │        │
          ┌────────▼──┐  ┌─────▼──────┐ │
          │SecureDevice│  │SecureStore │ │
          │ Keychain   │  │ WalletStore│ │
          │ SE signer  │  │ SQLCipher ─┼─┼──► SQLCipher.xcframework (dynamic, 4.19.0)
          │ LAContext  │  │ Loopback   │ │
          │ Notifs     │  └─────┬──────┘ │
          └────────┬──┘        │        │
                   └─────┬─────┴────────┘
                   ┌─────▼──────┐
                   │ SecureCore │  Foundation + CryptoKit only:
                   │ (pure)     │  money, encoding, hashing, keys, messages,
                   └────────────┘  chain, budgets, continuity, ranging protocol
```

**Phone-to-phone payments.** `SecurePeer` depends on `SecureCore` and `SecureStore`. It carries the DESIGN §6 protocol between two phones over any message link, calling only `WalletStore`'s public steps. The app supplies the link (`MultipeerLink`) and the ranger (`NearbyRanger`). See [DESIGN §12](DESIGN.md#12-phone-to-phone-payments-v1).

**Additional features.** `SecureConnect` (credit tiers, simulated banks and markets, odds and strategy maths, responsible-play rules) depends only on `SecureCore` value types. `SecureStore` depends on it for `ConnectedStore`, which keeps its own database; the wallet files (`WalletStore`, `LoopbackPayment`, the chain anchor) don't import it. See [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md).

`SecureCore` has no storage, UI or hardware dependency, so the whole protocol and budget engine can be unit-tested on a Mac in under a second. `SecureStore` adds SQLCipher; `SecureDevice` adds Apple's device frameworks. The two never depend on each other. The app wires them together, for example by handing a `KeychainSecretStore` from `SecureDevice` to a `WalletStore` from `SecureStore`.

### 3.3 Ports and adapters

| Port (protocol) | Purpose | Device adapter | Simulator / test adapter |
|---|---|---|---|
| `TransactionSigner` + `SigningSession` (SecureCore) | Sign protocol messages after one approval | `SecureEnclaveSigner` / `SecureEnclaveSession` | `SimulatorBiometricSigner` (Simulator); `SoftwareSigner` / `SoftwareSigningSession` (tests, demo peers) |
| `SecretStore` (SecureCore) | Small secrets: database key, anchor, key blob | `KeychainSecretStore` | `InMemorySecretStore` (with `snapshot()`/`restore()` to stage Keychain rollbacks in tests) |
| `RangingSession` (SecureCore), extended by `PeerRanger` (SecurePeer) | Measure distance to a peer during a session | `NearbyRanger`: one `NISession` per nearby phone ([NearbyRanger.swift](../App/Peer/NearbyRanger.swift)) | `SimulatedRanging`, `SimulatedPeerRanger` (seedable, always flagged `simulated`) |
| `WalletStore` (SecureStore, concrete actor) | Encrypted ledger | SQLCipher file in Application Support | SQLCipher file in a temp folder; optional in-memory database |
| `NearbyLink` (app) carrying `PeerConnection` (SecurePeer) | Carry messages between phones | `MultipeerLink`: MultipeerConnectivity over Bluetooth and peer-to-peer Wi-Fi | `LoopbackLink` (two Simulators, loopback TCP); in-memory `Wire` in tests; `LoopbackPayment` (both sides in one process) |

### 3.4 File map

About 9,090 lines of Swift: ~2,450 app, ~5,060 package sources, ~1,580 tests. The wallet files are listed here; the additional features' files are listed in [ADDITIONAL-FEATURES §9](ADDITIONAL-FEATURES.md#9-code-map).

| File | Lines | Responsibility |
|---|---|---|
| **SecureCore** | | |
| `Hashing.swift` | 98 | Hex helpers, `Digest32`, `DomainTag`, `TaggedHash` (tagged SHA-256 and signing payloads) |
| `CanonicalEncoding.swift` | 118 | `CanonicalWriter` / `CanonicalReader`: deterministic big-endian, length-prefixed encoding; size limits |
| `Money.swift` | 103 | `CurrencyCode`, `Money` (Int64 minor units), parsing, overflow-checked arithmetic, formatting |
| `Keys.swift` | 79 | `SignatureAlgorithm`, `WalletPublicKey` (33-byte compressed P-256), verification, fingerprint |
| `Signing.swift` | 82 | `TransactionSigner`, `SigningSession`, `SignerKind`, `SigningError`, `SoftwareSigner` |
| `SecretStore.swift` | 40 | `SecretStore` protocol, `InMemorySecretStore` |
| `Ranging.swift` | 103 | `RangingCapabilities`, `VerticalEstimate`, `RangingSummary`, `RangingSession`, `SimulatedRanging`, `SplitMix64` |
| `Messages.swift` | 352 | `SessionNonce`, `ProximityMeasurement`, `SignedMeasurement`, `ProximityPolicy`, `SpatialProof`, `Transfer`, `SignedTransfer`, `Receipt`, `SignedReceipt` |
| `Chain.swift` | 200 | `LinkDirection`, `EntryKind`, `ChainLink`, `ChainTip`, `LedgerEntry`, `ChainVerifier`, `ChainSummary` |
| `Budget.swift` | 197 | `BudgetPeriod` window maths, `Budget`, `BudgetStatus`, `OfflineLimits`, `BudgetVerdict`, `BudgetEngine` |
| `Continuity.swift` | 166 | `ChainClaim`, `ForkEvidence`, `PeerRecord`, `ContinuityVerdict`, `Continuity.check` |
| `Time.swift` | 10 | Millisecond timestamps |
| **SecureStore** | | |
| `SQLiteDatabase.swift` | 195 | SQLCipher connection: keying, cipher check, statements, bindings, `BEGIN IMMEDIATE` transactions |
| `Schema.swift` | 111 | Migration v1 (schema v2 in DESIGN terms): tables, triggers, indexes |
| `WalletStore.swift` | 656 | The ledger actor: open/verify/anchor, categories, budgets, spending queries, pay/accept/receipt paths, peers, forks |
| `ChainAnchor.swift` | 79 | 73-byte Keychain anchor, integrity evaluation, `WalletLocation` (file protection, backup exclusion) |
| `LoopbackPayment.swift` | 89 | Both sides of the DESIGN §6 protocol in one process |
| **SecureDevice** | | |
| `KeychainSecretStore.swift` | 63 | Generic-password items, `WhenUnlockedThisDeviceOnly`, data-protection Keychain |
| `Signers.swift` | 167 | `SecureEnclaveSigner`, `SecureEnclaveSession`, `SimulatorBiometricSigner`, `WalletSigners`, `BiometryStatus` |
| `NotificationService.swift` | 97 | Categories and actions, budget alerts, payment requests, delegate routing, cold-launch queue |
| **App** | | |
| `AppModel.swift` | 422 | Observable state, actions, error text, `WalletBootstrap`, `DemoPeer` |
| `HomeView.swift` | 182 | Home screen and reusable rows |
| `PayView.swift` | 116 | Pay sheet, `VerdictView` |
| `DetailViews.swift` | 102 | Transfer detail, Security screen |
| `BudgetEditorView.swift` | 89 | Budget and category creation |
| `ApprovalSheet.swift` | 58 | Payment-request approval |
| `SecureApp.swift` | 51 | Entry point, app delegate, tab view (Wallet, Accounts, Markets, Learn, Profile) |

---

## 4. Runtime architecture

### 4.1 App startup

1. **`AppDelegate.application(_:didFinishLaunchingWithOptions:)`** calls `NotificationService.shared.configure()`. This sets the notification-center delegate and registers categories before launch completes, so a tap on a notification that launched the app isn't lost.
2. **`SecureApp`** creates the `AppModel`, shows "Opening wallet…" and calls `model.start()`.
3. **`WalletBootstrap.open`** runs in `Task.detached` so file and database work stays off the main thread:
   1. `WalletLocation.directory(named: "Wallet")` creates `Application Support/Wallet` with file protection *Complete* and marks it excluded from backup.
   2. **Identity rotation:** if `wallet.sqlite` doesn't exist (fresh install), it deletes any leftover `wallet.signing-key`, `wallet.chain-anchor` and `wallet.database-key` from the Keychain. Keychain items survive app deletion; reusing an old key from sequence 0 would collide with sequence numbers former peers already hold.
   3. `WalletSigners.loadOrCreate` loads or creates the signer: the Secure Enclave on a phone, a software key gated by Face ID on the Simulator.
   4. `WalletStore.init` reads or creates the database key, opens SQLCipher and verifies the cipher, runs migrations, writes genesis for a new wallet, verifies the whole chain and compares it with the Keychain anchor. The result is an `IntegrityStatus` ([§7.3](#73-chain-verification-and-the-anchor)).
   5. Opens the two demo peers in `Application Support/DemoPeers` (software keys in the Keychain).
4. **Back on the main actor:**
   - pin Demo Issuer's key as a trusted issuer;
   - install the notification handler, which first delivers any queued taps;
   - request notification permission;
   - on first launch, seed the Food, Clothing and Transport categories and a $200/month Clothing budget;
   - load the UI state.
5. The phase becomes `.ready`, or `.failed(message)` if anything above threw (for example a missing database key).

### 4.2 Concurrency model

| Component | Isolation | Why |
|---|---|---|
| App target (views, `AppModel`) | Main actor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) | UI state is only touched on the main thread |
| `WalletStore` | Swift `actor` | Owns the single SQLCipher connection (`SQLiteDatabase`, a non-`Sendable` class confined to the actor). All reads and writes are serialized. |
| SQLite itself | `THREADSAFE=1` build, opened with `SQLITE_OPEN_FULLMUTEX` | A second guard under the actor |
| Protocol messages (`Transfer`, `SpatialProof`, …) | `Sendable` value types | Passed freely between actors without copying hazards |
| `InMemorySecretStore`, `SoftwareSigningSession`, `SecureEnclaveSession` | Classes with an `NSLock`, `@unchecked Sendable` | Small shared mutable state, protected by hand |
| `WalletBootstrap`, `DemoPeer` | `nonisolated` | Run inside `Task.detached` during startup |
| `NotificationService` | `@MainActor`; delegate methods `nonisolated async` | Extracts plain strings from the non-`Sendable` `UNNotificationResponse`, then hops to the main actor |

**Actor reentrancy.** An `await` (for example the Face ID prompt) lets other work run on the actor in between. The payer side handles this optimistically. `preparePayment` records the chain tip in the `PaymentDraft`; `commitDebit` re-reads the tip inside `BEGIN IMMEDIATE` and throws `chainMoved` if it changed. The signed but unsent transfer is then discarded, so the funds are never signed twice.

### 4.3 Payment pipeline

`LoopbackPayment.run(from:to:amount:categoryID:overrideOverBudget:)` performs the protocol in this order. Phase 4 keeps the order and splits it across two phones.

| Step | Actor | Call | Checks / output |
|---|---|---|---|
| 1 | both | `SessionNonce.derive(payerContribution:payeeContribution:)` | 32-byte joint session ID from 16 random bytes per side |
| 2 | payer | `WalletStore.preparePayment` | Wallet unlocked; payee ≠ self; budget verdict. A hard stop throws `.blocked`; an over-budget verdict without override throws `.needsOverride`. Output: `PaymentDraft` (tip, verdict, timestamp) |
| 3 | both | `TransactionSigner.authorize(reason:)` | One Face ID per side ("Pay $25.00 to Demo Shop" / "Receive …"); output: signing sessions |
| 4 | both | `RangingSession.measure` → `ProximityMeasurement` → `SigningSession.sign` | Each phone signs its own distance reading; output: `SpatialProof` |
| 5 | payee | `WalletStore.preflightIncoming` | "Ready": proof valid under the payee's policy, acceptance limit, payer not a known forker |
| 5b | payer | `SpatialProof.verify` (payer's policy) | Payer checks the same proof; output: agreed distance |
| 6 | payer | `PaymentDraft.transfer(spatialProof:)` → sign → `WalletStore.commitDebit` | Debit appended atomically (budget re-checked in the transaction) **before** handover |
| 7 | payee | `WalletStore.acceptTransfer` → sign `Receipt` | Full acceptance rules ([§7.4](#74-transfer-protocol)); credit or mint appended; peer record advanced |
| 8 | payer | `WalletStore.storeReceipt` | Receipt verified and stored; payee's chain position learned |

---

## 5. Cryptography

### 5.1 Primitives

| Primitive | Implementation | Used for |
|---|---|---|
| **SHA-256** | CryptoKit `SHA256` | Chain links, transfer IDs, proof hashes, session nonces, genesis payload, key fingerprints |
| **ECDSA on P-256 (secp256r1) with SHA-256** | Secure Enclave via `SecureEnclave.P256.Signing` (phone); CryptoKit `P256.Signing` (Simulator, tests, demo peers, and all verification) | Signing distance measurements, transfers and receipts |
| **AES-256-CBC with HMAC-SHA512 per page (encrypt-then-MAC)** | SQLCipher 4.19.0 on CommonCrypto | Database encryption at rest ([§6.2](#62-sqlcipher)) |
| **PBKDF2-HMAC-SHA512** | SQLCipher internal | Derives the page-HMAC key from the raw database key (2 iterations). The 256,000-iteration passphrase KDF is **not** used, because the key is a random 256-bit raw key. |
| **AES-256 file encryption** | iOS Data Protection (hardware AES engine, per-file keys) | Encrypts `wallet.sqlite` again at the file-system level ([§6.3](#63-ios-data-protection)) |
| **AES-256-GCM** | Keychain (managed by iOS) | Protects Keychain items: database key, anchor, key blob ([§6.4](#64-keychain)) |
| **CSPRNG** | Secure Enclave (wallet key); CryptoKit `SymmetricKey` (database key); `SystemRandomNumberGenerator` (session nonce contributions); CommonCrypto (SQLCipher salt and IVs) | All randomness ([§5.7](#57-randomness)) |

### 5.2 Key inventory

| Secret | Algorithm / size | Created by | Stored in | Protection | Who can use it | Lifetime |
|---|---|---|---|---|---|---|
| **Wallet signing key** (phone) | ECDSA P-256, 256-bit | Secure Enclave, at first launch | Private key: inside the Secure Enclave only. Encrypted blob (`dataRepresentation`): Keychain `wallet.signing-key` | Access control `.privateKeyUsage + .biometryAny`; Keychain `WhenUnlockedThisDeviceOnly` | This phone's Secure Enclave, after a Face ID match | Until the wallet's database is gone (a reinstall creates a new identity) |
| **Wallet signing key** (Simulator) | ECDSA P-256 software key | CryptoKit | Keychain `wallet.signing-key` (raw key) | `WhenUnlockedThisDeviceOnly`; app-level Face ID check | App process | Same |
| **Database key** | 256-bit random, raw SQLCipher key | CryptoKit `SymmetricKey(size: .bits256)` | Keychain `wallet.database-key` | `WhenUnlockedThisDeviceOnly` | SQLCipher inside the app process | Lifetime of the database; never replaced if missing |
| **Page-HMAC key** | HMAC-SHA512 key | SQLCipher, derived at open | Memory only | — | SQLCipher | Per database connection |
| **Chain anchor** | Not a key: 73-byte record | `WalletStore` | Keychain `wallet.chain-anchor` | `WhenUnlockedThisDeviceOnly` | `WalletStore` | Rewritten after every commit |
| **Demo peer keys** | ECDSA P-256 software keys | CryptoKit | Keychain `demo-issuer.signing-key`, `demo-shop.signing-key` (+ their own database keys and anchors) | `WhenUnlockedThisDeviceOnly` | App process | Demo only; replaced in Phase 4 by real phones |
| **Session nonce contributions** | 16 random bytes per side | `SystemRandomNumberGenerator` | Memory; the derived nonce is stored in ledger rows | — | Protocol | One transfer |
| **Data Protection keys** | AES-256 per-file key, wrapped by the Complete class key | iOS | Managed by iOS and the Secure Enclave | Class key unavailable while locked | iOS kernel | OS-managed |

### 5.3 Secure Enclave signing key

The **Secure Enclave** is a separate security subsystem inside the iPhone's chip, with its own processor, encrypted memory and key storage. Keys created there can be used through it but never read out. Face ID matching also happens inside it; the app only learns success or failure.

**Lifecycle** ([Signers.swift](../Packages/SecureKit/Sources/SecureDevice/Signers.swift)):

```
create (first launch)
  SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                  [.privateKeyUsage, .biometryAny])
  SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: …)
  └─ key.dataRepresentation  ──►  Keychain "wallet.signing-key"   (opaque blob; only this SE can use it)

load (every launch)          PrivateKey(dataRepresentation:)          no prompt

authorize (each transfer)    LAContext().evaluateAccessControl(acl, operation: .useKeySign,
                                                               localizedReason: "Pay $25.00 to Demo Shop")
                             ── Face ID match inside the Secure Enclave ──
                             PrivateKey(dataRepresentation:, authenticationContext: context)
                             └─ SecureEnclaveSession (valid 60 s)

sign (2× per side)           key.signature(for: payload)   →   ECDSASignature.rawRepresentation (64 bytes r‖s)

end                          session.end(): key reference dropped, context.invalidate()
```

**Why this access control.** The flags decide what the Secure Enclave demands before each use of the key:

| Option | Consequence | Chosen? |
|---|---|---|
| No biometric flag (`.privateKeyUsage` only) | Any code in the app could sign silently | No |
| `.userPresence` | Face ID **or** the device passcode | No: the PRD asks for biometrics |
| `.biometryCurrentSet` | Face ID; the key is destroyed when faces are added or removed. A device-bound balance would be lost with it. | No |
| **`.biometryAny`** | Face ID required for every use; survives enrolment changes | **Yes** |

The passcode remains iOS's root of trust: someone who knows the passcode can enroll their own face. The planned two-key scheme addresses that ([DESIGN §3.1](DESIGN.md#31-what-it-protects-against)).

**One approval, several signatures.** Each side signs its distance measurement and then either the transfer (payer) or the receipt (payee). Evaluating the `LAContext` once against the key's access control and passing that context to the key lets both signatures go through without a second prompt. `SecureEnclaveSession` limits this window to 60 seconds and invalidates the context when the transfer ends.

**No silent downgrade.** `WalletSigners.loadOrCreate` returns a Secure Enclave signer on real hardware and throws if `SecureEnclave.isAvailable` is false. Software keys are compiled in only under `targetEnvironment(simulator)` and in tests.

> Status: written and compiling for iPhone; the first run on a real phone is pending ([FEATURES 1.1–1.2](FEATURES.md#1-wallet-identity-and-keys)).

### 5.4 Simulator signer

The Simulator has no Secure Enclave. `SimulatorBiometricSigner` keeps a software P-256 key in the Keychain and asks `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` before opening a session. The Simulator's simulated Face ID drives it ([§12.4](#124-simulator-face-id-automation)). The Face ID check is app code here and the key sits in process memory, so this is a UX stand-in, not a security boundary. The Security screen labels it "Simulator: software key + Face ID check".

### 5.5 What gets signed

| Message | Signed by | Signing tag | Body size | Purpose |
|---|---|---|---|---|
| `ProximityMeasurement` | Each phone (the observer) | `SECURE/measurement/v1` | 122–125 bytes | Binds a distance reading to this session and both identities |
| `Transfer` | Payer | `SECURE/transfer/v1` | 204 bytes | Authorizes the debit; commits to the payer's chain position and the spatial proof |
| `Receipt` | Payee | `SECURE/receipt/v1` | 119 bytes | Acknowledges the credit at the payee's chain position |

- **Signing payload** = `u32 length(tag) ‖ tag (UTF-8) ‖ canonical body`. CryptoKit's ECDSA hashes the payload with SHA-256 and signs the digest. For transfers that digest is exactly the transfer ID ([§5.6](#56-hashing-and-domain-separation)), so the signature binds the ID.
- **Signature format:** 64 bytes, `r ‖ s` (`ECDSASignature.rawRepresentation`).
- **Public key format:** 33-byte SEC1 compressed P-256 point (`compressedRepresentation`), prefixed by an algorithm byte ([§5.8](#58-canonical-binary-encoding)). Decoding rejects any point that doesn't parse.
- **Verification:** `WalletPublicKey.isValidSignature(_:for:)` rebuilds the CryptoKit public key and checks the signature. Malformed keys or signatures simply fail.
- **Malleability:** an ECDSA signature `(r, s)` can be rewritten as `(r, n − s)` and still verify. IDs are therefore computed over the **unsigned** fields only, so a rewritten signature can't create a second ID for the same transfer.

### 5.6 Hashing and domain separation

All hashes are `SHA-256( u32 length(tag) ‖ tag ‖ body )` (`TaggedHash.sha256`). The tag stops bytes hashed or signed for one purpose from being reused for another. Length-prefixing the tag removes any ambiguity between the tag and the body.

| Tag | Hash or signature over | Produces |
|---|---|---|
| `SECURE/genesis/v1` | Canonical wallet public key (38 bytes) | Genesis payload `G` |
| `SECURE/link/v1` | `prev_link (32) ‖ seq (i64) ‖ direction (u8) ‖ payload (32)` = 73 bytes | Chain link `Lₙ` |
| `SECURE/session/v1` | `u32 16 ‖ payer bytes (16) ‖ u32 16 ‖ payee bytes (16)` = 40 bytes | Session nonce |
| `SECURE/measurement/v1` | Measurement body | Signing payload for measurements |
| `SECURE/proof/v1` | Spatial proof body | `spatial_proof_hash` (committed in the transfer) |
| `SECURE/transfer/v1` | Transfer body (unsigned) | Transfer ID, and the payer's signing payload |
| `SECURE/receipt/v1` | Receipt body | Signing payload for receipts |

Key fingerprints, for display only, are the first 8 bytes of plain SHA-256 over the 33-byte key, shown as `xxxx-xxxx-xxxx-xxxx`.

### 5.7 Randomness

| Value | Source | Size |
|---|---|---|
| Wallet private key (phone) | Secure Enclave's internal generator | 256-bit |
| Software keys (Simulator, demo peers, tests) | CryptoKit `P256.Signing.PrivateKey()` | 256-bit |
| Database key | CryptoKit `SymmetricKey(size: .bits256)` | 256-bit |
| Session nonce contributions | `SystemRandomNumberGenerator` (the OS cryptographic generator on Apple platforms) | 128-bit per side |
| SQLCipher file salt, per-page IVs | CommonCrypto, inside SQLCipher | 128-bit salt; 128-bit IV per page write |
| Simulated ranging noise | `SplitMix64` (deterministic, seedable) | Not security-relevant: test data only |

### 5.8 Canonical binary encoding

Everything that is hashed or signed uses one encoding ([CanonicalEncoding.swift](../Packages/SecureKit/Sources/SecureCore/CanonicalEncoding.swift)):

- Integers are big-endian, fixed width (`u8`, `u16`, `u32`, `u64`, `i16`, `i64`; signed as two's complement).
- Variable-length bytes and strings carry a `u32` length prefix. Strings are UTF-8.
- Fixed-size values (digests, nonces) are written raw, with no prefix.
- Optionals are one presence byte (`0`/`1`), followed by the value if present.
- Booleans are exactly `0` or `1`; anything else is rejected.
- Fields appear in a fixed order. Each message starts with a version byte (currently `1`).

Decoding is strict:
- truncated input, trailing bytes, any length-prefixed field over 64 KiB, an unknown version, a non-UTF-8 string, an invalid public key, a non-positive amount or an invalid currency all throw;
- a decoded structure re-encodes to the identical bytes.

**Byte layouts** (sizes in bytes):

`WalletPublicKey`: 38
| Field | Type | Size |
|---|---|---|
| algorithm | u8 (`1` = P-256 ECDSA) | 1 |
| key length | u32 (= 33) | 4 |
| key | SEC1 compressed point | 33 |

`ProximityMeasurement`: 122–125
| Field | Type | Size |
|---|---|---|
| version | u8 | 1 |
| session nonce | digest | 32 |
| observer | WalletPublicKey | 38 |
| subject | WalletPublicKey | 38 |
| distance (median), cm | u16 | 2 |
| spread (p90 − p10), cm | u16 | 2 |
| sample count | u16 | 2 |
| azimuth, 1/100° | optional i16 | 1 or 3 |
| vertical estimate | optional u8 (0 unknown, 1 same, 2 above, 3 below, 4 above-or-below) | 1 or 2 |
| capability flags | u8 (bit0 precise distance, bit1 direction, bit2 camera assistance, bit3 extended distance, bit7 simulated) | 1 |
| duration, ms | u32 | 4 |

`SpatialProof`: 389–395 = `version (1) ‖ [u32 len ‖ payer measurement ‖ u32 len ‖ 64-byte signature] ‖ [same for payee]`

`Transfer`: 204
| Field | Type | Size |
|---|---|---|
| version | u8 | 1 |
| payer | WalletPublicKey | 38 |
| payee | WalletPublicKey | 38 |
| amount, minor units | i64 (> 0) | 8 |
| currency | string (3 letters) | 7 |
| session nonce | digest | 32 |
| payer sequence | i64 (> 0) | 8 |
| payer previous link | digest | 32 |
| spatial proof hash | digest | 32 |
| created at, ms | i64 | 8 |

`SignedTransfer`: 276 = `u32 len ‖ Transfer (204) ‖ u32 len ‖ signature (64)`

`Receipt`: 119 = `version (1) ‖ transfer ID (32) ‖ payee key (38) ‖ payee sequence (8) ‖ payee previous link (32) ‖ created at (8)`

`SignedReceipt`: 191 = `u32 len ‖ Receipt ‖ u32 len ‖ signature (64)`

`ChainClaim`: 281 (debit) or 196 (credit) = `type (1 = debit, 2 = credit) ‖ u32 len ‖ SignedTransfer or SignedReceipt`

`ForkEvidence` = `u32 len ‖ earlier claim ‖ u32 len ‖ later claim`, e.g. 570 bytes for two debit claims

`ChainAnchor`: 73 = `version (1) ‖ genesis link (32) ‖ tip sequence (i64) ‖ tip link (32)`

A complete transfer (proof, signed transfer, receipt) is under 1 KB: small enough for a handful of Bluetooth LE writes or one L2CAP message in Phase 4.

---

## 6. Encryption at rest

### 6.1 Layers

The ledger file is protected by four independent mechanisms. Defeating one doesn't defeat the others.

| Layer | Mechanism | Protects against | Key held by |
|---|---|---|---|
| 1. Tamper evidence | Hash chain, signatures, append-only triggers, Keychain anchor ([§7](#7-ledger-and-transfer-protocol)) | Edits, deletions, reordering, partial rollback, even by someone holding the database key | Nothing secret; verification uses public data and the anchor |
| 2. Database encryption | SQLCipher: AES-256 pages + HMAC-SHA512 ([§6.2](#62-sqlcipher)) | Reading or modifying a copied database file | Keychain (`WhenUnlockedThisDeviceOnly`) |
| 3. File encryption | iOS Data Protection class *Complete* ([§6.3](#63-ios-data-protection)) | Reading the file on a locked or powered-off phone | Class key derived from the passcode and the device's hardware key |
| 4. Containment | Excluded from backups; Keychain items never sync ([§6.5](#65-backups)) | Copies leaking through iCloud or computer backups; restoring spent balances from a backup | — |

### 6.2 SQLCipher

**SQLCipher** is a fork of SQLite by Zetetic that encrypts every database page on its way to disk and authenticates it on the way back. To the app it looks exactly like SQLite: the same C API, plus a key.

**Measured configuration** (read from the built binary on 2026-10-24 with `PRAGMA` queries):

| Setting | Value | Meaning |
|---|---|---|
| `cipher_version` | `4.19.0 community` | Community (open-source) edition |
| `sqlite_version()` | `3.53.4` | Underlying SQLite |
| `cipher_provider` | `commoncrypto` | Crypto runs on Apple's CommonCrypto |
| `cipher_page_size` / `page_size` | 4096 | Encryption unit = one 4 KiB page |
| `cipher_use_hmac` | 1 | Every page is authenticated |
| `cipher_hmac_algorithm` | `HMAC_SHA512` | 64-byte tag per page |
| `cipher_kdf_algorithm` | `PBKDF2_HMAC_SHA512` | KDF for passphrases (unused: raw key) |
| `kdf_iter` | 256000 | Passphrase iterations (unused: raw key) |
| `fast_kdf_iter` | 2 | Iterations for deriving the HMAC key |
| `cipher_plaintext_header_size` | 0 | Nothing stored in plaintext; even SQLite's header is encrypted |
| `cipher_memory_security` | 0 | SQLCipher doesn't lock or wipe its buffers (its default) |
| Compile options | `HAS_CODEC`, `THREADSAFE=1`, `TEMP_STORE=2` | Encryption compiled in; serialized threading; temporary tables kept in memory |
| `journal_mode` | `delete` | Rollback journal, deleted on commit |

**Keying.** Immediately after `sqlite3_open_v2`, `SQLiteDatabase` executes:

```
PRAGMA key = "x'<64 hex characters = 32 random bytes>'";
```

The `x'…'` raw-key form makes SQLCipher use the 32 bytes directly as the AES-256 key and skip the 256,000-iteration passphrase KDF. That is safe because the key is random, not a human password, and it avoids a slow KDF on every open. The page-HMAC key is derived separately from the encryption key and a masked copy of the file salt, with 2 PBKDF2 iterations (`fast_kdf_iter`).

**On-disk format** (SQLCipher's documented page format; the random salt and the absence of plaintext were checked directly):
- The first 16 bytes of the file are a random salt. The test file's first bytes were `682c9db8cdb7361a…`, not SQLite's `"SQLite format 3\0"`.
- Each page holds AES-256-CBC ciphertext.
- A reserved area at the end of each page stores a fresh random IV (generated on every page write) and an HMAC-SHA512 tag. The tag covers the ciphertext, the IV and the page number, so pages can't be swapped or altered without detection.
- In the probe, the plaintext `"hello"` written to a table appeared nowhere in the file.

**Open-time safety checks** (`SQLiteDatabase.init`):

1. `PRAGMA cipher_version` must return a value. If the binary were plain SQLite, opening fails with `sqlcipherMissing` instead of silently writing an unencrypted file.
2. `SELECT count(*) FROM sqlite_master` forces the first page to decrypt. A wrong key fails here with `SQLITE_NOTADB`.
3. `PRAGMA foreign_keys = ON`.

**Journals and temporary data.** Rollback-journal pages are written in encrypted form and deleted at commit. `TEMP_STORE=2` keeps temporary tables and indexes in memory.

**In memory.** While the database is open, decrypted pages live in SQLite's page cache inside the app process. With `cipher_memory_security` off, SQLCipher doesn't wipe those buffers. iOS process isolation keeps other apps out; enabling memory security is a hardening option for Phase 6.

**Licence.** SQLCipher Community Edition is distributed by Zetetic LLC under a BSD-style licence (in the package checkout's `LICENSE.md`). It embeds SQLite, which is public domain.

### 6.3 iOS Data Protection

`WalletLocation` sets `FileProtectionType.complete` on the `Wallet` folder and on the database file; new files in the folder (journals) inherit it.

- **What iOS does:** every file is encrypted with its own per-file AES key. That key is wrapped by a class key. For class *Complete*, the class key is derived from the user's passcode and a hardware key fused into the device.
- **When it locks:** shortly after the phone locks (about 10 seconds with "Require passcode: Immediately"), iOS discards the unwrapped class key and the file can't be read until the next unlock.
- **Consequence:** the ledger is unreadable on a locked or powered-off phone even with full access to the flash storage. Phase 4 design consequence: a payment request arriving over Bluetooth while the phone is locked can't read budget data. Its notification will show a generic message, and details appear after unlock.
- **Simulator:** file protection has no effect there; it applies on real devices.

### 6.4 Keychain

`KeychainSecretStore` stores each secret as a generic-password item (`kSecClassGenericPassword`):

| Attribute | Value | Effect |
|---|---|---|
| `kSecAttrService` | `com.example.secure` | Namespaces the app's items |
| `kSecAttrAccount` | e.g. `wallet.database-key` | One item per secret ([§11](#11-on-device-data-map)) |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | Decryptable only while the phone is unlocked; never synced to iCloud Keychain; never migrates to another device |
| `kSecUseDataProtectionKeychain` | `true` | The modern Data Protection Keychain on every platform |

iOS encrypts each Keychain item with AES-256-GCM under keys protected by the Secure Enclave. Keychain items survive app deletion, which is why the app rotates its identity on a fresh install ([§4.1](#41-app-startup)).

### 6.5 Backups

The `Wallet` folder and database file carry `isExcludedFromBackup = true`, so neither iCloud Backup nor a Finder or iTunes backup contains the ledger. Restoring a backup therefore can't bring back balances that were already spent. A legitimate restore to a new phone starts with an empty wallet: the keys are device-bound and there is no server (decision D2, "a lost phone loses its balance").

### 6.6 What an attacker sees

| Attacker capability | Outcome |
|---|---|
| Holds the **locked** phone | Database file unreadable (Data Protection); Keychain items locked; Secure Enclave key unusable |
| Has the phone **unlocked** for a moment | Can view balances in the app; can't sign anything without a Face ID match enforced by the Secure Enclave |
| Extracts the app container **from a backup** | The ledger isn't in backups |
| Obtains a raw copy of `wallet.sqlite` | Still SQLCipher ciphertext; the key is in the Keychain, readable only by this app on this unlocked phone |
| **Edits bytes** in the database | Page HMAC fails, or chain verification fails on open; the wallet locks |
| Has the key and **edits rows directly** | Append-only triggers reject updates and deletes; any change to signed data breaks signatures and links; the wallet locks |
| Restores an **older database** but not the Keychain | The anchor is ahead of the database; the wallet locks (`rolledBack`) |
| Restores an **older database and Keychain together** | Undetectable on that phone. Caught when the wallet meets a peer holding a later claim ([§7.6](#76-double-spend-evidence)) |

---

## 7. Ledger and transfer protocol

### 7.1 Database schema

The exact SQL is in [Schema.swift](../Packages/SecureKit/Sources/SecureStore/Schema.swift), mirrored in [DESIGN §5](DESIGN.md#5-data-model-v2). All tables are `STRICT`, so SQLite rejects values of the wrong type.

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `meta` | Wallet identity and settings | `wallet_key` (canonical public key), `currency`, `issuer_keys` (pinned issuers, canonical list) |
| `categories` | Spending categories | `name` UNIQUE, `icon_name`, `archived` ∈ {0, 1} |
| `budgets` | Caps per category | `cap_minor ≥ 0`, `currency`, `period` ∈ {monthly, weekly, rolling, custom}, `anchor` (day 1–31 or weekday 1–7), `start_date`, `length_days > 0`, `alert_pct` 1–100, `hard_cap` ∈ {0, 1}. A CHECK requires the right parameters for each period. `ON DELETE CASCADE` from categories. |
| `ledger` | Append-only hash chain | `seq` (primary key, ≥ 0), `kind` ∈ {genesis, mint, debit, credit}, `counterparty_key`, `amount_minor ≥ 0`, `currency`, `category_id` (local note), `session_nonce`, `transfer_id` UNIQUE, `transfer` (signed bytes), `spatial_proof`, `spatial_proof_hash`, `created_at_ms`, `prev_link`, `link` UNIQUE; `UNIQUE(counterparty_key, session_nonce)` |
| `receipts` | Payees' countersignatures | `entry_link` → `ledger(link)`, `receipt` (signed bytes), `received_at_ms` |
| `pending_transfers` | Transfers in progress (**reserved for P4**) | `session_nonce` primary key, `role`, `state` ∈ {requested, ranging, ready, awaiting_approval, denied, expired} |
| `peers` | Latest known claim about each counterparty's chain | `public_key` primary key, `display_name`, `last_claim` (canonical `ChainClaim`), `last_seq`, `fork_evidence` |

**Triggers**
- `ledger_no_update` and `ledger_no_delete`: `RAISE(ABORT)` on any change to existing rows.
- `ledger_append_in_order`: rejects an insert whose `seq` isn't `MAX(seq) + 1`.

These guard against bugs and direct SQL edits. The cryptographic checks in §7.3 guard against deliberate tampering.

**Indexes**
- `ledger_debits_by_category (category_id, created_at_ms) WHERE kind = 'debit'`: a partial index for budget queries.
- `ledger_by_time (created_at_ms)`.

**Migrations.** `Schema.migrate` runs pending migrations in one transaction and records the count in `PRAGMA user_version`.

### 7.2 Hash chain

```
 seq 0  genesis              seq 1  incoming (mint)        seq 2  outgoing (debit)
┌──────────────────────┐    ┌──────────────────────┐      ┌──────────────────────┐
│ prev    = 00…00      │    │ prev    = L0          │      │ prev    = L1          │
│ payload = G          │──► │ payload = id(T1)      │ ───► │ payload = id(T2)      │
│ link    = L0         │    │ link    = L1          │      │ link    = L2          │
└──────────────────────┘    └──────────────────────┘      └──────────────────────┘

G  = SHA-256( "SECURE/genesis/v1" ‖ wallet public key )
Lₙ = SHA-256( "SECURE/link/v1"    ‖ Lₙ₋₁ ‖ n ‖ direction ‖ payloadₙ )      direction: 0 genesis · 1 outgoing · 2 incoming
```

- **Bound to one wallet:** the genesis link commits to the wallet's public key, so a chain can't be passed off as another wallet's.
- **Public by design:** a link covers only the sequence number, direction and transfer ID, all of which both parties hold. A payee holding the payer's signed transfer at sequence *n* can recompute the payer's link `Lₙ` (`ChainLink.afterDebit`). The payer can do the same from a receipt (`ChainLink.afterCredit`). Cross-checking chains depends on this ([§7.6](#76-double-spend-evidence)).
- **What stays out:** the category and the mint-versus-credit label are local judgements and aren't hashed. SQLCipher's page HMAC already protects them from anyone without the key.

### 7.3 Chain verification and the anchor

**Verification** (`ChainVerifier.verify`) runs on every open and on demand. In order:

1. The first entry is genesis: `seq = 0`, `prev_link = 0…0`, and `link = genesis(owner)`.
2. For each later entry:
   1. `seq` equals its position (no gaps).
   2. `prev_link` equals the previous entry's link.
   3. The entry holds a signed transfer and the signature verifies.
   4. The transfer's amount equals the entry's amount, and the stored proof's hash equals the transfer's `spatialProofHash`.
   5. **Debits:** the payer is this wallet, the counterparty is the payee, and the transfer's `payerSeq` and `payerPrevLink` equal this exact position. A debit can't be moved.
   6. **Credits and mints:** the payee is this wallet and the counterparty is the payer.
   7. The link recomputes.
   8. The running balance per currency doesn't overflow and never goes negative, unless the wallet is an issuer.

A failure returns a typed `ChainViolation`, such as `linkMismatch(seq: 7)`.

**The anchor** is the 73-byte record `(genesis link, tip seq, tip link)` in the Keychain, rewritten after every commit. On open, `ChainAnchor.evaluate` compares it with the verified chain:

| Condition | `IntegrityStatus` | Wallet |
|---|---|---|
| Chain verification failed | `chainInvalid(violation)` | Locked |
| No anchor, or the anchor belongs to another identity, **and** the wallet was just created | `verified` (anchor written) | Open |
| No anchor for this identity, but the wallet has history | `anchorMissing` | Locked |
| Anchor sequence > database tip | `rolledBack(anchorSeq, databaseSeq)` | Locked |
| The database's link at the anchor's sequence ≠ the anchor's link | `diverged(atSeq)` | Locked |
| Anchor sequence = tip and links match | `verified` | Open |
| Anchor sequence < tip and the database contains the anchor's link | `anchorAdvanced(from, to)` (anchor rewritten) | Open |

`anchorAdvanced` covers a crash between the database commit and the Keychain write, the only order in which writes happen. Locked wallets still display their data, but every payment, receipt and commit throws `walletLocked`.

### 7.4 Transfer protocol

```
Payer A                                           Payee B
  │  n_A (16 random bytes)          n_B          │
  │  session = SHA-256("SECURE/session/v1" ‖ n_A ‖ n_B)
  │  preparePayment: budget + balance check      │
  │  Face ID (one approval)        Face ID (one approval)
  │◄════════════ ranging (simulated now; UWB in P3) ═══════════►│
  │── Measurement_A + sig_A ───────────────────────────────────►│
  │◄─────────────────────────────────────── Measurement_B + sig_B │
  │                                  preflightIncoming ("Ready")│
  │  sign Transfer; commitDebit (append, anchor)                │
  │── SignedTransfer + SpatialProof ───────────────────────────►│
  │                    acceptTransfer (append credit, anchor)   │
  │◄──────────────────────────────────────────── SignedReceipt ──│
  │  storeReceipt                                                │
```

**Payee acceptance rules** (`WalletStore.acceptTransfer`), in order:

1. The wallet isn't locked.
2. The transfer is addressed to this wallet, and the payer isn't this wallet.
3. The transfer's session nonce is the expected one for this live session.
4. The payer's signature verifies.
5. The proof's hash equals the transfer's `spatialProofHash`, and the proof verifies under this wallet's policy ([§7.5](#75-spatial-proof)).
6. The amount is within this wallet's acceptance limit.
7. **Duplicate?** If this transfer ID is already in the ledger, return the existing entry and receipt (idempotent re-delivery).
8. **Known cheater?** If the wallet holds valid fork evidence against the payer, refuse.
9. **Continuity** ([§7.6](#76-double-spend-evidence)): a fork records evidence and refuses; any other verdict proceeds.
10. Append as `mint` (if the payer is a pinned issuer) or `credit`, advance the peer record (in the same transaction), update the anchor, and return the unsigned receipt for the payee to sign.

**Payer commit rules** (`WalletStore.commitDebit`): the wallet isn't locked; the transfer is signed by this wallet; the proof matches. Then, inside `BEGIN IMMEDIATE`:
- the transfer's `payerSeq` and `payerPrevLink` must equal the current tip + 1, otherwise `chainMoved`;
- the budget verdict is re-evaluated, and `blocked` or `needsOverride` aborts;
- the debit is appended.

The anchor is written after the commit.

**Receipt rules** (`WalletStore.storeReceipt`):
- the receipt's signature verifies;
- it names a debit in this ledger, and the signer is that debit's payee;
- the continuity check passes (a fork records evidence and refuses).

The receipt is then stored and the peer record advanced in one transaction.

### 7.5 Spatial proof

Each phone summarizes a ranging window into a `RangingSummary`:
- median distance;
- spread between the 10th and 90th percentile samples;
- sample count;
- optional azimuth and vertical estimate;
- capability flags;
- duration.

It wraps this in a `ProximityMeasurement` with the session nonce and both public keys, and signs it. The **spatial proof** is both signed measurements together.

**Verification** (`SpatialProof.verify`), in order:

1. **Participants:** the payer measured the payee, and the payee measured the payer.
2. **Session:** both measurements carry this session's nonce.
3. **Signatures:** both verify (payer's first, then payee's).
4. **Simulated flag:** rejected unless the policy allows it.
5. **Direction:** required only if the policy says so.
6. **Distance:** `max(d_payer, d_payee) ≤ maxDistanceCM`.
7. **Agreement:** `|d_payer − d_payee| ≤ max(toleranceCM, tolerancePercent × max(d))`.

The result is the agreed distance, the mean of both sides, shown as "40 cm apart".

| Policy | `maxDistanceCM` | `toleranceCM` | `tolerancePercent` | `requireDirection` | `allowSimulated` |
|---|---|---|---|---|---|
| `.device` | 100 | 25 | 20 % | no | **no** |
| `.simulator` | 100 | 25 | 20 % | no | yes |

These are starting values; the Phase 3 tape-measure runs set the real ones.

**What it proves:** two specific wallets, in one live session, each signed a statement that the other was within the limit, and the two readings agree. **What it doesn't prove:** where they were, or that neither phone lied. A compromised phone can sign any number, but it can't produce the other phone's signature, and two colluding phones can both lie ([DESIGN §3.3](DESIGN.md#33-non-goals)).

### 7.6 Double-spend evidence

A **`ChainClaim`** is a wallet's own signed statement about one position in its chain:
- **debit claim:** a signed transfer, where the payer states "my entry *n* is this outgoing transfer, after link *L*";
- **credit claim:** a signed receipt, where the payee states "my entry *m* records this incoming transfer, after link *L*".

Every claim lets anyone recompute the owner's link after that entry. The `peers` table keeps the latest claim for each counterparty. `Continuity.check(new, against: last)` classifies the next claim:

| Condition | Verdict | Action |
|---|---|---|
| No record for this peer | `firstContact` | Accept; store the claim |
| `new.seq == last.seq + 1` and `new.prevLink == link(last)` | `contiguous` | Accept; advance |
| `new.seq > last.seq + 1` | `gap(missing:)` | Accept; advance (continuity can't be checked across a gap) |
| `new.seq < last.seq` | `outOfOrder` | Accept without advancing (e.g. a transfer delivered late); not proof of fraud |
| Same sequence, same link | `duplicate` | Idempotent |
| Same sequence, **different link** | **`fork`** | Record evidence; refuse |
| `new.seq == last.seq + 1` but `new.prevLink ≠ link(last)` | **`fork`** | Record evidence; refuse |

**`ForkEvidence(earlier, later)`** is valid when both claims are signed by the same wallet and either share a sequence number with different links, or the later one follows the earlier one by sequence but contradicts its link. Anyone can check it: it needs only the two claims and the owner's public key, with no trusted third party.

**Worked example** (test `aFullRestoreIsCaughtWhenTheCheaterMeetsAnEarlierPayee`):

1. A member with $500 copies the full app state (database and Keychain).
2. They pay the shop $400. The member's debit is at sequence 2, and the shop stores that claim.
3. They restore the copy. On their own phone this is undetectable: the chain verifies and the anchor matches.
4. They pay a café the same $400, also at sequence 2.
5. Back at the shop, the member's next transfer is sequence 3, with `prevLink` = the link after the *café* debit. The shop computes the link after the debit *it* holds, they differ, and `Continuity` returns `fork`.
6. The shop stores both signed claims as evidence and refuses this wallet from then on.

**Planned (P4):** wallets exchange evidence when they meet, so a cheater is flagged beyond the wallets it cheated directly.

### 7.7 Failure handling and atomicity

| Situation | Behaviour |
|---|---|
| Budget, balance, limit or proximity check fails | Thrown before the payer's debit; nothing is written |
| The chain moved during Face ID (actor reentrancy) | `commitDebit` throws `chainMoved`; the signed transfer was never sent and is discarded |
| A crash after the database commit, before the anchor write | Next open: `anchorAdvanced`, repaired automatically |
| The receipt never arrives | The debit stands (funds in flight). The payer can deliver the same signed transfer again; the payee answers idempotently. The payer can't cancel alone, because the payee may already hold it. Transport and UI arrive in P4. |
| Payee-side continuity fails | Only possible for a payer that forked its chain. That payer loses the debit and leaves signed evidence; honest payers can't trigger it. |
| Transaction boundaries | Each append (with its peer update or receipt insert) is one `BEGIN IMMEDIATE … COMMIT`; any error rolls back |

---

## 8. Budget engine

### 8.1 Windows

`BudgetPeriod.window(containing: now, calendar:)` returns a half-open interval `[start, end)` in the user's current calendar and time zone:

| Period | Start | End | Edge cases handled |
|---|---|---|---|
| `monthly(anchorDay)` | The most recent anchor day at 00:00 | Same anchor day next month | Anchor clamped to the month's length (31 → 30 in April, 28/29 in February) |
| `weekly(anchorWeekday)` | The most recent anchor weekday at 00:00 (1 = Sunday … 7 = Saturday) | 7 calendar days later | Calendar arithmetic, so a week across a daylight-saving change is 167 or 169 hours (the 169-hour case is tested) |
| `rolling(days)` | Now minus *N* days | Now + 1 ms | Inclusive of a debit made this millisecond |
| `custom(start, lengthDays)` | The start of the current repeating block | +`lengthDays` | Returns `nil` (budget inactive) before `start` |

### 8.2 Decision order

`BudgetEngine.evaluate` checks, in this order:

1. The amount must be positive.
2. **Balance:** the amount must not exceed the spendable balance (skipped for issuers).
3. **Own per-transfer limit**, then **own daily limit** (debits since local midnight).
4. **Hard caps:** any hard-capped budget pushed over its cap → `blocked(.hardCap)`.
5. **Soft caps:** any budget pushed over its cap → `overBudget` (override needed).
6. **Alerts:** any budget at or past its alert threshold → `alert`.
7. Otherwise `ok`.

Only budgets in the transfer's category and currency are considered. Every verdict carries a `BudgetStatus` for each affected budget (window, spent before, requested, spent after), so the UI can show before → after.

### 8.3 Where it runs

| When | Call | Effect |
|---|---|---|
| While typing in the pay sheet | `WalletStore.evaluate` | Live preview; the button is disabled if blocked |
| Before Face ID | `preparePayment` | Hard stops throw; over-budget needs the user's override |
| Inside the write transaction | `commitDebit` | Re-checked, so concurrent payments can't both slip under a cap |

Spending is never stored. It is `SUM(amount_minor)` over debits in the category and currency within the window, served by the partial index `ledger_debits_by_category`.

---

## 9. Approvals and notifications

### 9.1 Approval flows

| Path | Steps |
|---|---|
| **In-app payment** | Pay sheet → (over budget? "Pay anyway") → Face ID prompt "Pay $25.00 to Demo Shop" → ranging → signatures → debit → receipt |
| **Notification Approve button** (lock screen or banner, long press) | Action `APPROVE` (`.foreground` + `.authenticationRequired`): the phone unlocks, the app opens, and `AppModel` runs the payment with the override already accepted → Face ID → … |
| **Notification tap** | Default action → `.open(requestID)` → approval sheet (amount, category, budget check) → "Approve with Face ID" or "Deny" |
| **Deny button** | Action `DENY` (`.destructive`, handled without opening the app); the request is dropped |

Face ID comes **before** ranging, so one approval covers that side's measurement and transfer signatures. Biometric prompts can't be shown from a background action handler, which is why Approve opens the app.

### 9.2 Notifications

| Category | Actions | Content | Identifier |
|---|---|---|---|
| `BUDGET_ALERT` | — | "Clothing budget alert / $180.00 spent of $200.00 limit." or "Clothing budget exceeded / …" | `budget-<budgetID>-<windowStartMS>-<level>` (level = alert % or 100) |
| `TRANSFER_REQUEST` | `APPROVE`, `DENY` | "Demo Shop payment request / Clothing: $180.00 spent of $200.00 limit. Approve $25.00 transaction?" | `request-<UUID>` |

- **Once per window:** the app also records posted alert keys in `UserDefaults` (`postedBudgetAlerts`), so each level fires at most once per budget per window.
- **Foreground:** `willPresent` returns `[.banner, .list, .sound]`, so alerts show even while the app is open.
- **Cold launch:** an action that arrives before the wallet has opened is queued in `NotificationService.pendingActions` and delivered once the handler is installed.
- **Interruption level:** requests are marked `.timeSensitive`. iOS honours it only once the Time Sensitive Notifications capability is added to the app (not yet).
- **Privacy:** notification text includes amounts and category names. Whether it shows on the lock screen depends on the phone's "Show Previews" setting.
- **Phase 1 limit:** pending requests are held in memory (`AppModel.pendingRequests`) and lost if the app is terminated; P4 persists them in `pending_transfers`.

---

## 10. Application layer

### 10.1 Screens

| Screen | Contents |
|---|---|
| **Home** | Balance (animated digits), integrity badge ("Chain verified" / "Locked"), wallet fingerprint, actions, budgets with coloured progress bars, activity list, pull to refresh, status banners |
| **Pay sheet** | Amount on the decimal pad (parsed with the user's locale), category picker (defaults to Clothing), payee, proximity, live budget check, "Pay with Face ID", over-budget confirmation dialog |
| **Approval sheet** | Requested amount, category, proximity, budget check, "Approve with Face ID", "Deny" |
| **Budget editor** | Existing or new category, limit, period (monthly day / weekly weekday / rolling days / custom start + length), alert % (50–100, step 5), hard cap |
| **Transfer detail** | Amount, counterparty, private category, receipt status; both signed measurements with flags and samples; proof hash; sequence, previous link, link, transfer ID, signature validity |
| **Security** | Signer type, wallet key, Face ID availability, SQLCipher version, file-encryption check (reads the first 16 bytes of the file and compares them with SQLite's plaintext header), backups excluded, integrity, entry count, tip link, "Re-verify chain", proximity policy |

### 10.2 AppModel

`AppModel` (`@Observable`, main actor) holds:
- **Display state:** phase, balance, budget rows, categories, activity rows, integrity, diagnostics, banner, approval request.
- **Private references:** the wallet store, signer and demo peers.

Its actions — `start`, `refresh`, `evaluate`, `pay`, `addDemoFunds`, `simulateIncomingRequest`, `approve`/`deny`, `addCategory`, `saveBudget`, `deleteBudget`, `reverify` — are thin wrappers that call into SecureKit and translate errors into plain sentences (`AppModel.describe`).

### 10.3 Demo peers

`DemoPeer` is a real wallet: its own SQLCipher database, Keychain database key, anchor and software P-256 key.
- **Demo Issuer** is configured with `isIssuer: true` (its balance may go negative) and is pinned by the user's wallet, so its transfers are recorded as mints.
- **Demo Shop** is an ordinary wallet that receives payments.

Both use simulated ranging at 0.40 m. In Phase 4 they are replaced by a second phone, using the same `WalletStore` API on each side.

---

## 11. On-device data map

**Files** (inside the app's sandbox container):

| Path | Contents | Protection |
|---|---|---|
| `Library/Application Support/Wallet/wallet.sqlite` | The user's ledger, budgets, categories, peers, receipts | SQLCipher + Data Protection Complete + excluded from backup |
| `Library/Application Support/Wallet/wallet.sqlite-journal` | Transient rollback journal (exists only during a write) | Same; encrypted pages |
| `Library/Application Support/DemoPeers/demo-issuer.sqlite`, `demo-shop.sqlite` | Demo counterparties' ledgers | Same |
| `Library/Application Support/Connected/connected.sqlite` | Additional features: credit profile, simulated linked accounts and transactions, practice orders, positions and bets ([ADDITIONAL-FEATURES §8](ADDITIONAL-FEATURES.md#8-storage-and-encryption)) | SQLCipher (own key) + Data Protection Complete + excluded from backup |
| `Library/Preferences/com.example.secure.plist` | `UserDefaults`: `postedBudgetAlerts` (budget ID, window start and level only; no amounts); `nearbyDisplayName` (the name shown to nearby phones); `nearbyNames` (wallet fingerprint → name other phones introduced themselves with) | iOS default file protection |

**Keychain** (service `com.example.secure`; every item `WhenUnlockedThisDeviceOnly`):

| Account | Contents | Size |
|---|---|---|
| `wallet.signing-key` | Secure Enclave key blob (phone) / raw P-256 key (Simulator) | Opaque / 32 bytes |
| `wallet.database-key` | SQLCipher raw key | 32 bytes |
| `wallet.chain-anchor` | Chain anchor | 73 bytes |
| `demo-issuer.signing-key`, `.database-key`, `.chain-anchor` | Demo Issuer's secrets | 32 / 32 / 73 bytes |
| `demo-shop.signing-key`, `.database-key`, `.chain-anchor` | Demo Shop's secrets | 32 / 32 / 73 bytes |
| `connected.database-key` | SQLCipher raw key for `connected.sqlite` (additional features) | 32 bytes |

Nothing is written outside the app's container. The only data that leaves the phone is the phone-to-phone protocol, sent directly to a nearby phone while the Nearby screen is open: the `hello` (wallet key, chosen name, discovery token) and, during a payment, the amount, signed measurements, the signed transfer and the receipt. The category never leaves the phone.

---

## 12. Build, test and tooling

### 12.1 Xcode project

`SECURE.xcodeproj` is hand-written in the Xcode 16+ format (`objectVersion = 77`). The `App/` folder is a **file-system synchronized group**: any Swift file added to the folder joins the target automatically, so the project file never lists individual sources. The local package is attached with an `XCLocalSwiftPackageReference` to `Packages/SecureKit`, and the app links the `SecureCore`, `SecureStore`, `SecureDevice` and `SecurePeer` products (`SecureConnect` comes in through `SecureStore`). `INFOPLIST_FILE = Config/Info.plist` adds the keys that can't be expressed as `INFOPLIST_KEY_` settings (the `NSBonjourServices` array). Xcode embeds `SQLCipher.framework` in `SECURE.app/Frameworks` automatically (confirmed in the device build).

| Build setting | Value |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.secure` |
| `INFOPLIST_KEY_CFBundleDisplayName` | `S.E.C.U.R.E` |
| `IPHONEOS_DEPLOYMENT_TARGET` | 26.0 |
| `TARGETED_DEVICE_FAMILY` | 1 (iPhone) |
| `SWIFT_VERSION` | 6.0 (Swift 6 language mode) |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | YES |
| `GENERATE_INFOPLIST_FILE` | YES |
| `INFOPLIST_KEY_NSFaceIDUsageDescription` | "Face ID approves every payment and receipt this wallet signs." |
| `CODE_SIGN_STYLE` | Automatic (no team set yet; Simulator builds need none) |

### 12.2 Swift package

[Package.swift](../Packages/SecureKit/Package.swift) (tools 6.2, platforms iOS 26 / macOS 26) declares:
- five library products (`SecureCore`, `SecureStore`, `SecureDevice`, `SecureConnect`, `SecurePeer`);
- four test targets;
- one dependency, `https://github.com/sqlcipher/SQLCipher.swift.git`, pinned with `exact: "4.19.0"`.

That package is a binary target (`SQLCipher.xcframework.zip`, 50.5 MB, a dynamic framework with iOS, Simulator, macOS, tvOS, watchOS and visionOS slices). Its download is verified against a SHA-256 checksum pinned in the upstream manifest. `Package.resolved` is committed, so every build resolves to the same revision.

### 12.3 Test architecture

144 tests in Swift Testing: 69 for the wallet (below), 20 for phone-to-phone payments (`SecurePeerTests`: success, decline, budget stop before contact, distance rules, release builds rejecting simulated readings, amount mismatch, tampered transfer then re-delivery, lost receipt recovered without double credit, one payment per link, withdrawn offer, closed link; requests approved, declined, stopped by the payer's budget, approved over budget, not pre-approved for a changed amount, withdrawn, one at a time; message encoding) and 55 for the additional features ([ADDITIONAL-FEATURES §10](ADDITIONAL-FEATURES.md#10-tests)). Each suite runs on macOS (`swift test`) and on the iOS Simulator (`xcodebuild test -scheme SecureKit-Package`).

| Suite | Tests | Covers |
|---|---|---|
| Canonical encoding | 5 | Round trips, big-endian layout, truncation, trailing bytes, oversized fields, invalid bools, hex, domain separation |
| Money | 6 (17 cases) | Parsing (valid and invalid inputs), zero-decimal currencies, currency mismatch, overflow, formatting, code validation |
| Hash chain | 10 | Valid chain and balance, genesis binding, changed amount, dropped entry, rewritten link, debit signed by someone else, debit claiming another position, negative balance vs issuer, mismatched proof, link recomputation from public data |
| Budget windows | 7 | Monthly clamping, monthly from day 1, weekly anchor, a daylight-saving week (169 h), rolling, custom blocks / not started, invalid periods |
| Budget engine | 7 | OK, the PRD alert example, soft-cap override, hard cap, balance / per-transfer / daily limits / invalid amount, issuer, other categories |
| Spatial proof | 8 | Accept, too far, disagreement, simulated vs device policy, nonce and participant binding, tampered measurement, round trip, reproducible simulated ranging |
| Transfers and receipts | 4 | Signed round trip, tamper detection, strict decoding, no category in the bytes |
| Continuity | 5 | Honest sequences, same-sequence fork, link-contradiction fork, receipts as claims, invalid evidence |
| Encrypted storage | 5 | Encrypted file header, wrong key, missing key, wrong wallet key, append-only triggers and CHECK constraints |
| Wallet ledger and budgets | 7 | Fresh wallet, mint from issuer + receipt, the PRD budget walkthrough, hard caps and balance, proximity refusal before debit, acceptance limit, idempotent re-delivery |
| Rollback and double-spend | 5 | Restored database locks, missing anchor, reinstall with old key, interrupted-commit repair, full restore caught by the earlier payee |

**Attack staging.** `TestWallet` (in [StoreTestSupport.swift](../Packages/SecureKit/Tests/SecureStoreTests/StoreTestSupport.swift)) wraps a real on-disk SQLCipher wallet with an `InMemorySecretStore`. Tests copy the database file aside (`snapshotDatabase`), restore it (`restoreDatabase`) and snapshot or restore the "Keychain" (`snapshot` / `restore`). That reproduces rollback, reinstall, crash and full-restore attacks without a device.

**Commands**

```bash
cd Packages/SecureKit && swift test
```

```bash
cd Packages/SecureKit && xcodebuild test -scheme SecureKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

```bash
xcodebuild -project SECURE.xcodeproj -scheme SECURE -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData build
```

### 12.4 Simulator Face ID automation

The Simulator's Face ID can be scripted, which made the walkthrough repeatable.

Enroll a face (same as Features ▸ Face ID ▸ Enrolled):

```bash
xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
```

```bash
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.enrollmentChanged
```

Answer a pending Face ID prompt with a matching face:

```bash
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.match
```

Or with a non-matching face, to test refusal:

```bash
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.nomatch
```

### 12.5 Debug vs release

| | Debug / Simulator | Release |
|---|---|---|
| Proximity policy | `.simulator` (accepts simulated measurements, needed until UWB exists) | `.device` (rejects anything flagged simulated) |
| Signer | Simulator: `SimulatorBiometricSigner`; phone: Secure Enclave | Secure Enclave only |
| Optimization | `-Onone`, testability on | Whole-module optimization |

---

## 13. Planned architecture (Phases 3–4)

**Status (2026-10-25):** phone-to-phone payments are built: NearbyInteraction ranging as planned in §13.1, but over a MultipeerConnectivity link instead of the CoreBluetooth design in §13.2 (decision and message flow in [DESIGN §12](DESIGN.md#12-phone-to-phone-payments-v1)). §13.2 is kept as the option for background requests. In-flight re-delivery from §13.3 is built; the rest of §13.3 is still planned. The APIs named here were checked against the iOS 27.1 SDK headers.

### 13.1 UWB ranging with NearbyInteraction

- **Session:** `NISession` with `NINearbyPeerConfiguration(peerToken:)`, using the peer's `NIDiscoveryToken`. The token is `NSSecureCoding`, so it travels as `NSKeyedArchiver` data inside the Bluetooth hello message.
- **Capabilities** (`NISession.deviceCapabilities`, also exposed on the peer's token): `supportsPreciseDistanceMeasurement`, `supportsDirectionMeasurement`, `supportsCameraAssistance`, `supportsExtendedDistanceMeasurement`. These map onto the signed `RangingCapabilities` flags.
- **Options:** `isCameraAssistanceEnabled` (uses ARKit to obtain direction on models whose UWB alone doesn't provide it) and `isExtendedDistanceMeasurementEnabled`.
- **Samples:** `NINearbyObject.distance` (metres) feeds `RangingSummary.summarize` (median and p10–p90 spread). `horizontalAngle` becomes `azimuthCentiDegrees`, and `verticalDirectionEstimate` becomes `vertical`.
- **Adapter:** a `RangingSession` implementation, so `LoopbackPayment` and `WalletStore` don't change.
- **Phase 3 measurements** on a pair of UWB iPhones (ideally different chip generations): error and spread against a tape measure at 0.25, 0.5, 1, 2 and 3 m; time to first fix; direction availability with and without camera assistance. These set the final `ProximityPolicy` values.
- iOS 27 also adds Bluetooth Channel Sounding ranging (`NINearbyAccessoryConfiguration(bluetoothChannelSoundingIdentifier:previousBluetoothIdentifier:)`). It applies only to paired accessories, a possible path for a merchant terminal without UWB, and isn't used phone to phone.

### 13.2 Bluetooth transport with CoreBluetooth

- **Service:** one custom GATT service for discovery and the hello exchange (wallet key, algorithm, `NIDiscoveryToken`, nonce contribution).
- **Message stream:** an L2CAP channel for the protocol messages, each framed as `u32 length ‖ type byte ‖ canonical bytes`. A full transfer is under 1 KB ([§5.8](#58-canonical-binary-encoding)).
- **Background modes:** `bluetooth-central` and `bluetooth-peripheral`, so a request can wake a backgrounded phone and post the payment-request notification.
- **Info.plist additions:** `NSNearbyInteractionUsageDescription`, `NSBluetoothAlwaysUsageDescription`, and `NSCameraUsageDescription` if camera assistance is used.

### 13.3 Protocol completion

- **Built:** in-flight debits are re-delivered from the ledger (debits without a receipt) with `PeerConnection.redeliver`; `pending_transfers` stays unused.
- Fork evidence will be exchanged between wallets when they meet.
- An issuer-mode screen will let one phone mint to others in person.
- **Later options:** a two-key identity (an identity key endorsing a biometry-bound spending key), and ML-DSA-65 signatures in the Secure Enclave (algorithm byte `2`) for post-quantum security.

---

## 14. Security properties and limitations

| Property | Mechanism | Holds against | Caveat |
|---|---|---|---|
| Only the owner can spend | Secure Enclave key, Face ID enforced by hardware | Thieves, malware without a Face ID match | Someone who knows the passcode can enroll a face (iOS root of trust) |
| Ledger confidentiality | SQLCipher + Data Protection + Keychain | Lost or stolen phones, file copies, backups | Decrypted pages are in app memory while it runs |
| Ledger integrity | Hash chain, signatures, triggers, page HMAC | Edits, deletion, reordering | — |
| Rollback detection | Keychain anchor | Restoring an older database alone | Restoring database and Keychain together is undetectable locally |
| Double-spend accountability | Bilateral chain claims, fork evidence | Re-spending after a full restore, once the cheater meets an earlier counterparty | Detection, not prevention. Exposure capped by acceptance limits. |
| Replay protection | Joint session nonce, `UNIQUE(counterparty, nonce)`, transfer IDs | Replayed transfers, measurements or receipts | — |
| Proximity attestation | Mutual signed UWB measurements (simulated now) | One phone faking closeness alone; relays (UWB time of flight, P3) | Two colluding phones; not a location proof |
| Category privacy | Categories excluded from transfers and links | Counterparties learning your budgets | Visible in your own notifications on the lock screen, depending on preview settings |

**Known limitations** are listed in full in [FEATURES.md → Known limitations](FEATURES.md#known-limitations) and [DESIGN §3](DESIGN.md#3-threat-model).

---

## 15. Glossary

| Term | Meaning |
|---|---|
| **Anchor** | The chain tip (sequence + link) stored in the Keychain, used to detect a restored older database |
| **CBC** | Cipher Block Chaining, an AES mode; each block depends on the previous one and a random IV |
| **ChainClaim** | A wallet's signed statement about one position in its own chain (a transfer it sent or a receipt it signed) |
| **CommonCrypto** | Apple's C cryptography library; SQLCipher's crypto provider here |
| **Data Protection class Complete** | iOS file encryption whose key is unavailable while the phone is locked |
| **Discovery token** | `NIDiscoveryToken`; NearbyInteraction's per-session identifier that two phones exchange before ranging |
| **Domain tag** | A string such as `SECURE/transfer/v1` mixed into a hash, so data hashed for one purpose can't be reused for another |
| **ECDSA / P-256** | Elliptic-curve digital signatures on NIST curve P-256 (secp256r1), the curve the Secure Enclave supports |
| **Fork** | Two contradictory signed claims about one chain, proof that a wallet rewrote its history (e.g. a double-spend after a restore) |
| **Genesis** | Entry 0 of a chain; its link commits to the wallet's public key |
| **HMAC** | Keyed hash that authenticates data; SQLCipher uses HMAC-SHA512 per page |
| **IV** | Initialization vector; a fresh random value per encryption so identical pages encrypt differently |
| **Link** | The hash that chains one ledger entry to the previous one |
| **Minor units** | The smallest unit of a currency (cents for USD); all amounts are stored this way |
| **Mint** | A credit from a pinned issuer, creating new money in the offline-cash model |
| **Nonce** | A value used once; here, the 32-byte session ID both phones contribute to |
| **PBKDF2** | Password-based key derivation; SQLCipher uses it only to derive its HMAC key here, because the database key is random |
| **Raw key** | A SQLCipher key given as exact key bytes (`x'…'`) rather than a passphrase, so no key stretching is needed |
| **Secure Enclave** | Apple's on-chip security coprocessor that generates and uses keys it never releases, and performs Face ID matching |
| **Spatial proof** | Both phones' signed distance measurements for one session |
| **STRICT table** | A SQLite table mode that enforces declared column types |
| **UWB** | Ultra-Wideband, a radio technology that measures distance by time of flight with centimetre precision |
| **`WhenUnlockedThisDeviceOnly`** | Keychain accessibility: readable only while the phone is unlocked, never synced or migrated to another device |
