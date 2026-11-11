import CryptoKit
import Foundation

public enum BankImportSource: String, Codable, Sendable {
    case wallet
    case statement
}

public enum BankTransactionStatus: String, Codable, Sendable {
    case pending
    case booked
    case rejected
}

public struct BankTransaction: Identifiable, Codable, Equatable, Sendable {
    public let source: BankImportSource
    public let accountID: String
    public let transactionID: String?
    public let importRowID: String?
    public let date: Date
    public let postedDate: Date?
    public let amountCents: Int64
    public let kind: EntryKind
    public let currency: Currency
    public let description: String
    public let status: BankTransactionStatus

    public var id: String {
        let components = [source.rawValue, accountID, transactionID == nil ? "row" : "transaction",
                          transactionID ?? importRowID ?? ""]
        let key = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(source: BankImportSource, accountID: String, transactionID: String? = nil,
                importRowID: String? = nil, date: Date, postedDate: Date? = nil, amountCents: Int64,
                kind: EntryKind, currency: Currency = .usd, description: String,
                status: BankTransactionStatus = .booked) {
        self.source = source
        self.accountID = accountID
        self.transactionID = transactionID
        self.importRowID = importRowID
        self.date = date
        self.postedDate = postedDate
        self.amountCents = amountCents
        self.kind = kind
        self.currency = currency
        self.description = description
        self.status = status
    }

    func validate() throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transactionID != nil || importRowID != nil,
              transactionID == nil || transactionID?.isEmpty == false,
              importRowID == nil || importRowID?.isEmpty == false,
              amountCents > 0, amountCents <= Money.maximumCents, currency == .usd,
              date.timeIntervalSince1970.isFinite,
              postedDate == nil || postedDate?.timeIntervalSince1970.isFinite == true
        else { throw FinanceError.invalidField("银行交易标识、币种、日期或金额") }
    }

    func hasSameFinancialMeaning(as other: Self) -> Bool {
        id == other.id && date == other.date && amountCents == other.amountCents
            && kind == other.kind && currency == other.currency && status == other.status
    }
}

public struct BankImportIssue: Codable, Equatable, Sendable {
    public let row: Int
    public let message: String

    public init(row: Int, message: String) {
        self.row = row
        self.message = message
    }
}

public struct BankImportBatch: Sendable {
    public let transactions: [BankTransaction]
    public let issues: [BankImportIssue]

    public init(transactions: [BankTransaction], issues: [BankImportIssue] = []) {
        self.transactions = transactions
        self.issues = issues
    }
}

public enum BankResolution: Codable, Equatable, Sendable {
    case unresolved
    case linked(entryID: String)
    case excluded(reason: String)
}

public struct ImportedBankRecord: Identifiable, Codable, Sendable {
    public var id: String { transaction.id }
    public let transaction: BankTransaction
    public let resolution: BankResolution
    public let previousEntryID: String?
}

public enum BankImportDisposition: String, Codable, Sendable {
    case queuedForReview
    case duplicateSkipped
    case bankPending
    case bankRejected
    case changedNeedsReview
}

public struct BankImportOutcome: Codable, Sendable {
    public let recordID: String
    public let disposition: BankImportDisposition
    public let candidateEntryIDs: [String]
    public let message: String
}

public struct BankImportReport: Codable, Sendable {
    public let id: String
    public let date: Date
    public let outcomes: [BankImportOutcome]
    public let issues: [BankImportIssue]

    public var duplicateCount: Int { outcomes.filter { $0.disposition == .duplicateSkipped }.count }
    public var reviewCount: Int {
        outcomes.filter { $0.disposition == .queuedForReview || $0.disposition == .changedNeedsReview }.count
    }
}

public enum BankReviewAction: Sendable {
    case linkExistingEntry(id: String)
    case createEntry(category: String, author: String, note: String)
    case exclude(reason: String)
}

public struct BankImportLedger: Codable, Sendable {
    public private(set) var records: [ImportedBankRecord] = []
    public private(set) var reports: [BankImportReport] = []

    public init() {}

    public var unresolvedRecords: [ImportedBankRecord] {
        records.filter { $0.resolution == .unresolved }
    }

    public func candidates(for recordID: String, entries: [LedgerEntry], calendar: Calendar) throws -> [String] {
        guard let record = records.first(where: { $0.id == recordID }) else {
            throw FinanceError.invalidField("银行核对记录标识")
        }
        let transaction = record.transaction
        return entries.filter {
            $0.amountCents == transaction.amountCents && $0.kind == transaction.kind
                && calendar.isDate($0.date, inSameDayAs: transaction.date)
        }.map(\.id)
    }

