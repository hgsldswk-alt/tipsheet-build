import CloudKit
import Foundation

enum CloudState: Equatable {
    case checking, disabled, unavailable, running, synced(Date), failed, changedAccount
}

enum CloudProblem: Error { case unavailable, changedAccount }

actor PrivateCloud {
    private lazy var container = CKContainer(identifier: "iCloud.com.hgsldswk.tipsheet")
    private let recordID = CKRecord.ID(recordName: "tipsheet-ledger-v1")

    func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudProblem.unavailable }
        return try await container.userRecordID().recordName
    }

    func sync(_ local: Ledger, account expectedAccount: String, at date: Date) async throws -> Ledger {
        let database = container.privateCloudDatabase
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard try await account() == expectedAccount else { throw CloudProblem.changedAccount }
            let record: CKRecord
            let existing: Bool
            do {
                record = try await database.record(for: recordID)
                existing = true
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "TipsheetLedger", recordID: recordID)
                existing = false
            }
            var merged = local
            if existing {
                guard let asset = record["ledger"] as? CKAsset, let url = asset.fileURL else { throw ExchangeError.invalidFile }
                let remote = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
                guard remote.isValid else { throw ExchangeError.invalidFile }
                merged = local.merged(with: remote)
                merged.purge(at: date)
                if remote == merged { return merged }
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try JSONEncoder().encode(merged).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? FileManager.default.removeItem(at: file) }
            record["ledger"] = CKAsset(fileURL: file)
            try Task.checkCancellation()
            guard try await account() == expectedAccount else { throw CloudProblem.changedAccount }
            do {
                _ = try await database.save(record)
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CKError(.serverRecordChanged)
    }
}
