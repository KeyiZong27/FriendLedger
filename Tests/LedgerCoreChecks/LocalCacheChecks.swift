import Foundation
import FriendLedgerCore

@MainActor
private func expectCacheFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { try check(true, message); return }
    throw CheckFailure.failed(message)
}

@MainActor
func runLocalCacheChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerCacheChecks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { fatalError("Test cache cleanup failed: \(error)") }
    }
    let cache = LocalLedgerCache(fileURL: directory.appendingPathComponent("ledgers.json"))
    try check(try cache.load().records.isEmpty, "Missing cache must start locally without an account")
    let ledger = Ledger(zoneName: "FriendLedger-\(UUID().uuidString)", ownerName: "owner", database: .personal, name: "Local test")
    var stored = StoredLedger(ledger: ledger)
    try check(!stored.syncEnabled && stored.cloudAccountID == nil, "New ledger must not opt into cloud")
    let first = entry(cents: 1234, kind: .expense)
    try stored.edit { try $0.addManualEntry(first) }
    var snapshot = LocalLedgerSnapshot()
    snapshot.records = [stored]
    try cache.save(snapshot)
    let loaded = try cache.load()
    try check(loaded.records.count == 1 && loaded.records[0].id == stored.id, "Restart must keep local identity")
    try check(loaded.records[0].book.entries.count == 1 &&
              loaded.records[0].book.entries[0].id == first.id &&
              loaded.records[0].book.entries[0].amountCents == 1234 &&
              loaded.records[0].book.currency == .usd,
              "Restart must keep exact USD entries")
    try check(!loaded.records[0].syncEnabled && loaded.discoveryAccountID == nil, "Local persistence must not enable sync")
    try check(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
              "Local-only cache must exclude automatic cloud backup")

    let oldData = try Data(contentsOf: cache.fileURL)
    var invalid = snapshot
    invalid.records.append(stored)
    try expectCacheFailure("Duplicate cache IDs must fail before replacing saved data") { try cache.save(invalid) }
    try check(try Data(contentsOf: cache.fileURL) == oldData, "Failed validation must preserve the prior file")
    let blocker = directory.appendingPathComponent("blocker")
    try Data("not a directory".utf8).write(to: blocker)
    let blocked = LocalLedgerCache(fileURL: blocker.appendingPathComponent("ledgers.json"))
    try expectCacheFailure("Cache write errors must be explicit") { try blocked.save(snapshot) }
    let directoryCache = LocalLedgerCache(fileURL: directory)
    try expectCacheFailure("Unreadable files must not appear as empty ledgers") { _ = try directoryCache.load() }

    try stored.enableSync(accountID: "account-A")
    try check(stored.syncEnabled && stored.cloudAccountID == "account-A", "Sync must bind an explicit account")
    try expectCacheFailure("Empty accounts must fail") { try stored.enableSync(accountID: "") }
    try expectCacheFailure("Account change must not upload old data to another account") {
        try stored.enableSync(accountID: "account-B")
    }
    let sentRevision = stored.bookRevision
    let sentBook = stored.book
    let second = entry(cents: 5678, kind: .income)
    try stored.edit { try $0.addManualEntry(second) }
    let remote = RemoteLedgerState(ledger: ledger, book: sentBook, changeTag: "tag-1")
    try stored.acknowledgeUpload(remote, sentRevision: sentRevision)
    try check(stored.book.entries.count == 2 && stored.needsUpload, "Older upload ACK must preserve edits made during upload")
    try check(stored.serverChangeTag == "tag-1", "Older ACK must still advance the upload baseline")
    try check(try stored.merge(remote) == .keepingLocalChanges && stored.book.entries.count == 2,
              "Unchanged cloud baseline must not replace unsent edits")
    var otherBook = sentBook
    try otherBook.addManualEntry(entry(cents: 99, kind: .expense))
    let conflict = RemoteLedgerState(ledger: ledger, book: otherBook, changeTag: "tag-2")
    try check(try stored.merge(conflict) == .conflict && stored.hasConflict && stored.book.entries.count == 2,
              "Cloud conflicts must preserve local data")
    try check(stored.book.entries.contains(where: { $0.id == second.id && $0.amountCents == second.amountCents }),
              "Conflict must keep the newest local entry")
    let matching = RemoteLedgerState(ledger: ledger, book: stored.book, changeTag: "tag-3")
    try check(try stored.merge(matching) == .updated && !stored.needsUpload && !stored.hasConflict,
              "Same-byte remote result must acknowledge an uncertain successful upload")
    try stored.edit { try $0.addManualEntry(entry(cents: 55, kind: .expense)) }
    stored.markUnavailable()
    try check(try stored.merge(matching) == .keepingLocalChanges && stored.isAvailable,
              "Restored access must preserve pending local edits and make the shared cache available")
    let currentRevision = stored.bookRevision
    let current = RemoteLedgerState(ledger: ledger, book: stored.book, changeTag: "tag-4")
    try stored.acknowledgeUpload(current, sentRevision: currentRevision)
    try check(!stored.needsUpload && !stored.hasConflict, "Current-revision upload must clear pending state")
    stored.disableSync()
    snapshot.records = [stored]
    try cache.save(snapshot)
    let optedOut = try cache.load().records[0]
    try check(!optedOut.syncEnabled && optedOut.cloudAccountID == "account-A", "Opt-out must persist without erasing account binding")
    let wrong = RemoteLedgerState(
        ledger: Ledger(zoneName: "FriendLedger-other", ownerName: "owner", database: .personal, name: "Other"),
        book: HouseholdBook(), changeTag: "wrong"
    )
    try expectCacheFailure("Remote identity mismatch must fail") { _ = try stored.merge(wrong) }
    try check(stored.book.entries.count == 3, "Invalid remote data must not destroy local entries")

    var performanceBook = HouseholdBook()
    for _ in 0..<200 { try performanceBook.addManualEntry(entry(cents: 100, kind: .expense)) }
    var performanceSnapshot = LocalLedgerSnapshot()
    performanceSnapshot.records = [StoredLedger(ledger: ledger, book: performanceBook)]
    let start = Date()
    try cache.save(performanceSnapshot)
    let performanceLoaded = try cache.load()
    let duration = Date().timeIntervalSince(start)
    try check(performanceLoaded.records[0].book.entries.count == 200 && duration < 1,
              "Saving and reopening 200 local entries must take less than one second, took \(duration)s")
    print(String(format: "Local cache save + reload (200 entries): %.3fs", duration))
    let corrupt = Data("{corrupt".utf8)
    try corrupt.write(to: cache.fileURL, options: .atomic)
    try expectCacheFailure("Corrupt cache must fail, not become an empty successful ledger") { _ = try cache.load() }
    try check(try Data(contentsOf: cache.fileURL) == corrupt, "Read failure must not overwrite the corrupt file")
}
