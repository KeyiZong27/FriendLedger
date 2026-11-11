import CloudKit
import Foundation

enum CloudLedgerError: LocalizedError {
    case configuration
    case account
    case corruptRecord(String)
    case missingLedger
    case financeConflict

    var errorDescription: String? {
        switch self {
        case .configuration: "请先在 Xcode 配置开发团队、自己的 iCloud 容器和签名权限，替换示例 CloudKitContainerIdentifier。"
        case .account: "请先在 iPhone 设置中登录 iCloud，并开启本应用的 iCloud 权限。"
        case .corruptRecord(let name): "云端记录格式不正确：\(name)。请联系账本创建者。"
        case .missingLedger: "账本已不存在，或你已被移出共享。请刷新账本列表。"
        case .financeConflict: "另一位成员刚刚更新了财务账本，请刷新后核对并重试，未覆盖对方的数据。"
        }
    }
}

struct CloudSnapshot: Codable {
    var ledgers: [Ledger]
    var entries: [String: [LedgerEntry]]
    var syncedAt: Date
}

struct SharePresentation: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
    let title: String
}

@MainActor
final class CloudLedgerService: LedgerCloudClient {
    private var configuredContainer: CKContainer?

    func container() throws -> CKContainer {
        if let configuredContainer { return configuredContainer }
        guard let identifier = Bundle.main.object(
            forInfoDictionaryKey: "CloudKitContainerIdentifier"
        ) as? String, identifier.hasPrefix("iCloud."), !identifier.contains("$("),
              identifier != "iCloud.com.example.FriendLedger" else {
            throw CloudLedgerError.configuration
        }
        let container = CKContainer(identifier: identifier)
        configuredContainer = container
        return container
    }

    func checkAccount() async throws {
        guard try await container().accountStatus() == .available else {
            throw CloudLedgerError.account
        }
    }

    func accountIdentifier() async throws -> String {
        try await checkAccount()
        return try await container().userRecordID().recordName
    }

    func preparePresentation(for ledger: Ledger) async throws -> SharePresentation {
        SharePresentation(share: try await share(for: ledger), container: try container(), title: ledger.name)
    }

    func fetchRemoteLedgers() async throws -> RemoteLedgerDiscovery {
        let privateDatabase = try database(for: .personal)
        let sharedDatabase = try database(for: .shared)
        async let privateZones = privateDatabase.allRecordZones()
        async let sharedZones = sharedDatabase.allRecordZones()
        let scopes = try await [
            (LedgerDatabase.personal, privateDatabase, privateZones),
            (LedgerDatabase.shared, sharedDatabase, sharedZones)
        ]
        var snapshots: [RemoteLedgerState] = []
        var visibleIDs: Set<String> = []
        var warnings: [String] = []
        for (scope, database, allZones) in scopes {
            let zones = allZones.filter { $0.zoneID.zoneName.hasPrefix("FriendLedger-") }
            // Fetch roots and financial snapshots together, instead of querying every expense.
            for start in stride(from: 0, to: zones.count, by: 100) {
                let batch = zones[start..<min(start + 100, zones.count)]
                let ids = batch.flatMap { zone in
                    ["ledger", "household-book"].map { CKRecord.ID(recordName: $0, zoneID: zone.zoneID) }
                }
                let results = try await database.records(for: ids, desiredKeys: ["name", "payload"])
                for zone in batch {
                    let identifier = "\(scope.rawValue):\(zone.zoneID.ownerName):\(zone.zoneID.zoneName)"
                    visibleIDs.insert(identifier)
                    let rootID = CKRecord.ID(recordName: "ledger", zoneID: zone.zoneID)
                    let bookID = CKRecord.ID(recordName: "household-book", zoneID: zone.zoneID)
                    guard let rootResult = results[rootID], let bookResult = results[bookID] else {
                        throw CloudLedgerError.corruptRecord(identifier)
                    }
                    do {
                        let root = try rootResult.get()
                        guard let name = root["name"] as? String, !name.isEmpty else {
                            throw CloudLedgerError.corruptRecord(identifier)
                        }
                        do {
                            let record = try bookResult.get()
                            guard let tag = record.recordChangeTag else {
                                throw CloudLedgerError.corruptRecord(identifier)
                            }
                            let ledger = Ledger(
                                zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName,
                                database: scope, name: name
                            )
                            snapshots.append(RemoteLedgerState(
                                ledger: ledger, book: try decodeHouseholdRecord(record), changeTag: tag
                            ))
                        } catch let error as CKError where error.code == .unknownItem {
                            warnings.append("“\(name)”是旧原型账本，尚未迁移到美元内核；未改动原有记录。")
                        }
                    } catch let error as CKError {
                        warnings.append("云端账本 \(zone.zoneID.zoneName) 暂未读取：\(error.localizedDescription)")
                    }
                }
            }
        }
        return RemoteLedgerDiscovery(records: snapshots, visibleLedgerIDs: visibleIDs, warnings: warnings)
    }