    @discardableResult
    mutating func ingest(_ batch: BankImportBatch, entries: [LedgerEntry], calendar: Calendar) throws -> BankImportReport {
        for transaction in batch.transactions { try transaction.validate() }
        var outcomes: [BankImportOutcome] = []
        for transaction in batch.transactions {
            let index = records.firstIndex { $0.id == transaction.id }
            let previous = index.map { records[$0] }
            let disposition: BankImportDisposition
            let resolution: BankResolution
            let previousEntryID: String?
            let message: String
            if let previous, previous.transaction.hasSameFinancialMeaning(as: transaction) {
                disposition = .duplicateSkipped
                resolution = previous.resolution
                previousEntryID = previous.previousEntryID
                message = "同一来源、账户和交易标识已接收，跳过重复；原核对状态保留。"
            } else if let previous,
                      previous.transaction.status == .booked || previous.previousEntryID != nil {
                disposition = .changedNeedsReview
                resolution = .unresolved
                if case .linked(let id) = previous.resolution { previousEntryID = id }
                else { previousEntryID = previous.previousEntryID }
                message = "银行已入账交易发生变化，需人工核对，未自动修改或重复记账。"
            } else {
                previousEntryID = nil
                switch transaction.status {
                case .booked:
                    disposition = .queuedForReview
                    resolution = .unresolved
                    message = "已入账银行交易待核对；仅同日期同金额不会自动忽略。"
                case .pending:
                    disposition = .bankPending
                    resolution = .unresolved
                    message = "银行待入账交易，仅保留证据，不计入收支。"
                case .rejected:
                    disposition = .bankRejected
                    resolution = .excluded(reason: "银行拒绝交易")
                    message = "银行拒绝交易，不计入收支。"
                }
            }
            let record = ImportedBankRecord(
                transaction: transaction, resolution: resolution, previousEntryID: previousEntryID
            )
            if let index { records[index] = record } else { records.append(record) }
            outcomes.append(BankImportOutcome(
                recordID: record.id, disposition: disposition,
                candidateEntryIDs: try candidates(for: record.id, entries: entries, calendar: calendar),
                message: message
            ))
        }
        let report = BankImportReport(id: UUID().uuidString, date: Date(), outcomes: outcomes, issues: batch.issues)
        reports.append(report)
        return report
    }

    mutating func resolve(_ id: String, action: BankReviewAction, entries: inout [LedgerEntry]) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw FinanceError.invalidField("银行核对记录标识")
        }
        let record = records[index]
        guard record.resolution == .unresolved else {
            throw FinanceError.invalidField("核对状态，只有未解决的交易可以确认")
        }
        let resolution: BankResolution
        switch action {
        case .linkExistingEntry(let entryID):
            guard record.transaction.status == .booked,
                  record.previousEntryID == nil || record.previousEntryID == entryID,
                  let entry = entries.first(where: { $0.id == entryID }),
                  entry.amountCents == record.transaction.amountCents,
                  entry.kind == record.transaction.kind else {
                throw FinanceError.invalidField("关联账目的金额或收支方向")
            }
            resolution = .linked(entryID: entryID)
        case .createEntry(let category, let author, let note):
            guard record.transaction.status == .booked, record.previousEntryID == nil else {
                throw FinanceError.invalidField("银行入账状态或已变化的原关联账目")
            }
            guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FinanceError.invalidField("银行入账分类及记账人")
            }
            let entryID = "bank-\(id)"
            guard !entries.contains(where: { $0.id == entryID }) else { throw FinanceError.duplicateID }
            entries.append(LedgerEntry(
                id: entryID, amountCents: record.transaction.amountCents, kind: record.transaction.kind,
                category: category, note: note, author: author, date: record.transaction.date
            ))
            resolution = .linked(entryID: entryID)
        case .exclude(let reason):
            guard record.previousEntryID == nil else {
                throw FinanceError.invalidField("银行交易已变化，请先核对处理原关联账目")
            }
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FinanceError.invalidField("排除原因，例如账户转账或信用卡还款")
            }
            resolution = .excluded(reason: reason)
        }
        records[index] = ImportedBankRecord(transaction: record.transaction, resolution: resolution, previousEntryID: nil)
    }

    mutating func reopenLinks(to entryID: String) {
        records = records.map { record in
            if record.resolution == .linked(entryID: entryID) || record.previousEntryID == entryID {
                return ImportedBankRecord(transaction: record.transaction, resolution: .unresolved, previousEntryID: nil)
            }
            return record
        }
    }

    func validate(entries: [LedgerEntry]) throws {
        guard Set(records.map(\.id)).count == records.count,
              Set(reports.map(\.id)).count == reports.count else { throw FinanceError.inconsistentBook }
        for record in records {
            try record.transaction.validate()
            if let previousID = record.previousEntryID {
                guard record.resolution == .unresolved, entries.contains(where: { $0.id == previousID }) else {
                    throw FinanceError.inconsistentBook
                }
            }
            switch record.resolution {
            case .unresolved: break
            case .excluded(let reason):
                guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FinanceError.inconsistentBook
                }
            case .linked(let entryID):
                guard record.transaction.status == .booked,
                      let entry = entries.first(where: { $0.id == entryID }),
                      entry.amountCents == record.transaction.amountCents,
                      entry.kind == record.transaction.kind else { throw FinanceError.inconsistentBook }
            }
        }
        for entry in entries where entry.id.hasPrefix("bank-") {
            guard records.contains(where: {
                $0.resolution == .linked(entryID: entry.id) || $0.previousEntryID == entry.id
            }) else { throw FinanceError.inconsistentBook }
        }
    }
}
