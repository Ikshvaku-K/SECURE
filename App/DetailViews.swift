import SecureCore
import SecureStore
import SwiftUI

struct EntryDetailView: View {
    let row: ActivityRow

    var body: some View {
        let entry = row.entry
        List {
            Section("Transfer") {
                LabeledContent("Amount", value: entry.amount.formatted())
                LabeledContent(entry.kind == .debit ? "To" : "From", value: row.title)
                LabeledContent("Kind", value: entry.kind.rawValue.capitalized)
                if let category = row.categoryName { LabeledContent("Category (private)", value: category) }
                LabeledContent("Time", value: entry.createdAt.formatted(date: .abbreviated, time: .standard))
                if entry.kind == .debit {
                    LabeledContent("Receipt", value: row.hasReceipt ? "Countersigned" : "Not yet received")
                }
            }
            if let proof = entry.spatialProof {
                Section {
                    MeasurementRow(title: "Payer measured", measurement: proof.payerSide.measurement)
                    MeasurementRow(title: "Payee measured", measurement: proof.payeeSide.measurement)
                    LabeledContent("Proof hash") { Text(proof.hash.short).font(.caption.monospaced()) }
                } header: {
                    Text("Spatial proof")
                } footer: {
                    Text("Each phone signs its own distance reading for this session; a transfer is accepted only if both are close and agree.")
                }
            }
            Section("Chain") {
                LabeledContent("Sequence", value: "\(entry.seq)")
                LabeledContent("Previous link") { Text(entry.prevLink.short).font(.caption.monospaced()) }
                LabeledContent("Link") { Text(entry.link.short).font(.caption.monospaced()) }
                if let transfer = entry.transfer {
                    LabeledContent("Transfer ID") { Text(transfer.id.short).font(.caption.monospaced()) }
                    LabeledContent("Payer signature", value: transfer.isSignatureValid ? "Valid" : "INVALID")
                }
            }
        }
        .navigationTitle(entry.amount.formatted())
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MeasurementRow: View {
    let title: String
    let measurement: ProximityMeasurement

    var body: some View {
        let summary = measurement.summary
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: "\(summary.distanceCM) cm ± \(summary.spreadCM / 2)")
            Text(flags(summary.capabilities) + " · \(summary.samples) samples").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func flags(_ caps: RangingCapabilities) -> String {
        var parts: [String] = []
        if caps.contains(.simulated) { parts.append("Simulated") }
        if caps.contains(.preciseDistance) { parts.append("Distance") }
        if caps.contains(.direction) { parts.append("Direction") }
        if caps.contains(.cameraAssistance) { parts.append("Camera-assisted") }
        return parts.joined(separator: ", ")
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.diagnostics
        List {
            Section("Keys") {
                LabeledContent("Signer", value: d.signer)
                LabeledContent("Wallet key") { Text(d.walletFingerprint).font(.caption.monospaced()) }
                LabeledContent("Approval", value: d.biometry)
            }
            Section("Storage") {
                LabeledContent("SQLCipher", value: d.cipherVersion)
                LabeledContent("Database file", value: d.fileEncrypted ? "Encrypted" : "NOT ENCRYPTED")
                LabeledContent("Backups", value: "Excluded")
            }
            Section {
                LabeledContent("Integrity", value: model.integrity.isLocked ? "Locked" : "Verified")
                LabeledContent("Entries", value: "\(d.chainLength)")
                LabeledContent("Tip link") { Text(d.tipLink).font(.caption.monospaced()) }
                Button("Re-verify chain") { Task { await model.reverify() } }
            } header: {
                Text("Hash chain")
            } footer: {
                Text("Every link and signature is re-checked, then the tip is compared with the anchor kept in the Keychain. A restored older database locks the wallet.")
            }
            Section("Proximity") {
                LabeledContent("Policy", value: d.proximityPolicy)
            }
        }
        .navigationTitle("Security")
        .overlay(alignment: .bottom) { BannerView() }
    }
}
