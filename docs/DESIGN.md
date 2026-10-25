# S.E.C.U.R.E: Design and PRD Review

Draft v0.3 · 2026-10-24 · decisions D1–D3 made (§9): P-256 in the Secure Enclave, offline cash, core engine first · §5–6 updated to match the Phase 1 code
Checked against Xcode 27.1 (27A9275), the iOS 27.1 SDK and Swift 6.4.
Additional features (credit tiers, connected accounts, practice markets, strategies) are covered in §11 and [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md).
Phone-to-phone payments (built 2026-10-25) are covered in §12.

## 1. Summary

Most of the [PRD](PRD.md) maps directly onto iOS. SQLCipher storage, CryptoKit signing in the Secure Enclave, Face ID, local notifications and UWB ranging through NearbyInteraction all work without a network. Four things don't work as written:

1. **Ed25519 can't be stored in the Secure Enclave.** The Secure Enclave can only sign with P-256 and, from iOS 26, ML-DSA. See D1.
2. **A hash chain on the phone can't stop rollback by itself.** It catches edits and gaps. But an older copy of the database and Keychain that is consistent in itself still forms a valid, shorter chain. iOS also gives apps no hardware monotonic counter. Offline, double-spending can be made hard, provable and bounded, but not impossible. See D2.
3. **The spatial proof shows that both phones agreed they were close, not where they were.** Each phone's OS reports the distance to the app, and a compromised phone can sign any number. Requiring both phones to sign matching measurements turns it into a mutual claim of proximity.
4. **A Face ID check done only with `LAContext` can be skipped** by a patched app. If the signing key itself requires biometry, the Secure Enclave refuses to sign without a Face ID match.

Smaller fixes: store money as integer cents, scope nonces to each sender, keep pending transfers out of the immutable chain, compute budget spending from the ledger instead of changing the caps, and keep categories private.

## 2. PRD corrections

| # | PRD | What iOS actually does | Change |
|---|---|---|---|
| 1 | Ed25519 keys stored in the Secure Enclave | `CryptoKit.SecureEnclave` offers `P256.Signing`, `P256.KeyAgreement`, and from iOS 26 `MLDSA65/87` and `MLKEM768/1024`. Curve25519 exists only as a software key. | Secure Enclave P-256 ECDSA (recommended) or ML-DSA-65. Put an algorithm ID in every payload (D1). |
| 2 | SQLCipher with AES-256-GCM | SQLCipher 4 encrypts each page with AES-256-CBC and authenticates it with HMAC-SHA512. That is authenticated encryption, but not GCM. | Keep SQLCipher. Use a random 256-bit raw key kept in the Keychain (`WhenUnlockedThisDeviceOnly`), file protection `complete`, and exclude the database from backups. Fix the PRD wording. |
| 3 | A hash chain prevents rolling the database back | It detects edits and gaps, not a full rollback to an older consistent state. iOS has no monotonic counter that apps can use. | Layered defence (§3.2) and a value model (D2). |
| 4 | `LAContext` check before signing | The check is ordinary app code. | Create the Secure Enclave key with `SecAccessControl [.privateKeyUsage, .biometryAny]`. `LAContext` only sets the prompt text. |
| 5 | Approve/Deny on a lock-screen banner, then Face ID | An action handler running in the background can't show the biometric prompt. | Approve is a `.foreground` action: the app opens and signing prompts for Face ID. Deny runs in the background (§8). |
| 6 | Azimuth in every proof | Direction depends on the hardware. Apps must check `deviceCapabilities.supportsDirectionMeasurement`, and some models need camera assistance (ARKit) to get it. The Simulator has no UWB. | Distance is required; direction is optional and comes with capability flags. Measure on two UWB iPhones in Phase 3. |
| 7 | Spatial proof as a security guarantee | Each phone's OS reports its own measurement. | Mutual proof: both phones sign their own measurement of a shared nonce (§6). |
| 8 | `DECIMAL(10,2)` | SQLite has no decimal type, so amounts can end up stored as floating point. | `INTEGER` minor units plus a currency code. |
| 9 | `nonce INTEGER UNIQUE` | Two different senders can use the same nonce, which collides in the recipient's table. | 32-byte joint session nonce with `UNIQUE(counterparty_key, session_nonce)`. |
| 10 | `status` Pending/Approved/Rejected inside the immutable chain | Updating the status changes the row's hash. | Pending transfers live in a separate, editable table. Only committed events enter the chain. |
| 11 | Atomically decrement category caps | Caps that keep changing drift and lose the limit the user set. | Caps never change. Spent = sum of ledger debits in the window. Check, append and anchor in one `BEGIN IMMEDIATE` transaction. |
| 12 | Category in the signed payload | It tells every counterparty how you budget. | Category is a local note, hashed into your own chain only. |
| 13 | "Overall balance" | No table stores it. | Computed from the chain (credits − debits). |
| 14 | Ordering by `CURRENT_TIMESTAMP` | The user can set the clock while offline. | Order by chain sequence. Timestamps are informational, and clock jumps backwards are flagged. |
| 15 | Monthly / Weekly / Custom (and "rolling" in Feature 3) | Custom and rolling periods have no window definition. | `period`, `anchor_date`, `length_days` (§7). |