    func uploadLedger(_ stored: StoredLedger) async throws -> RemoteLedgerState {
        try stored.validate()
        let ledger = stored.ledger
        let database = try database(for: ledger.database)
        let zoneID = zoneID(for: ledger)
        if ledger.isOwner && stored.serverChangeTag == nil {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
        let record = try await householdRecord(database: database, zoneID: zoneID)
        let data = try stored.book.encoded()
        if let existingTag = record.recordChangeTag {
            if try decodeHouseholdRecord(record).encoded() == data {
                return RemoteLedgerState(ledger: ledger, book: stored.book, changeTag: existingTag)
            }
            guard existingTag == stored.serverChangeTag else { throw CloudLedgerError.financeConflict }
        } else if stored.serverChangeTag != nil || !ledger.isOwner {
            throw CloudLedgerError.missingLedger
        }
        guard let payload = String(data: data, encoding: .utf8) else {
            throw CloudLedgerError.corruptRecord(record.recordID.recordName)
        }
        record["payload"] = payload as CKRecordValue
        var saving = [record]
        if record.recordChangeTag == nil {
            let rootID = CKRecord.ID(recordName: "ledger", zoneID: zoneID)
            let root: CKRecord
            do {
                _ = try await database.record(for: rootID)
                throw CloudLedgerError.corruptRecord("旧账本缺少财务快照，请先迁移；未改动原记录")
            }
            catch let error as CKError where error.code == .unknownItem {
                root = CKRecord(recordType: "Ledger", recordID: rootID)
            }
            root["name"] = ledger.name as CKRecordValue
            saving.append(root)
        }
        do {
            let results = try await database.modifyRecords(
                saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            for item in saving {
                guard let result = results.saveResults[item.recordID] else {
                    throw CloudLedgerError.corruptRecord(item.recordID.recordName)
                }
                _ = try result.get()
            }
            guard let result = results.saveResults[record.recordID], let tag = try result.get().recordChangeTag else {
                throw CloudLedgerError.corruptRecord(record.recordID.recordName)
            }
            return RemoteLedgerState(ledger: ledger, book: stored.book, changeTag: tag)
        } catch let error as CKError {
            if error.code == .serverRecordChanged ||
                error.partialErrorsByItemID?.values.contains(where: {
                    ($0 as? CKError)?.code == .serverRecordChanged
                }) == true {
                throw CloudLedgerError.financeConflict
            }
            throw error
        }
    }

    func fetchSnapshot() async throws -> CloudSnapshot {
        try await checkAccount()
        var ledgers: [Ledger] = []
        var entries: [String: [LedgerEntry]] = [:]
        for scope in [LedgerDatabase.personal, .shared] {
            let database = try database(for: scope)
            let zones = try await database.allRecordZones()
            for zone in zones where zone.zoneID.zoneName.hasPrefix("FriendLedger-") {
                let recordID = CKRecord.ID(recordName: "ledger", zoneID: zone.zoneID)
                let root = try await database.record(for: recordID)
                guard let name = root["name"] as? String, !name.isEmpty else {
                    throw CloudLedgerError.corruptRecord(root.recordID.recordName)
                }
                let ledger = Ledger(
                    zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName,
                    database: scope, name: name
                )
                let records = try await fetchEntries(database: database, zoneID: zone.zoneID)
                entries[ledger.id] = try records.map(decodeEntry).sorted {
                    $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
                }
                ledgers.append(ledger)
            }
        }
        return CloudSnapshot(
            ledgers: ledgers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            entries: entries, syncedAt: Date()
        )
    }

    func createLedger(name: String) async throws -> Ledger {
        try await checkAccount()
        let database = try database(for: .personal)
        let zone = CKRecordZone(zoneName: "FriendLedger-\(UUID().uuidString)")
        _ = try await database.save(zone)
        let root = CKRecord(
            recordType: "Ledger", recordID: CKRecord.ID(recordName: "ledger", zoneID: zone.zoneID)
        )
        root["name"] = name as CKRecordValue
        do {
            _ = try await database.save(root)
        } catch {
            do {
                try await database.deleteRecordZone(withID: zone.zoneID)
            } catch let cleanupError {
                throw NSError(
                    domain: "FriendLedger", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "创建账本失败：\(error.localizedDescription)；清理失败：\(cleanupError.localizedDescription)"]
                )
            }
            throw error
        }
        return Ledger(
            zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName,
            database: .personal, name: name
        )
    }

    func addEntry(_ entry: LedgerEntry, to ledger: Ledger) async throws {
        guard entry.amountCents > 0, entry.amountCents <= Money.maximumCents else {
            throw AmountError.invalid
        }
        let database = try database(for: ledger.database)
        let zoneID = zoneID(for: ledger)
        // Confirm access to the root before writing to a potentially revoked share.
        _ = try await database.record(for: CKRecord.ID(recordName: "ledger", zoneID: zoneID))
        let record = CKRecord(
            recordType: "Entry", recordID: CKRecord.ID(recordName: entry.id, zoneID: zoneID)
        )
        record["amountCents"] = NSNumber(value: entry.amountCents)
        record["kind"] = entry.kind.rawValue as CKRecordValue
        record["category"] = entry.category as CKRecordValue
        record["note"] = entry.note as CKRecordValue
        record["author"] = entry.author as CKRecordValue
        record["date"] = entry.date as CKRecordValue
        // Reuse the entry ID so retrying an uncertain network result does not create a duplicate.
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .allKeys, atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else {
            throw CloudLedgerError.corruptRecord(record.recordID.recordName)
        }
        _ = try saved.get()
    }

    func deleteEntry(_ entry: LedgerEntry, from ledger: Ledger) async throws {
        try await database(for: ledger.database).deleteRecord(
            withID: CKRecord.ID(recordName: entry.id, zoneID: zoneID(for: ledger))
        )
    }

    func share(for ledger: Ledger) async throws -> CKShare {
        guard ledger.isOwner else { throw CloudLedgerError.missingLedger }
        let database = try database(for: .personal)
        let zoneID = zoneID(for: ledger)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            let record = try await database.record(for: shareID)
            guard let share = record as? CKShare else {
                throw CloudLedgerError.corruptRecord(record.recordID.recordName)
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = ledger.name as CKRecordValue
            share.publicPermission = .none
            let saved = try await database.save(share)
            guard let savedShare = saved as? CKShare else {
                throw CloudLedgerError.corruptRecord(saved.recordID.recordName)
            }
            return savedShare
        }
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        try await checkAccount()
        guard metadata.containerIdentifier == (try container().containerIdentifier) else {
            throw CloudLedgerError.configuration
        }
        _ = try await container().accept(metadata)
    }

    func loadHouseholdBook(for ledger: Ledger) async throws -> HouseholdBook {
        try await checkAccount()
        let database = try database(for: ledger.database)
        _ = try await database.record(for: CKRecord.ID(recordName: "ledger", zoneID: zoneID(for: ledger)))
        let record = try await householdRecord(database: database, zoneID: zoneID(for: ledger))
        return try decodeHouseholdRecord(record)
    }

    func updateHouseholdBook(
        for ledger: Ledger, mutation: (inout HouseholdBook) throws -> Void
    ) async throws -> HouseholdBook {
        try await checkAccount()
        let database = try database(for: ledger.database)
        _ = try await database.record(for: CKRecord.ID(recordName: "ledger", zoneID: zoneID(for: ledger)))
        let record = try await householdRecord(database: database, zoneID: zoneID(for: ledger))
        var book = try decodeHouseholdRecord(record)
        try mutation(&book)
        let data = try book.encoded()
        guard let payload = String(data: data, encoding: .utf8) else {
            throw CloudLedgerError.corruptRecord(record.recordID.recordName)
        }
        record["payload"] = payload as CKRecordValue
        do {
            // Preserve the fetched change tag: simultaneous edits must conflict, not overwrite.
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw CloudLedgerError.financeConflict
        }
        return book
    }

    private func householdRecord(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKRecord {
        let id = CKRecord.ID(recordName: "household-book", zoneID: zoneID)
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: "HouseholdBook", recordID: id)
        }
    }

