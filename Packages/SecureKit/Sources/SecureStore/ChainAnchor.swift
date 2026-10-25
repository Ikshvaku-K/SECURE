import Foundation
import SecureCore

/// The chain tip remembered outside the database, in the Keychain (`ThisDeviceOnly`).
/// Restoring an older database without also restoring this item is caught on the next open.
struct ChainAnchor: Equatable {
    /// Binds the anchor to one wallet identity, so a stale anchor from a previous install isn't mistaken for this one.
    let genesisLink: Digest32
    let tip: ChainTip

    var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(1)
        w.writeDigest(genesisLink)
        w.writeI64(tip.seq)
        w.writeDigest(tip.link)
        return w.data
    }

    static func read(_ secrets: any SecretStore, account: String) throws -> ChainAnchor? {
        guard let data = try secrets.read(account) else { return nil }
        var r = CanonicalReader(data)
        guard (try? r.readU8()) == 1,
              let genesis = try? r.readDigest(),
              let seq = try? r.readI64(),
              let link = try? r.readDigest(),
              (try? r.finish()) != nil
        else { return nil }
        return ChainAnchor(genesisLink: genesis, tip: ChainTip(seq: seq, link: link))
    }

    func write(_ secrets: any SecretStore, account: String) throws {
        try secrets.write(canonicalBytes, account: account)
    }

    /// Compares a verified chain with the anchor.
    static func evaluate(anchor: ChainAnchor?, entries: [LedgerEntry], genesisLink: Digest32, created: Bool) -> IntegrityStatus {
        guard let tip = entries.last else { return .chainInvalid(.empty) }
        guard let anchor, anchor.genesisLink == genesisLink else {
            // No anchor for this identity: expected for a wallet created just now, suspicious for one with history.
            return created ? .verified : .anchorMissing
        }
        if anchor.tip.seq > tip.seq {
            return .rolledBack(anchorSeq: anchor.tip.seq, databaseSeq: tip.seq)
        }
        guard anchor.tip.seq >= 0, entries.indices.contains(Int(anchor.tip.seq)),
              entries[Int(anchor.tip.seq)].link == anchor.tip.link
        else { return .diverged(atSeq: anchor.tip.seq) }
        return anchor.tip.seq == tip.seq ? .verified : .anchorAdvanced(from: anchor.tip.seq, to: tip.seq)
    }
}

public enum WalletLocation {
    /// `Application Support/<folder>`, with complete file protection on iOS and excluded from backups.
    /// Keeping the database out of backups means restoring a backup can't bring back spent balances.
    public static func directory(named folder: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var url = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func protectFile(at url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
