# Product Requirements Document (PRD): Offline Spatial Token Verifier & Personal Finance App

> Original requirements as provided on 2026-10-24, kept verbatim (only the table and list formatting were restored).
> Where iOS doesn't allow something as written, the correction and the reason are in [DESIGN.md](DESIGN.md#2-prd-corrections).

## 1. Executive Overview

A fully self-contained, offline-first iOS application that executes secure cryptographic transactions, enforces local spending and budgeting rules, and utilizes hardware-based spatial verification (distance/direction) without requiring an internet connection or external servers.

## 2. Core Features & Functional Requirements

### Feature 1: Hardware-Backed Offline Key & Security Architecture

- **Local Key Generation:** Generate and manage asymmetric keypairs (Ed25519) stored inside Apple's Secure Enclave.
- **Data-at-Rest Encryption:** Store all local balances, budget rules, transaction histories, and categories inside a SQLCipher database using AES-256-GCM encryption.
- **State-Locking & Tamper Protection:** Bind the balance mutation counter to local hardware-backed storage or a rolling cryptographic hash chain ($T_n = \text{Hash}(T_{n-1} + \text{Data})$) to prevent users from rolling back SQLite database files to restore spent balances.

### Feature 2: Spatial & Distance Verification (No GPS/Cellular Required)

- **Peer-to-Peer Ranging:** Utilize NearbyInteraction and CoreBluetooth with Ultra-Wideband (UWB) chips (Apple U1/U2/U3) to determine relative distance (down to centimeters) and directional angle between interacting iPhones.
- **Spatial Vector Proof:** Construct a challenge-response spatial payload containing relative azimuth, distance verification, sender ID, recipient ID, nonce, and a timestamp.

### Feature 3: Expense Categorization & Offline Budgeting Engine

- **Category Management:** Maintain categorized accounts (e.g., Clothing, Food, Transport) with customizable monthly or rolling spending caps (e.g., $200/month limit for Clothing).
- **Real-Time Balance & Budget Analysis:** Prior to signing any transaction, query local aggregates to verify that the spending limit is not exceeded.
- **Atomic Mutation:** Atomically decrement category caps and overall balance upon transaction approval to guarantee offline consistency.

### Feature 4: Offline Notification & Biometric Verification

- **Local Interactive Alerts:** Trigger native iOS banners via UserNotifications when a transaction approaches or hits budget limits (e.g., "Clothing Budget Alert: $180 spent of $200 limit. Approve $25 transaction?").
- **Interactive Lock-Screen Actions:** Provide Approve and Deny action buttons embedded directly within notification banners.
- **Biometric Approval:** Require Face ID / Touch ID via LocalAuthentication (LAContext) before signing and committing any transaction payload.

## 3. Technology Stack & Frameworks

| Subsystem | iOS Native Technology / Framework | Function |
|---|---|---|
| Language & Core | Swift 5+ / SwiftUI | Modern UI and async/await task handling |
| Database Encryption | SQLCipher for Swift | Encrypted SQLite database for offline storage |
| Cryptography | Apple CryptoKit & Secure Enclave | Ed25519 payload signing and key encapsulation |
| Biometric Auth | LocalAuthentication | Enforces Face ID / Touch ID verification |
| Notifications | UserNotifications | Schedules and displays offline local alerts and actionable UI |
| Spatial / Ranging | NearbyInteraction & CoreBluetooth | Peer-to-peer UWB distance and direction ranging |

## 4. Local Database Schema Design

```sql
CREATE TABLE Categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    icon_name TEXT
);

CREATE TABLE Budgets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id INTEGER,
    limit_amount DECIMAL(10,2) NOT NULL,
    period TEXT CHECK(period IN ('Monthly', 'Weekly', 'Custom')),
    FOREIGN KEY(category_id) REFERENCES Categories(id)
);

CREATE TABLE Transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_pubkey TEXT NOT NULL,
    recipient_pubkey TEXT NOT NULL,
    category_id INTEGER,
    amount DECIMAL(10,2) NOT NULL,
    spatial_proof_hash TEXT NOT NULL,
    nonce INTEGER UNIQUE NOT NULL,
    previous_tx_hash TEXT NOT NULL,
    current_tx_hash TEXT UNIQUE NOT NULL,
    status TEXT CHECK(status IN ('Pending', 'Approved', 'Rejected')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(category_id) REFERENCES Categories(id)
);
```

## 5. Execution & Transaction Flow

1. **Initiation:** Device A initiates a transfer specifying Amount and Category (e.g., $25 for Clothing).
2. **Budget Verification:** App queries Budgets and Transactions tables locally.
   - If Spent + Requested > Budget Limit, present an Over-Budget Warning prompt.
3. **Spatial Verification:** App scans local UWB/BLE signals to obtain spatial relative vector proofs.
4. **Local Alert & Biometric Prompt:** Trigger UserNotifications banner with interactive actions. Upon tapping "Approve", invoke LAContext for Face ID verification.
5. **Cryptographic Signing:** Secure Enclave signs the payload containing [Sender, Recipient, Amount, Category, SpatialProof, Nonce, PrevTxHash].
6. **State Mutation:** Atomically update remaining budget and insert the new transaction into the immutable local chain in SQLCipher.