    private func decodeHouseholdRecord(_ record: CKRecord) throws -> HouseholdBook {
        if record.creationDate == nil, record["payload"] == nil { return HouseholdBook() }
        guard record.recordType == "HouseholdBook",
              let payload = record["payload"] as? String else {
            throw CloudLedgerError.corruptRecord(record.recordID.recordName)
        }
        return try HouseholdBook.decode(Data(payload.utf8))
    }

    private func database(for scope: LedgerDatabase) throws -> CKDatabase {
        let container = try container()
        return scope == .personal ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for ledger: Ledger) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: ledger.zoneName, ownerName: ledger.ownerName)
    }

    private func fetchEntries(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        let query = CKQuery(recordType: "Entry", predicate: NSPredicate(value: true))
        var page = try await database.records(matching: query, inZoneWith: zoneID)
        var records = try page.matchResults.map { try $0.1.get() }
        while let cursor = page.queryCursor {
            page = try await database.records(continuingMatchFrom: cursor)
            records.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        }
        return records
    }

    private func decodeEntry(_ record: CKRecord) throws -> LedgerEntry {
        guard let amount = record["amountCents"] as? NSNumber,
              amount.int64Value > 0, amount.int64Value <= Money.maximumCents,
              let kindValue = record["kind"] as? String,
              let kind = EntryKind(rawValue: kindValue),
              let category = record["category"] as? String,
              let note = record["note"] as? String,
              let author = record["author"] as? String,
              let date = record["date"] as? Date else {
            throw CloudLedgerError.corruptRecord(record.recordID.recordName)
        }
        return LedgerEntry(
            id: record.recordID.recordName, amountCents: amount.int64Value, kind: kind,
            category: category, note: note, author: author, date: date
        )
    }
}