## 3. Threat model

### 3.1 What it protects against

| Adversary | Protection |
|---|---|
| Thief with a locked phone | The database can't be read: file protection plus a SQLCipher key that the Keychain releases only while the phone is unlocked. Keys never leave the Secure Enclave. |
| Thief with an unlocked phone | Every signature needs a Face ID match enforced by the Secure Enclave, with no passcode fallback. |
| Counterparty replaying an old transfer | Joint session nonce, `UNIQUE(counterparty, nonce)` and sequence checks. |
| Attacker relaying radio signals to fake "nearby" | UWB time-of-flight ranging is much harder to shorten than Bluetooth signal strength, and both phones must agree. |
| App bug rewriting history | Append-only triggers, and the hash chain is verified each time the wallet opens. |
| Owner editing or partly restoring the database | Chain verification plus a Keychain anchor mismatch locks the wallet. |

Key policy: `.biometryCurrentSet` would also destroy the key whenever a face is enrolled, and because keys can't leave the phone, the balance would go with it. v1 therefore uses `.biometryAny`. The upgrade path is two keys: a passcode-or-Face-ID identity key that endorses a biometry-bound spending key, and re-endorses a new one after biometric changes.

### 3.2 Rollback and double-spending: the honest limits

If the owner controls the phone and there is no server, nothing stops a determined owner from restoring a complete old copy of the app state and spending the same balance again (for example by restoring an encrypted backup to the same phone, or with a jailbreak). The design does three things:

1. **Make it hard.** The database is excluded from backups. The chain tip `(seq, hash)` is anchored in the Keychain (`ThisDeviceOnly`) and cross-checked each time the wallet opens. A database behind the anchor locks the wallet read-only.
2. **Make it provable.** Every transfer carries the payer's sequence number and previous chain hash, signed with the Secure Enclave key. Two different signed transfers with the same sequence number prove a double-spend. Each wallet remembers the last `(seq, head)` it saw from every peer and can swap that evidence with other wallets (bilateral chains, as in TrustChain).
3. **Limit the loss.** Per-transfer and per-day offline limits.

Losing the phone means losing the balance, because keys are tied to the device, unless the value model includes an issuer and server (D2, option C).

### 3.3 Non-goals

Proving absolute location; anonymity; stopping two parties who both lie about being close.

## 4. Architecture

```
App (SwiftUI)          Home · Budgets · Send/Request · Proximity · History · Settings
   │
Coordinators           TransferCoordinator (protocol state machine) · BudgetEngine · Approvals
   │
Ports (protocols)      LedgerStore         Signer                  RangingSession        PeerLink
   │
Device adapters        SQLCipher DB        Secure Enclave P-256    NISession (UWB)       CoreBluetooth
                       + Keychain anchor   + Face ID
Simulator/test         SQLCipher DB        SoftwareSigner          SimulatedRanging      LoopbackLink
adapters
```

