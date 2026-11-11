import CloudKit
import Combine
import Foundation

@MainActor
final class LedgerStore: ObservableObject {
    static let shared = makeShared()

    @Published private(set) var records: [StoredLedger] = []
    @Published private(set) var syncedAt: Date?
    @Published private(set) var savedAt: Date?
    @Published private(set) var isMutating = false
    @Published private(set) var isSyncing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var storageReady = false
    @Published private(set) var syncMessage = ""
    @Published var errorMessage: String?

    var isLoading: Bool { isSyncing || isConnecting }
    var cloudEnabled: Bool { snapshot.discoveryAccountID != nil }
    var selectedCloudAccountID: String? { snapshot.discoveryAccountID }
    @Published private(set) var nickname = ""
    @Published private(set) var useOnDeviceModel = false
    var needsSetup: Bool { storageReady && nickname.isEmpty }

    /// Apple's on-device model needs a recent iPhone with Apple Intelligence enabled in a supported region.
    static var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return AppleReceiptInterpreter.makeIfAvailable() != nil }
        #endif
        return false
    }

    func setUseOnDeviceModel(_ enabled: Bool) {
        preferences.set(enabled, forKey: "useOnDeviceModel")
        useOnDeviceModel = enabled
    }

    func receiptInterpreter() -> (any ReceiptTextInterpreter)? {
        #if canImport(FoundationModels)
        if useOnDeviceModel, #available(iOS 26.0, *) { return AppleReceiptInterpreter.makeIfAvailable() }
        #endif
        return nil
    }
    private let cache: LocalLedgerCache?
    private let preferences: UserDefaults
    private let cloud: any LedgerCloudClient
    private var snapshot = LocalLedgerSnapshot()
    private var accountObserver: NSObjectProtocol?
    private var syncGeneration = UUID()
    private var scheduledSync: Task<Void, Never>?
    private var syncAgain = false

    init(cache: LocalLedgerCache?, cloud: any LedgerCloudClient, preferences: UserDefaults = .standard,
         initialError: String? = nil) {
        self.cache = cache
        self.cloud = cloud
        self.preferences = preferences
        nickname = preferences.string(forKey: "memberNickname") ?? ""
        useOnDeviceModel = preferences.bool(forKey: "useOnDeviceModel")
        do {
            guard let cache else { throw FinanceError.invalidField("本地存储位置") }
            snapshot = try cache.load()
            publish()
            storageReady = true
        } catch {
            errorMessage = initialError ?? "本地账本读取失败：\(error.localizedDescription)。未覆盖原文件。"
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncGeneration = UUID()
                self.errorMessage = "iCloud 账号发生变化，本地数据保留；旧账本不会自动上传到其他账号。"
            }
        }
    }

    func record(id: String) -> StoredLedger? { records.first { $0.id == id } }
    private func validNickname(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 30 else {
            throw FinanceError.invalidField("称呼需为 1–30 个字")
        }
        return trimmed
    }

    /// First launch: everyone starts with their own local ledger, no account or network needed.
    func completeSetup(nickname name: String) async -> Bool {
        do {
            let trimmed = try validNickname(name)
            if records.isEmpty {
                guard await createLedger(name: "\(trimmed)的账本") != nil else { return false }
            }
            preferences.set(trimmed, forKey: "memberNickname")
            nickname = trimmed
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateNickname(_ name: String) -> Bool {
        do {
            let trimmed = try validNickname(name)
            preferences.set(trimmed, forKey: "memberNickname")
            nickname = trimmed
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func retryLocalLoad() {
        do {
            guard let cache else { throw FinanceError.invalidField("本地存储位置") }
            snapshot = try cache.load()
            storageReady = true
            publish()
            errorMessage = nil
            scheduleSync()
        } catch {
            errorMessage = "本地账本读取失败：\(error.localizedDescription)。未覆盖原文件。"
        }
    }

    func entries(for id: String) -> [LedgerEntry] {
        (record(id: id)?.book.entries ?? []).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }

    func createLedger(name: String) async -> StoredLedger? {
        isMutating = true
        defer { isMutating = false }
        do {
            let ledger = Ledger(
                zoneName: "FriendLedger-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName,
                database: .personal, name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let stored = StoredLedger(ledger: ledger)
            var next = snapshot
            next.records.append(stored)
            try commit(next)
            errorMessage = nil
            return stored
        } catch {
            errorMessage = "本地创建失败：\(error.localizedDescription)"
            return nil
        }
    }

    func addEntry(_ entry: LedgerEntry, recordID: String) async -> Bool {
        mutate(recordID) { try $0.addManualEntry(entry) }
    }

    enum ReceiptSaveOutcome {
        case saved
        case possibleDuplicate
        case failed(String)
    }

    /// Saves the merchant and the single expense together, or neither.
    func saveReceipt(_ draft: ReceiptDraft, _ submission: ReceiptSubmission, recordID: String) -> ReceiptSaveOutcome {
        isMutating = true
        defer { isMutating = false }
        do {
            var next = snapshot
            try next.records[try index(recordID, in: next)].edit {
                try $0.submitReceipt(draft, submission, calendar: .current)
            }
            try commit(next)
            errorMessage = nil
            scheduleSync()
            return .saved
        } catch FinanceError.possibleDuplicateReceipt {
            return .possibleDuplicate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static var isUITestProfile: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LEDGER_TEST_CACHE_ID"].flatMap(UUID.init(uuidString:)) != nil
        #else
        return false
        #endif
    }

    func deleteEntry(_ entry: LedgerEntry, recordID: String) async {
        _ = mutate(recordID) { try $0.removeEntry(id: entry.id) }
    }

    func copyLocally(recordID: String) async -> StoredLedger? {
        do {
            let index = try index(recordID, in: snapshot)
            let original = snapshot.records[index]
            let ledger = Ledger(
                zoneName: "FriendLedger-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName,
                database: .personal, name: String(original.ledger.name.prefix(30)) + "（本地副本）"
            )
            let copy = StoredLedger(ledger: ledger, book: original.book)
            var next = snapshot
            next.records.append(copy)
            try commit(next)
            errorMessage = nil
            return copy
        } catch {
            errorMessage = "保留副本失败：\(error.localizedDescription)"
            return nil
        }
    }

    func enableSync(recordID: String) async {
        do {
            try await connect(recordID: recordID)
            scheduleSync()
        } catch {
            errorMessage = "开启同步失败：\(error.localizedDescription)。本地账本不受影响。"
        }
    }

    func disableSync(recordID: String) {
        do {
            var next = snapshot
            next.records[try index(recordID, in: next)].disableSync()
            if !next.records.contains(where: {
                $0.syncEnabled && $0.cloudAccountID == next.discoveryAccountID
            }) { next.discoveryAccountID = nil }
            try commit(next)
            errorMessage = nil
        } catch {
            errorMessage = "停用同步失败：\(error.localizedDescription)"
        }
    }

    func restoreFromCloud() async {
        guard storageReady, !isLoading else { return }
        isConnecting = true
        syncMessage = "正在连接 iCloud，本地账本仍可使用…"
        let generation = syncGeneration
        do {
            let account = try await cloud.accountIdentifier()
            guard generation == syncGeneration else {
                throw FinanceError.invalidField("连接期间 iCloud 账号发生变化，请重试")
            }
            var next = snapshot
            if next.discoveryAccountID != account { syncGeneration = UUID() }
            next.discoveryAccountID = account
            try commit(next)
            isConnecting = false
            await reload()
        } catch {
            isConnecting = false
            errorMessage = "读取云端失败：\(error.localizedDescription)。本地账本仍可使用。"
        }
    }

    func reload() async {
        guard storageReady, let selectedAccount = snapshot.discoveryAccountID else { return }
        if isLoading { syncAgain = true; return }
        isSyncing = true
        syncMessage = "正在同步，本地账本仍可记账…"
        let generation = syncGeneration
        defer {
            isSyncing = false
            if syncAgain { syncAgain = false; scheduleSync() }
        }
        do {
            let account = try await cloud.accountIdentifier()
            guard generation == syncGeneration else { return }
            guard account == selectedAccount else {
                throw FinanceError.invalidField("iCloud 账号已改变，请主动选择从当前账号加载；旧账本保留在本地")
            }
            var issues: [String] = []
            let uploads = snapshot.records.filter {
                $0.syncEnabled && $0.cloudAccountID == account && $0.needsUpload && !$0.hasConflict && $0.isAvailable
            }
            for stored in uploads {
                guard generation == syncGeneration, snapshot.discoveryAccountID == account else { return }
                guard record(id: stored.id)?.syncEnabled == true else { continue }
                syncMessage = "正在上传“\(stored.ledger.name)”，本地仍可记账…"
                do {
                    let remote = try await cloud.uploadLedger(stored)
                    guard generation == syncGeneration else { return }
                    var next = snapshot
                    let index = try index(stored.id, in: next)
                    try next.records[index].acknowledgeUpload(remote, sentRevision: stored.bookRevision)
                    try commit(next)
                } catch let error as CloudLedgerError {
                    if case .financeConflict = error {
                        var next = snapshot
                        next.records[try index(stored.id, in: next)].markConflict()
                        try commit(next)
                    }
                    issues.append("“\(stored.ledger.name)”：\(error.localizedDescription)")
                } catch {
                    issues.append("“\(stored.ledger.name)”：\(error.localizedDescription)")
                }
            }
            guard generation == syncGeneration, snapshot.discoveryAccountID == account else { return }
            syncMessage = "正在核对云端版本，本地仍可记账…"
            let discovery = try await cloud.fetchRemoteLedgers()
            guard generation == syncGeneration, snapshot.discoveryAccountID == account else { return }
            var next = snapshot
            for remote in discovery.records {
                if let index = next.records.firstIndex(where: {
                    $0.cloudAccountID == account && $0.ledger.id == remote.ledger.id
                }) {
                    guard next.records[index].syncEnabled else { continue }
                    if try next.records[index].merge(remote) == .conflict {
                        issues.append("“\(remote.ledger.name)”有同步冲突，本地修改保留，未覆盖云端。")
                    }
                } else {
                    var restored = StoredLedger(ledger: remote.ledger, book: remote.book)
                    try restored.enableSync(accountID: account)
                    try restored.acknowledgeUpload(remote, sentRevision: restored.bookRevision)
                    next.records.append(restored)
                }
            }
            for index in next.records.indices {
                let stored = next.records[index]
                if !stored.ledger.isOwner, stored.syncEnabled, stored.cloudAccountID == account,
                   !discovery.visibleLedgerIDs.contains(stored.ledger.id) {
                    next.records[index].markUnavailable()
                    issues.append("“\(stored.ledger.name)”的共享已不可用，本地缓存保留，已禁止继续写入共享账本。")
                }
            }
            next.lastSyncedAt = Date()
            try commit(next)
            issues.append(contentsOf: discovery.warnings)
            errorMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
            if records.contains(where: {
                $0.syncEnabled && $0.cloudAccountID == account && $0.needsUpload && !$0.hasConflict && $0.isAvailable
            }) && issues.isEmpty { syncAgain = true }
        } catch {
            if generation == syncGeneration {
                errorMessage = "同步暂未完成：\(error.localizedDescription)。本地数据和待上传修改保留。"
            }
        }
    }

    func keepCopyAndReloadConflict(recordID: String) async {
        guard !isLoading else { return }
        isConnecting = true
        syncMessage = "正在核对冲突版本，本地修改会保留副本…"
        let generation = syncGeneration
        defer { isConnecting = false }
        do {
            let account = try await cloud.accountIdentifier()
            let discovery = try await cloud.fetchRemoteLedgers()
            guard generation == syncGeneration else {
                throw FinanceError.invalidField("核对期间 iCloud 账号发生变化，请重试")
            }
            let original = snapshot.records[try index(recordID, in: snapshot)]
            guard original.cloudAccountID == account,
                  let remote = discovery.records.first(where: { $0.ledger.id == original.ledger.id }) else {
                throw CloudLedgerError.missingLedger
            }
            let ledger = Ledger(
                zoneName: "FriendLedger-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName,
                database: .personal, name: String(original.ledger.name.prefix(30)) + "（本地副本）"
            )
            var next = snapshot
            next.records.append(StoredLedger(ledger: ledger, book: original.book))
            var replacement = StoredLedger(id: original.id, ledger: remote.ledger, book: remote.book)
            try replacement.enableSync(accountID: account)
            try replacement.acknowledgeUpload(remote, sentRevision: replacement.bookRevision)
            next.records[try index(recordID, in: next)] = replacement
            try commit(next)
            errorMessage = "本地修改已保留为独立副本，原账本已加载云端版本。"
        } catch {
            errorMessage = "冲突暂未解决：\(error.localizedDescription)。未丢弃本地修改。"
        }
    }

    func prepareShare(recordID: String) async -> SharePresentation? {
        do {
            try await connect(recordID: recordID)
            await reload()
            let stored = snapshot.records[try index(recordID, in: snapshot)]
            guard stored.ledger.isOwner, !stored.needsUpload, !stored.hasConflict else {
                throw FinanceError.invalidField("请先完成当前账本同步，再发送邀请")
            }
            isConnecting = true
            syncMessage = "正在准备共享邀请…"
            defer { isConnecting = false }
            return try await cloud.preparePresentation(for: stored.ledger)
        } catch {
            errorMessage = "邀请暂未完成：\(error.localizedDescription)。本地账本保留。"
            return nil
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        isConnecting = true
        syncMessage = "正在接受共享邀请，本地账本仍可使用…"
        let generation = syncGeneration
        do {
            let account = try await cloud.accountIdentifier()
            try await cloud.accept(metadata)
            guard generation == syncGeneration else {
                throw FinanceError.invalidField("接受邀请期间 iCloud 账号发生变化，请重新加载")
            }
            var next = snapshot
            if next.discoveryAccountID != account { syncGeneration = UUID() }
            next.discoveryAccountID = account
            try commit(next)
            isConnecting = false
            if isSyncing { syncAgain = true } else { await reload() }
        } catch {
            isConnecting = false
            errorMessage = "加入账本失败：\(error.localizedDescription)"
        }
    }

    private func mutate(_ recordID: String, _ mutation: (inout HouseholdBook) throws -> Void) -> Bool {
        isMutating = true
        defer { isMutating = false }
        do {
            var next = snapshot
            try next.records[try index(recordID, in: next)].edit(mutation)
            try commit(next)
            errorMessage = nil
            scheduleSync()
            return true
        } catch {
            errorMessage = "本地保存失败：\(error.localizedDescription)。输入未清空。"
            return false
        }
    }

    private func connect(recordID: String) async throws {
        guard storageReady, !isLoading else { throw FinanceError.invalidField("请等待当前 iCloud 操作完成") }
        isConnecting = true
        syncMessage = "正在连接 iCloud，本地仍可记账…"
        defer { isConnecting = false }
        let generation = syncGeneration
        let account = try await cloud.accountIdentifier()
        guard generation == syncGeneration else {
            throw FinanceError.invalidField("连接期间 iCloud 账号发生变化，请重试")
        }
        var next = snapshot
        try next.records[try index(recordID, in: next)].enableSync(accountID: account)
        if next.discoveryAccountID != account { syncGeneration = UUID() }
        next.discoveryAccountID = account
        try commit(next)
        errorMessage = nil
    }

    private func scheduleSync() {
        guard cloudEnabled else { return }
        if isLoading { syncAgain = true; return }
        scheduledSync?.cancel()
        scheduledSync = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch is CancellationError { return }
            catch { self?.errorMessage = "同步调度失败：\(error.localizedDescription)"; return }
            guard let self else { return }
            self.scheduledSync = nil
            await self.reload()
        }
    }

    private func index(_ id: String, in state: LocalLedgerSnapshot) throws -> Int {
        guard let index = state.records.firstIndex(where: { $0.id == id }) else {
            throw FinanceError.invalidField("本地账本标识")
        }
        return index
    }

    private func commit(_ next: LocalLedgerSnapshot) throws {
        guard storageReady, let cache else { throw FinanceError.invalidField("本地存储尚未恢复，请先处理读取错误") }
        var changed = next
        changed.lastSavedAt = Date()
        try cache.save(changed)
        snapshot = changed
        publish()
    }

    private func publish() {
        records = snapshot.records
        syncedAt = snapshot.lastSyncedAt
        savedAt = snapshot.lastSavedAt
    }

    private static func makeShared() -> LedgerStore {
        let cloud: any LedgerCloudClient
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let testProfile = environment["LEDGER_TEST_CACHE_ID"].flatMap(UUID.init(uuidString:))
        cloud = testProfile != nil && environment["LEDGER_TEST_SLOW_CLOUD"] == "1"
            ? SlowUITestCloudClient() : CloudLedgerService()
        #else
        let testProfile: UUID? = nil
        cloud = CloudLedgerService()
        #endif
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let folder = testProfile.map { "FriendLedgerUITests/\($0.uuidString)" } ?? "FriendLedger"
            let cache = LocalLedgerCache(fileURL: support.appendingPathComponent(folder).appendingPathComponent("ledgers-v1.json"))
            let preferences: UserDefaults
            if let testProfile {
                guard let suite = UserDefaults(suiteName: "FriendLedgerUITests.\(testProfile.uuidString)") else {
                    throw FinanceError.invalidField("测试偏好设置隔离")
                }
                preferences = suite
            } else { preferences = .standard }
            return LedgerStore(cache: cache, cloud: cloud, preferences: preferences)
        } catch {
            return LedgerStore(cache: nil, cloud: cloud, initialError: "无法打开本地存储：\(error.localizedDescription)")
        }
    }
}
