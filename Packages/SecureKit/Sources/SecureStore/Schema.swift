import Foundation

/// Ordered migrations; `PRAGMA user_version` records how many have run.
enum Schema {
    static let migrations: [String] = [v1]

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = Int(try db.userVersion)
        guard current < migrations.count else { return }
        try db.transaction {
            for index in current..<migrations.count {
                try db.execute(migrations[index])
            }
            try db.execute("PRAGMA user_version = \(migrations.count);")
        }
    }

    /// Schema v2 from docs/DESIGN.md §5. STRICT tables enforce column types, so money can't
    /// silently become floating point.
    static let v1 = """
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
    """
}