Layout:

```
secure/
├─ SECURE.xcodeproj             app project (iOS 26+, Swift 6)
├─ App/                          SwiftUI app target
├─ Packages/SecureKit/
│  ├─ Sources/SecureCore/        money, canonical encoding, hash chain, protocol messages, budget engine (pure Swift, runs on macOS)
│  ├─ Sources/SecureStore/       SQLCipher persistence, migrations, Keychain key and anchor
│  ├─ Sources/SecureDevice/      Secure Enclave signer, LocalAuthentication, notifications, NearbyInteraction, CoreBluetooth
│  └─ Tests/
└─ docs/
```

What can be tested where:

| Capability | Simulator | iPhone |
|---|---|---|
| Ledger, budgets, SQLCipher | yes | yes |
| Face ID prompt (`LAContext`) | simulated (Features ▸ Face ID) | yes |
| Secure Enclave keys | no, uses `SoftwareSigner` | yes |
| Local notifications and actions | yes | yes |
| Bluetooth link | no, uses `LoopbackLink` | yes |
| UWB ranging | no, uses `SimulatedRanging` | yes, needs two UWB iPhones |

Transport: CoreBluetooth (GATT for small messages, L2CAP for larger ones). MultipeerConnectivity is simpler but can't wake an app in the background, and the incoming-request notification (§8) needs that.

## 5. Data model v2

As built in `Packages/SecureKit/Sources/SecureStore/Schema.swift`, which is the source of truth. All tables are `STRICT`, so a money column can't silently hold a float.

```sql
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value BLOB NOT NULL
) STRICT;

CREATE TABLE categories (
    id        INTEGER PRIMARY KEY,
    name      TEXT NOT NULL UNIQUE,
    icon_name TEXT,
    archived  INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
) STRICT;

CREATE TABLE budgets (
    id          INTEGER PRIMARY KEY,
    category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    cap_minor   INTEGER NOT NULL CHECK (cap_minor >= 0),
    currency    TEXT    NOT NULL DEFAULT 'USD',
    period      TEXT    NOT NULL CHECK (period IN ('monthly', 'weekly', 'rolling', 'custom')),
    anchor      INTEGER,
    start_date  TEXT,
    length_days INTEGER,
    alert_pct   INTEGER NOT NULL DEFAULT 80 CHECK (alert_pct BETWEEN 1 AND 100),
    hard_cap    INTEGER NOT NULL DEFAULT 0 CHECK (hard_cap IN (0, 1)),
    CHECK (
        (period = 'monthly' AND anchor BETWEEN 1 AND 31) OR
        (period = 'weekly'  AND anchor BETWEEN 1 AND 7) OR
        (period = 'rolling' AND length_days > 0) OR
        (period = 'custom'  AND start_date IS NOT NULL AND length_days > 0)
    )
) STRICT;

CREATE TABLE ledger (
    seq                INTEGER PRIMARY KEY CHECK (seq >= 0),
    kind               TEXT    NOT NULL CHECK (kind IN ('genesis', 'mint', 'debit', 'credit')),
    counterparty_key   BLOB,
    amount_minor       INTEGER NOT NULL CHECK (amount_minor >= 0),
    currency           TEXT    NOT NULL,
    category_id        INTEGER REFERENCES categories(id),
    session_nonce      BLOB,
    transfer_id        BLOB UNIQUE,
    transfer           BLOB,
    spatial_proof      BLOB,
    spatial_proof_hash BLOB,
    created_at_ms      INTEGER NOT NULL,
    prev_link          BLOB    NOT NULL,
    link               BLOB    NOT NULL UNIQUE,
    UNIQUE (counterparty_key, session_nonce)
) STRICT;

CREATE INDEX ledger_debits_by_category ON ledger (category_id, created_at_ms) WHERE kind = 'debit';
CREATE INDEX ledger_by_time ON ledger (created_at_ms);

CREATE TRIGGER ledger_no_update BEFORE UPDATE ON ledger
BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;

CREATE TRIGGER ledger_no_delete BEFORE DELETE ON ledger
BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;

CREATE TRIGGER ledger_append_in_order BEFORE INSERT ON ledger
WHEN NEW.seq <> COALESCE((SELECT MAX(seq) FROM ledger) + 1, 0)
BEGIN SELECT RAISE(ABORT, 'ledger sequence must grow by exactly one'); END;

CREATE TABLE receipts (
    entry_link     BLOB PRIMARY KEY REFERENCES ledger(link),
    receipt        BLOB    NOT NULL,
    received_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE pending_transfers (
    session_nonce    BLOB PRIMARY KEY,
    role             TEXT    NOT NULL CHECK (role IN ('payer', 'payee')),
    counterparty_key BLOB    NOT NULL,
    amount_minor     INTEGER NOT NULL CHECK (amount_minor > 0),
    currency         TEXT    NOT NULL,
    category_id      INTEGER REFERENCES categories(id),
    state            TEXT    NOT NULL CHECK (state IN ('requested', 'ranging', 'ready', 'awaiting_approval', 'denied', 'expired')),
    created_at_ms    INTEGER NOT NULL,
    updated_at_ms    INTEGER NOT NULL
) STRICT;

CREATE TABLE peers (
    public_key    BLOB PRIMARY KEY,
    display_name  TEXT,
    last_claim    BLOB    NOT NULL,
    last_seq      INTEGER NOT NULL,
    first_seen_ms INTEGER NOT NULL,
    updated_ms    INTEGER NOT NULL,
    fork_evidence BLOB
) STRICT;

```

