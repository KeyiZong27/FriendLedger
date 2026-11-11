import Foundation

public struct RemoteLedgerState: Sendable {
    public let ledger: Ledger
    public let book: HouseholdBook
    public let changeTag: String

    public init(ledger: Ledger, book: HouseholdBook, changeTag: String) {
        self.ledger = ledger
        self.book = book
        self.changeTag = changeTag
    }
}

public enum LocalLedgerMerge: Sendable {
    case updated
    case keepingLocalChanges
    case conflict
}

public struct StoredLedger: Identifiable, Codable, Sendable {
    public let id: String
    public private(set) var ledger: Ledger
    public private(set) var book: HouseholdBook
    public private(set) var syncEnabled = false
    public private(set) var cloudAccountID: String?
    public private(set) var serverChangeTag: String?
    public private(set) var needsUpload = true
    public private(set) var hasConflict = false
    public private(set) var isAvailable = true
    public private(set) var bookRevision = UUID()

    public init(id: String = UUID().uuidString, ledger: Ledger, book: HouseholdBook = HouseholdBook()) {
        self.id = id
        self.ledger = ledger
        self.book = book
    }

    public mutating func edit(_ mutation: (inout HouseholdBook) throws -> Void) throws {
        guard ledger.isOwner || isAvailable else { throw FinanceError.invalidField("共享账本访问权限") }
        var changed = book
        try mutation(&changed)
        _ = try changed.encoded()
        book = changed
        bookRevision = UUID()
        needsUpload = true
    }

    public mutating func enableSync(accountID: String) throws {
        guard !accountID.isEmpty, cloudAccountID == nil || cloudAccountID == accountID else {
            throw FinanceError.invalidField("iCloud 账号，旧账本不会自动上传到其他账号，请先保留本地副本")
        }
        cloudAccountID = accountID
        syncEnabled = true
    }

    public mutating func disableSync() { syncEnabled = false }
    public mutating func markConflict() { hasConflict = true }
    public mutating func markUnavailable() { isAvailable = false }

    public mutating func acknowledgeUpload(_ remote: RemoteLedgerState, sentRevision: UUID) throws {
        try validateRemote(remote)
        ledger = remote.ledger
        serverChangeTag = remote.changeTag
        needsUpload = bookRevision != sentRevision
        hasConflict = false
        isAvailable = true
        if !needsUpload { book = remote.book }
    }

    public mutating func merge(_ remote: RemoteLedgerState) throws -> LocalLedgerMerge {
        try validateRemote(remote)
        isAvailable = true
        if try !needsUpload || book.encoded() == remote.book.encoded() {
            ledger = remote.ledger
            book = remote.book
            serverChangeTag = remote.changeTag
            needsUpload = false
            hasConflict = false
            isAvailable = true
            bookRevision = UUID()
            return .updated
        }
        if serverChangeTag != remote.changeTag {
            hasConflict = true
            return .conflict
        }
        return .keepingLocalChanges
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil,
              ledger.zoneName.hasPrefix("FriendLedger-"), !ledger.ownerName.isEmpty,
              !ledger.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ledger.name.count <= 40,
              !syncEnabled || cloudAccountID?.isEmpty == false,
              cloudAccountID == nil || cloudAccountID?.isEmpty == false,
              serverChangeTag == nil || serverChangeTag?.isEmpty == false,
              !syncEnabled || needsUpload || serverChangeTag != nil else {
            throw FinanceError.invalidField("本地账本或同步状态")
        }
        _ = try book.encoded()
    }

    private func validateRemote(_ remote: RemoteLedgerState) throws {
        guard remote.ledger.id == ledger.id, !remote.changeTag.isEmpty else {
            throw FinanceError.invalidField("云端账本标识或版本")
        }
        _ = try remote.book.encoded()
    }
}

public struct LocalLedgerSnapshot: Codable, Sendable {
    public var records: [StoredLedger] = []
    public var discoveryAccountID: String?
    public var lastSyncedAt: Date?
    public var lastSavedAt: Date?
    private let version: Int

    public init() { version = 1 }

    public func validate() throws {
        guard version == 1, Set(records.map(\.id)).count == records.count,
              discoveryAccountID == nil || discoveryAccountID?.isEmpty == false,
              lastSyncedAt == nil || lastSyncedAt?.timeIntervalSince1970.isFinite == true,
              lastSavedAt == nil || lastSavedAt?.timeIntervalSince1970.isFinite == true else {
            throw FinanceError.invalidField("本地账本缓存版本或状态")
        }
        for record in records { try record.validate() }
    }
}

public struct LocalLedgerCache: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> LocalLedgerSnapshot {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LocalLedgerSnapshot()
        }
        let snapshot = try JSONDecoder().decode(LocalLedgerSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    public func save(_ snapshot: LocalLedgerSnapshot) throws {
        try snapshot.validate()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Cloud backup is opt-in in the app, including automatic device-backup exclusion.
        var directoryURL = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directoryURL.setResourceValues(resources)
        let data = try JSONEncoder().encode(snapshot)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}
