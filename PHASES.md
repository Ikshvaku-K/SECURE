# S.E.C.U.R.E — Phases

Tags: **[infra]** setup and plumbing · **[core]** PRD functionality · **[novel]** the differentiating part (UWB-attested transfers, double-spend evidence)

## Phase 0 — Plan and decisions [infra]
- [x] Project folder, git, PRD saved, design reviewed against the iOS 27.1 SDK
- [x] D1 P-256 in the Secure Enclave · D2 offline cash · D3 core engine first ([DESIGN §9](docs/DESIGN.md#9-decisions))
- [ ] Signing team set in Xcode (only needed for on-device builds)
- [ ] Developer Mode on both test iPhones

## Phase 1 — Core engine on the Simulator [core]
- [x] Xcode project (iOS 26+, Swift 6) and local package `SecureKit`
- [x] SecureCore: money in integer minor units, canonical binary encoding, SHA-256 hash chain, budget engine
- [x] SecureStore: SQLCipher database (random 256-bit key in Keychain, file protection `complete`, excluded from backup), schema v2 migrations, append-only triggers, Keychain chain anchor with a rollback check on open
- [x] Signer protocol: Secure Enclave signer, plus a software signer for the Simulator and tests
- [x] Unit tests: chain verification, tamper and rollback detection, budget windows and decisions, atomic commit (69 tests, macOS and iOS Simulator)
- Done when `xcodebuild test` passes on the iOS Simulator and a demo flow records debits against budgets. **Done 2026-10-24.**

## Phase 2 — Approvals [core] (implemented; device verification pending)
- [x] Secure Enclave key with `.privateKeyUsage` and `.biometryAny`, so the hardware enforces Face ID (written; first device run pending)
- [x] Over-budget warning flow and hard caps
- [x] Notifications: budget alerts (80 % and 100 %) and a transfer-request category with Approve (opens the app) and Deny; tapping the notification opens an approval sheet
- Done when signing is impossible without Face ID on a device, and notification actions route correctly on the Simulator and a device.

## Additional features (simulated) [core add-on]
- [x] `SecureConnect` module and `ConnectedStore` in their own encrypted database; the core transactions model is unchanged
- [x] Credit score (self-reported or demo) with five tiers limiting practice transactions per day and size
- [x] Connected accounts: three fictional banks, history import, sync, net worth and spending dashboard, alerts
- [x] Practice markets: stocks and ETFs, prediction markets, sports, portfolio and a simulated market clock (sports switched off for now, 2026-10-25)
- [x] Strategy guide (27 strategies) and four calculators
- [x] Responsible play: age, daily stake limit, cool-offs, self-exclusion
- [x] 55 tests; Simulator walkthrough of the Accounts, Markets and Profile tabs
- See [docs/ADDITIONAL-FEATURES.md](docs/ADDITIONAL-FEATURES.md).

## Phase 3 — Proximity with two iPhones [novel]
- [x] Link for exchanging discovery tokens: MultipeerConnectivity instead of CoreBluetooth (decision 2026-10-25, [DESIGN §12](docs/DESIGN.md#12-phone-to-phone-payments-v1)); loopback stand-in for two Simulators
- [x] NISession peer ranging, one session per nearby phone; live distance on screen; direction and vertical estimate recorded when available
- [ ] First run on two iPhones
- [ ] Check against a tape measure at 0.25, 0.5, 1, 2 and 3 m: error, spread, time to first fix, and direction availability with and without camera assistance
- Done when a measurement report sets the proof thresholds (distance limit, agreement tolerance).

## Phase 4 — Transfer protocol [novel]
- [x] Joint session nonce, signed measurements, mutual spatial proof (built in Phase 1, now exchanged between phones)
- [x] Transfer and receipt messages over the link (`SecurePeer`), payee "ready" for the exact amount, commit on both sides, in-flight re-delivery with Retry
- [x] 13 tests; two-Simulator walkthrough ($25 paid, receipt countersigned)
- [x] Peer table and double-spend evidence (Phase 1)
- [ ] Evidence exchange between wallets when they meet
- [ ] Payee-initiated requests; issuer mode on a phone
- Done when two phones complete a UWB-verified transfer approved with Face ID, and a staged database rollback is caught.

## Phase 5 — App UI [core]
- [ ] Home, budget editor, send and request with a proximity view, history and chain explorer, settings
- [ ] VoiceOver, Dynamic Type, dark mode

## Phase 6 — Hardening and evaluation [novel / infra]
- [ ] Tamper tests: database rollback, Keychain/database mismatch, replayed nonce, forged or oversized payloads, proof out of range
- [ ] Threat-model write-up with measured numbers
- [ ] Performance: Secure Enclave signing time, ranging time to proof, database commit time

## Phase 7 — Distribution (optional) [infra]
- [ ] TestFlight or the App Store (needs the paid Apple Developer Program)
- [ ] Legal check if tokens stand for real money