**Chain links cover only public data.** `link = SHA-256("SECURE/link/v1" ‖ prev_link ‖ seq ‖ direction ‖ transfer_id)`, where direction is genesis, outgoing or incoming, and the genesis link commits to the wallet's public key. A counterparty holding a signed transfer or receipt can therefore recompute the other wallet's link at that position (`ChainLink.afterDebit` / `afterCredit`). That is what makes double-spend evidence checkable by anyone. Local notes (category, mint vs credit) stay out of the link. SQLCipher's per-page HMAC already stops anyone without the key from editing them.

- `transfer` holds the canonical bytes of the signed transfer, signature included. `transfer_id` hashes only the unsigned fields, so ECDSA signature malleability can't give one transfer two IDs.
- Receipts arrive after the debit is committed and prove themselves, so they live outside the chain in `receipts`.
- Spending is computed, never stored: `SUM(amount_minor)` over `kind = 'debit'` rows for the category inside the budget window. Balance is the sum of credits and mints minus debits.

## 6. Transfer protocol (v1)

```
Payer A                                          Payee B
  │── BLE  Hello{key_A, alg, ni_token_A, n_A} ────►│
  │◄─ BLE  Hello{key_B, alg, ni_token_B, n_B} ─────│
  │   session_nonce = SHA-256("SECURE/session/v1" ‖ n_A ‖ n_B)
  │── Offer{amount, currency, session_nonce} ─────►│   (or B starts with a Request)
  │◄═════════ UWB ranging, NISession ~1–2 s ══════►│
  │── Measurement_A + sig_A ──────────────────────►│
  │◄─ Measurement_B + sig_B ───────────────────────│   both check the proof
  │◄─ Ready (B accepts proof, amount, limits) ─────│
  │   budget check → over-budget warning if needed → Face ID → Secure Enclave signs
  │   append debit to own chain, update anchor     │
  │── Transfer + sig_A ───────────────────────────►│   verify, fork check, append credit, anchor
  │◄─ Receipt + sig_B ─────────────────────────────│
  │   store receipt                                │
```

Messages use a canonical binary encoding: version byte, fixed field order, length-prefixed fields. Hashes are SHA-256 with a domain tag.

- **Measurement:** `v, session_nonce, observer_key, subject_key, distance_cm` (median), `spread_cm, samples, azimuth_cdeg?, vertical_estimate?, capability_flags, duration_ms`. Signed by the observer.
- **SpatialProof:** `Measurement_A ‖ sig_A ‖ Measurement_B ‖ sig_B`, with `spatial_proof_hash = SHA-256("SECURE/proof/v1" ‖ proof)`.
- **Transfer:** `v, alg, payer_key, payee_key, amount_minor, currency, session_nonce, payer_seq, payer_prev_hash, spatial_proof_hash, created_at`. Signed by the payer in the Secure Enclave after Face ID.
- **Receipt:** `v, transfer_hash, payee_seq, payee_prev_hash, created_at`. Signed by the payee.

The payee accepts a transfer only if:

1. The signatures are valid and the algorithm is allowed.
2. `session_nonce` belongs to this live session and is new for this payer.
3. The proof holds: both signatures check out, the keys match the payer and payee, `max(d_A, d_B) ≤ limit`, and `|d_A − d_B| ≤ tolerance`. Starting values are 1.0 m and max(25 cm, 20 %); Phase 3 measurements set the real ones.
4. The fork check passes: `payer_seq` is above the last sequence seen from this payer, and if it is exactly one above, `payer_prev_hash` equals the last head seen. The same sequence with a different hash is double-spend evidence: reject it, flag the peer, keep both transfers.
5. For offline cash: the amount is within the offline limits.

**One Face ID approval per side.** Each side approves once (`TransactionSigner.authorize`). That opens a signing session of at most 60 s, which signs that side's measurement plus the transfer (payer) or the receipt (payee) without prompting again. On a phone, the session is an `LAContext` already evaluated against the Secure Enclave key's access control.

**When continuity is checked.** The payee's preflight refuses wallets it already holds fork evidence for. The full continuity check needs the signed transfer, so it runs after the payer's debit. An honest payer can never fail it. A payer who restored an old copy and comes back to an earlier payee loses that debit and leaves signed evidence of the fork behind.

If a step fails: the payer debits at signing, so the same funds can't be signed twice. If the receipt never arrives, the transfer stays in flight. The payer can deliver the same signed transfer again later (the nonce makes this idempotent), but can't cancel it alone, because the payee may already hold it. B sends `Ready` before A signs, so a valid transfer can't be rejected after the debit.

## 7. Budget engine

- **Windows** (in the user's current time zone):
  - monthly: from the anchor day to the same day next month, clamped to the month's length;
  - weekly: from the most recent anchor weekday, 7 days long;
  - rolling: the last `length_days` days;
  - custom: repeating `length_days` blocks starting at `anchor_date`.
- **Decision** for a debit of `x` in category `c`, checked for every budget on `c`:
  - `spent + x > cap` with `hard_cap`: block.
  - `spent + x > cap`: over-budget warning; going ahead needs an explicit override plus Face ID.
  - `spent + x ≥ alert_pct % of cap`: proceed, then alert.
  - For offline cash, also block if `x` is more than the available balance.
- The check runs once before signing, then again inside the write transaction that appends the debit. Two transfers at the same moment therefore can't both slip under a cap.

## 8. Approvals

- **App in the foreground:** the over-budget sheet, then "Approve", then the Secure Enclave signs. The Face ID prompt shows the amount, the payee and the category status, for example "$25.00 to Alex · Clothing $205 of $200".
- **Request while the app is in the background:** a Bluetooth request wakes the app, which posts a notification such as "Alex requests $25.00 · Clothing $180 of $200". Approve is a `.foreground` action that opens the app. Deny is a `.destructive` action handled in the background. Ranging and Face ID happen after the app opens, because UWB peer sessions need the app in the foreground.
- **Budget alerts:** at `alert_pct` and at 100 % of each budget, sent once per window.

## 9. Decisions

Decided 2026-10-24: **D1 = P-256 ECDSA in the Secure Enclave · D2 = A, offline cash · D3 = core engine first.**

**D1 — Signing key** (Ed25519 can't be stored in the Secure Enclave)

| Option | Public key / signature | Notes |
|---|---|---|
| **P-256 ECDSA in the Secure Enclave** (recommended) | 65 B / 64 B | Key never leaves the hardware, fast, verifiable everywhere |
| ML-DSA-65 in the Secure Enclave | 1,952 B / 3,309 B | Post-quantum and in hardware, but iOS 26+ only and larger Bluetooth messages |
| Ed25519 in software (Keychain) | 32 B / 64 B | The PRD's algorithm, but the key sits in app memory while signing |

**D2 — What a transfer moves**

| Option | Meaning | Guarantees | Fits the PRD |
|---|---|---|---|
| **A. Offline cash** (recommended) | Balances are spendable value, minted in person by an issuer key you control (for example a group treasurer's phone) | Double-spending is made hard, provable and limited, but not prevented. A lost phone loses its balance. | Yes, fully offline |
| B. Signed IOUs | Each transfer is a co-signed debt between two people, settled outside the app | No double-spend problem: the signed record is the claim | Offline, but less like money |
| C. Issuer with online sync | Like A, but phones reconcile with a server whenever they get a connection | Double-spends are caught at the next sync, and balances can be recovered | Breaks "no servers" |

**D3 — What to build first:** the core engine on the Simulator (recommended), a two-iPhone UWB spike, or nothing until the docs are reviewed.

Defaults chosen unless you say otherwise: iOS 26.0 deployment target, Swift 6 language mode, SwiftUI with Observation, SQLCipher 4.19.0 through Swift Package Manager, and a CoreBluetooth transport.

Still open, not blocking: what S.E.C.U.R.E stands for, and the bundle identifier.

## 10. Platform notes

- **Info.plist** ([Config/Info.plist](../Config/Info.plist), merged with the generated keys): `NSFaceIDUsageDescription`, `NSNearbyInteractionUsageDescription`, `NSLocalNetworkUsageDescription`, and `NSBonjourServices` (`_secure-pay._tcp`, `_secure-pay._udp`) for MultipeerConnectivity. No background modes: phone-to-phone UWB ranging only runs in the foreground, so both people keep the Nearby screen open.
- **On-device builds:** sign in to Xcode ▸ Settings ▸ Accounts with an Apple ID. A free Personal Team works, but its profiles expire after 7 days. TestFlight needs the paid Apple Developer Program. Turn on Developer Mode on each iPhone under Settings ▸ Privacy & Security.
- **iOS 27** adds Bluetooth Channel Sounding ranging to NearbyInteraction, but only through `NINearbyAccessoryConfiguration` (paired accessories). It could suit a merchant terminal without UWB later; it doesn't work phone to phone.
- **Regulation:** if tokens stand for real money, money-transmission and e-money rules may apply. Option B, and option A used as closed-loop community credit, avoid that. Get a legal check before any public release.

## 11. Additional features

Added after the PRD: credit-score access tiers, connected bank accounts in one dashboard, practice markets (stocks and ETFs, prediction markets, sports) and a strategy guide. Decisions taken for them:

| Question | Decision | Why |
|---|---|---|
| Real or simulated? | Fully simulated: fictional banks and instruments, practice money | Real bank data, brokerage and betting need servers, licences and identity checks, which conflict with an offline app and need legal review |
| Which markets? | Prediction markets, stocks and ETFs, sports | One of each kind of pricing: event contracts (cents), continuous prices (bid/ask), bookmaker odds (moneyline with margin) |
| Credit score source | Self-reported or a demo persona, always shown as unverified | No credit bureau is contacted; nothing leaves the phone |
| What the tier limits | Practice-market transactions per day and the largest single transaction | **The core transactions model is unchanged.** Wallet transfers, budgets, approvals and the ledger never read the credit score |
| Where the data lives | A separate SQLCipher database (`connected.sqlite`) with its own Keychain key | The wallet ledger stays append-only and hash-chained; the connected data is mutable and simulated, so it shouldn't share the ledger's integrity rules |
| Safeguards | Age confirmation (18+, 21+ for sports), daily stake limit, cool-offs and self-exclusion that can't be shortened | Practice should model safe habits, and the same controls would be required for real money |

The full design is in [ADDITIONAL-FEATURES.md](ADDITIONAL-FEATURES.md) and the strategies in [STRATEGIES.md](STRATEGIES.md).

## 12. Phone-to-phone payments (v1)

Built 2026-10-25. The §6 protocol now runs with each side on its own phone. Nothing in the wallet changed: the new `SecurePeer` module calls only `WalletStore`'s public steps, the same ones `LoopbackPayment` uses.

**Decision: MultipeerConnectivity instead of raw CoreBluetooth** (user decision, 2026-10-25). Reasons:
- Phone-to-phone NearbyInteraction ranging only works with both apps in the foreground, so CoreBluetooth's background wake-up wouldn't help a payment.
- MultipeerConnectivity finds peers and keeps encrypted, reliable sessions over Bluetooth and peer-to-peer Wi-Fi with no internet, in far less code. Apple's own NearbyInteraction sample uses it to exchange discovery tokens.
- The link is untrusted either way: every message that matters is signed.

Two Simulators on one Mac can't complete a MultipeerConnectivity session, so Simulator builds use a loopback TCP stand-in with the same interface. It is compiled out of device builds.

**Messages** (`PeerMessage`, canonical encoding, version 1):

| # | From → to | Message | Contents and checks |
|---|---|---|---|
| 0 | both | `hello` | Wallet key, self-chosen name (unverified), NearbyInteraction discovery token for this link |
| 1 | payer → payee | `offer` | Offer ID, both keys, amount, payer's nonce contribution. Sent only after the payer's budget and balance check. |
| 2 | payee → payer | `reply` | Payee's nonce contribution if the user accepted **and** passed Face ID; otherwise declined |
| 3 | both | `measurement` | Each phone's signed UWB summary for the joint nonce. The receiver checks nonce, observer, subject and signature. |
| 4 | payee → payer | `ready` | After `preflightIncoming` passes: proof, acceptance limits, payer record. **Repeats the agreed amount**; the payer won't commit if it differs. |
| 5 | payer → payee | `transfer` | After the payer verifies the proof itself and commits its debit. The payee checks that the proof and amount match before `acceptTransfer`. |
| 6 | payee → payer | `receipt` | Countersigned receipt; the payer stores it. |
| — | either | `failure` | Code and plain-language reason, so both screens agree on why it stopped |

**Money safety:**
- Every refusal (budget, balance, limits, distance, disagreement, simulated reading on a release build, mismatched amount) happens before the payer's debit.
- After the debit, a lost link leaves an *unconfirmed* payment, never a lost one. It stays in the payer's ledger without a receipt and is re-sent with **Retry**. The proof already contains the payee's own signed measurement from that session, so the payee only confirms with Face ID and countersigns. `acceptTransfer` is idempotent, so a re-delivery never credits twice.
- One payment at a time per link. Decisions time out after 90 s; if the payer gives up, it withdraws the offer and the payee's prompt closes.

**Face ID timing.** The payee approves when accepting, before contributing to the nonce. The payer approves right after the reply. From then on every step runs at machine speed, well inside the 60-second signing session.

**Open points** (for the hardening phase):
- Bind the UWB reading to the wallet key. Today a phone measures the device holding the discovery token it was handed.
- Requests initiated by the payee.
- Fork-evidence exchange when phones meet.
- Final distance thresholds from tape-measure runs on two iPhones.
