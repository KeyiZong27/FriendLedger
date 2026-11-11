import Foundation

public struct PayrollRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let member: String
    public let date: Date
    public let grossCents: Int64
    public let withheldTaxCents: Int64
    public let otherDeductionCents: Int64
    public let netCents: Int64
    public let linkedEntryID: String?
    public var entryID: String { linkedEntryID ?? "payroll-\(id)" }

    public init(id: String = UUID().uuidString, member: String, date: Date,
                grossCents: Int64, withheldTaxCents: Int64, otherDeductionCents: Int64, netCents: Int64,
                linkedEntryID: String? = nil) {
        self.id = id
        self.member = member
        self.date = date
        self.grossCents = grossCents
        self.withheldTaxCents = withheldTaxCents
        self.otherDeductionCents = otherDeductionCents
        self.netCents = netCents
        self.linkedEntryID = linkedEntryID
    }

    func validate() throws {
        guard !id.isEmpty, !member.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              grossCents > 0, grossCents <= Money.maximumCents,
              [withheldTaxCents, otherDeductionCents, netCents].allSatisfy({ (0...Money.maximumCents).contains($0) }),
              netCents > 0 || linkedEntryID == nil,
              date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("工资信息") }
        guard Decimal(grossCents) - Decimal(withheldTaxCents) - Decimal(otherDeductionCents) == Decimal(netCents)
        else { throw FinanceError.payrollMismatch }
    }
}

public struct SavingsOpening: Codable, Sendable {
    public let amountCents: Int64
    public let date: Date

    public init(amountCents: Int64, date: Date) {
        self.amountCents = amountCents
        self.date = date
    }
}

public enum SavingsDirection: String, Codable, Sendable {
    case deposit
    case withdrawal
}

public struct SavingsMovement: Identifiable, Codable, Sendable {
    public let id: String
    public let direction: SavingsDirection
    public let amountCents: Int64
    public let date: Date
    public let note: String

    public init(id: String = UUID().uuidString, direction: SavingsDirection,
                amountCents: Int64, date: Date, note: String = "") {
        self.id = id
        self.direction = direction
        self.amountCents = amountCents
        self.date = date
        self.note = note
    }
}

public struct ManualExchangeRate: Codable, Sendable {
    public let cnyPerUSD: Decimal
    public let effectiveDate: Date

    public init(cnyPerUSD: Decimal, effectiveDate: Date) throws {
        self.cnyPerUSD = cnyPerUSD
        self.effectiveDate = effectiveDate
        try validate()
    }

    func validate() throws {
        guard !cnyPerUSD.isNaN, cnyPerUSD > 0, cnyPerUSD <= 1000,
              effectiveDate.timeIntervalSince1970.isFinite else {
            throw FinanceError.invalidField("美元兑人民币汇率及日期")
        }
    }
}

public struct SavingsProgress: Sendable {
    public let balanceUSDCents: Decimal
    public let estimatedBalanceCNYCents: Decimal
    public let targetCNYCents: Int64
    public let exchangeRate: ManualExchangeRate

    public var remainingCNYCents: Decimal {
        max(0, Decimal(targetCNYCents) - estimatedBalanceCNYCents)
    }
    public var progressFraction: Decimal { estimatedBalanceCNYCents / Decimal(targetCNYCents) }
}

public struct MerchantMonthlyTotal: Sendable {
    public let merchant: MerchantProfile
    public let expenseCents: Decimal
    public let receiptCount: Int
}

public struct MonthlyFinanceSummary: Sendable {
    public let incomeCents: Decimal
    public let expenseCents: Decimal
    public var cashFlowCents: Decimal { incomeCents - expenseCents }
    public let grossPayrollCents: Decimal
    public let withheldTaxCents: Decimal
    public let otherPayrollDeductionCents: Decimal
    public let netPayrollCents: Decimal
    public let depositedCents: Decimal
    public let withdrawnCents: Decimal
    public let merchantTotals: [MerchantMonthlyTotal]
    public let businessTypeTotals: [String: Decimal]
    public let unassignedExpenseCents: Decimal
}

public struct HouseholdBook: Codable, Sendable {
    public private(set) var entries: [LedgerEntry] = []
    public private(set) var merchants: [MerchantProfile] = []
    public private(set) var receipts: [ConfirmedReceipt] = []
    public private(set) var payroll: [PayrollRecord] = []
    public private(set) var savingsOpening: SavingsOpening?
    public private(set) var savingsMovements: [SavingsMovement] = []
    public private(set) var exchangeRate: ManualExchangeRate?
    public private(set) var targetCNYCents: Int64 = 2_000_000_000
    public private(set) var bankImports = BankImportLedger()
    public var currency: Currency { .usd }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case entries, merchants, receipts, payroll, savingsOpening, savingsMovements
        case exchangeRate, targetCNYCents, bankImports
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([LedgerEntry].self, forKey: .entries)
        merchants = try values.decode([MerchantProfile].self, forKey: .merchants)
        receipts = try values.decode([ConfirmedReceipt].self, forKey: .receipts)
        payroll = try values.decode([PayrollRecord].self, forKey: .payroll)
        savingsOpening = try values.decodeIfPresent(SavingsOpening.self, forKey: .savingsOpening)
        savingsMovements = try values.decode([SavingsMovement].self, forKey: .savingsMovements)
        exchangeRate = try values.decodeIfPresent(ManualExchangeRate.self, forKey: .exchangeRate)
        targetCNYCents = try values.decode(Int64.self, forKey: .targetCNYCents)
        bankImports = values.contains(.bankImports)
            ? try values.decode(BankImportLedger.self, forKey: .bankImports) : BankImportLedger()
    }

    @discardableResult
    public mutating func importBankTransactions(_ batch: BankImportBatch, calendar: Calendar) throws -> BankImportReport {
        try validate()
        return try bankImports.ingest(batch, entries: entries, calendar: calendar)
    }

    public mutating func resolveBankTransaction(id: String, action: BankReviewAction) throws {
        try validate()
        try bankImports.resolve(id, action: action, entries: &entries)
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(HouseholdBookEnvelope(version: 1, currency: .usd, book: self))
        guard data.count <= 900_000 else {
            throw FinanceError.invalidField("账本容量，当前内核快照最多 900 KB，需要升级存储方式")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> HouseholdBook {
        guard data.count <= 900_000 else { throw FinanceError.invalidField("账本快照容量") }
        let envelope = try JSONDecoder().decode(HouseholdBookEnvelope.self, from: data)
        guard envelope.version == 1, envelope.currency == .usd else {
            throw FinanceError.invalidField("账本版本或币种，当前内核只接受美元账本")
        }
        try envelope.book.validate()
        return envelope.book
    }

    public func merchant(matching name: String) -> MerchantProfile? {
        let key = MerchantProfile.key(name)
        guard !key.isEmpty else { return nil }
        return merchants.first { $0.keys.contains(key) }
    }

    public mutating func saveMerchant(_ merchant: MerchantProfile) throws {
        try validateMerchant(merchant)
        guard !merchants.contains(where: { $0.id != merchant.id && !$0.keys.isDisjoint(with: merchant.keys) })
        else { throw FinanceError.ambiguousMerchant }
        if let index = merchants.firstIndex(where: { $0.id == merchant.id }) {
            merchants[index] = merchant
        } else {
            merchants.append(merchant)
        }
    }

    public mutating func addManualEntry(_ entry: LedgerEntry) throws {
        try validateEntry(entry)
        guard !entries.contains(where: { $0.id == entry.id }),
              !entry.id.hasPrefix("receipt-"), !entry.id.hasPrefix("payroll-"),
              !entry.id.hasPrefix("bank-") else {
            throw FinanceError.duplicateID
        }
        entries.append(entry)
    }

    @discardableResult
    public mutating func confirmReceipt(
        _ draft: ReceiptDraft, review: ReceiptReview, calendar: Calendar,
        allowPossibleDuplicate: Bool = false, existingEntryID: String? = nil
    ) throws -> ConfirmedReceipt {
        guard !receipts.contains(where: { $0.id == draft.id || (
            draft.imageFingerprint != nil && $0.imageFingerprint == draft.imageFingerprint
        ) }) else { throw FinanceError.duplicateReceipt }
        guard let merchant = merchants.first(where: { $0.id == review.merchantID }) else {
            throw FinanceError.merchantNotFound
        }
        let entry = LedgerEntry(
            id: existingEntryID ?? "receipt-\(draft.id)", amountCents: review.totalCents, kind: .expense,
            category: merchant.businessType, note: review.note, author: review.author, date: review.date
        )
        try validateEntry(entry)
        if let existingEntryID {
            guard let existing = entries.first(where: { $0.id == existingEntryID }),
                  existing.kind == .expense, existing.amountCents == review.totalCents,
                  !receipts.contains(where: { $0.entryID == existingEntryID }) else {
                throw FinanceError.invalidField("待关联收据的已有支出")
            }
        } else {
            guard !entries.contains(where: { $0.id == entry.id }) else { throw FinanceError.duplicateID }
        }
        let receipt = ConfirmedReceipt(
            id: draft.id, entryID: entry.id, imageFingerprint: draft.imageFingerprint,
            merchant: merchant, items: review.items, adjustments: review.adjustments,
            taxCents: review.taxCents, totalCents: review.totalCents, date: review.date
        )
        try validateReceipt(receipt)
        guard allowPossibleDuplicate || !receipts.contains(where: {
            $0.merchant.id == merchant.id && $0.totalCents == review.totalCents
                && calendar.isDate($0.date, inSameDayAs: review.date)
        }) else { throw FinanceError.possibleDuplicateReceipt }
        // Item totals are analysis only. The one confirmed payment is the ledger expense.
        receipts.append(receipt)
        if existingEntryID == nil { entries.append(entry) }
        return receipt
    }

    public mutating func addPayroll(_ record: PayrollRecord) throws {
        try record.validate()
        guard !payroll.contains(where: { $0.id == record.id }),
              !payroll.contains(where: { $0.entryID == record.entryID }) else { throw FinanceError.duplicateID }
        if let linkedID = record.linkedEntryID {
            guard record.netCents > 0, let entry = entries.first(where: { $0.id == linkedID }),
                  entry.kind == .income, entry.amountCents == record.netCents else {
                throw FinanceError.invalidField("待关联工资的已有到账")
            }
        } else if entries.contains(where: { $0.id == record.entryID }) { throw FinanceError.duplicateID }
        payroll.append(record)
        if record.netCents > 0 && record.linkedEntryID == nil {
            entries.append(LedgerEntry(
                id: record.entryID, amountCents: record.netCents, kind: .income,
                category: "工资", note: "税后实际到账", author: record.member, date: record.date
            ))
        }
    }

    public mutating func removeEntry(id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { throw FinanceError.invalidField("记录标识") }
        entries.removeAll { $0.id == id }
        receipts.removeAll { $0.entryID == id }
        payroll.removeAll { $0.entryID == id }
        bankImports.reopenLinks(to: id)
    }

    public mutating func removePayroll(id: String) throws {
        guard let record = payroll.first(where: { $0.id == id }) else {
            throw FinanceError.invalidField("工资记录标识")
        }
        payroll.removeAll { $0.id == id }
        entries.removeAll { $0.id == record.entryID }
        bankImports.reopenLinks(to: record.entryID)
    }

    public mutating func setSavingsOpening(_ opening: SavingsOpening) throws {
        guard (0...Money.maximumCents).contains(opening.amountCents),
              opening.date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("初始存款") }
        try validateSavings(opening: opening, movements: savingsMovements)
        savingsOpening = opening
    }

    public mutating func addSavingsMovement(_ movement: SavingsMovement) throws {
        guard let opening = savingsOpening else { throw FinanceError.savingsNotConfigured }
        guard !savingsMovements.contains(where: { $0.id == movement.id }) else { throw FinanceError.duplicateID }
        try validateSavings(opening: opening, movements: savingsMovements + [movement])
        savingsMovements.append(movement)
    }

    public mutating func removeSavingsMovement(id: String) throws {
        guard let opening = savingsOpening else { throw FinanceError.savingsNotConfigured }
        guard savingsMovements.contains(where: { $0.id == id }) else { throw FinanceError.invalidField("存款流水标识") }
        let remaining = savingsMovements.filter { $0.id != id }
        try validateSavings(opening: opening, movements: remaining)
        savingsMovements = remaining
    }

    public mutating func setSavingsGoal(targetCNYCents: Int64, rate: ManualExchangeRate) throws {
        guard targetCNYCents > 0, targetCNYCents <= Money.maximumCents else {
            throw FinanceError.invalidField("人民币存款目标")
        }
        try rate.validate()
        self.targetCNYCents = targetCNYCents
        exchangeRate = rate
    }

    public func savingsProgress(asOf date: Date) throws -> SavingsProgress {
        guard date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("存款查询日期") }
        try validate()
        guard let opening = savingsOpening else { throw FinanceError.savingsNotConfigured }
        guard date >= opening.date else { throw FinanceError.savingsBeforeOpening }
        guard let rate = exchangeRate, rate.effectiveDate <= date else {
            throw FinanceError.exchangeRateMissing
        }
        let balance = savingsMovements.filter { $0.date <= date }.reduce(Decimal(opening.amountCents)) {
            $0 + ($1.direction == .deposit ? Decimal($1.amountCents) : -Decimal($1.amountCents))
        }
        var converted = balance * rate.cnyPerUSD
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &converted, 0, .plain)
        return SavingsProgress(
            balanceUSDCents: balance, estimatedBalanceCNYCents: rounded,
            targetCNYCents: targetCNYCents, exchangeRate: rate
        )
    }

    public func monthlySummary(containing date: Date, calendar: Calendar) throws -> MonthlyFinanceSummary {
        guard date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("月份") }
        try validate()
        guard let month = calendar.dateInterval(of: .month, for: date) else {
            throw FinanceError.invalidField("月份")
        }
        func inMonth(_ date: Date) -> Bool { date >= month.start && date < month.end }
        let monthEntries = entries.filter { inMonth($0.date) }
        let monthEntryIDs = Set(monthEntries.map(\.id))
        let totals = LedgerTotals(entries: monthEntries)
        let wages = payroll.filter { $0.netCents == 0 ? inMonth($0.date) : monthEntryIDs.contains($0.entryID) }
        let movements = savingsMovements.filter { inMonth($0.date) }
        let monthReceipts = receipts.filter { monthEntryIDs.contains($0.entryID) }
        let groups = Dictionary(grouping: monthReceipts, by: { $0.merchant.id })
        let merchantTotals = groups.values.compactMap { group -> MerchantMonthlyTotal? in
            guard let first = group.first else { return nil }
            return MerchantMonthlyTotal(
                merchant: first.merchant,
                expenseCents: group.reduce(Decimal.zero) { $0 + Decimal($1.totalCents) },
                receiptCount: group.count
            )
        }.sorted {
            $0.expenseCents == $1.expenseCents ? $0.merchant.id < $1.merchant.id : $0.expenseCents > $1.expenseCents
        }
        var businessTypes: [String: Decimal] = [:]
        for receipt in monthReceipts {
            businessTypes[receipt.merchant.businessType, default: 0] += Decimal(receipt.totalCents)
        }
        let receiptEntryIDs = Set(monthReceipts.map(\.entryID))
        return MonthlyFinanceSummary(
            incomeCents: totals.incomeCents, expenseCents: totals.expenseCents,
            grossPayrollCents: wages.reduce(0) { $0 + Decimal($1.grossCents) },
            withheldTaxCents: wages.reduce(0) { $0 + Decimal($1.withheldTaxCents) },
            otherPayrollDeductionCents: wages.reduce(0) { $0 + Decimal($1.otherDeductionCents) },
            netPayrollCents: wages.reduce(0) { $0 + Decimal($1.netCents) },
            depositedCents: movements.filter { $0.direction == .deposit }.reduce(0) { $0 + Decimal($1.amountCents) },
            withdrawnCents: movements.filter { $0.direction == .withdrawal }.reduce(0) { $0 + Decimal($1.amountCents) },
            merchantTotals: merchantTotals, businessTypeTotals: businessTypes,
            unassignedExpenseCents: monthEntries.filter { $0.kind == .expense && !receiptEntryIDs.contains($0.id) }
                .reduce(0) { $0 + Decimal($1.amountCents) }
        )
    }

    public func validate() throws {
        try bankImports.validate(entries: entries)
        guard targetCNYCents > 0, targetCNYCents <= Money.maximumCents,
              Set(entries.map(\.id)).count == entries.count,
              Set(receipts.map(\.id)).count == receipts.count,
              Set(receipts.map(\.entryID)).count == receipts.count,
              Set(payroll.map(\.id)).count == payroll.count,
              Set(payroll.map(\.entryID)).count == payroll.count,
              Set(merchants.map(\.id)).count == merchants.count else { throw FinanceError.inconsistentBook }
        for entry in entries { try validateEntry(entry) }
        var merchantKeys: Set<String> = []
        for merchant in merchants {
            try validateMerchant(merchant)
            guard merchantKeys.isDisjoint(with: merchant.keys) else { throw FinanceError.ambiguousMerchant }
            merchantKeys.formUnion(merchant.keys)
        }
        let fingerprints = receipts.compactMap(\.imageFingerprint)
        guard Set(fingerprints).count == fingerprints.count else { throw FinanceError.duplicateReceipt }
        for receipt in receipts {
            try validateReceipt(receipt)
            guard merchants.contains(where: { $0.id == receipt.merchant.id }),
                  let entry = entries.first(where: { $0.id == receipt.entryID }),
                  entry.kind == .expense, entry.amountCents == receipt.totalCents else {
                throw FinanceError.inconsistentBook
            }
        }
        for record in payroll {
            try record.validate()
            let entry = entries.first { $0.id == record.entryID }
            guard record.netCents == 0 ? entry == nil :
                    (entry?.kind == .income && entry?.amountCents == record.netCents
                     && (record.linkedEntryID != nil || entry?.date == record.date))
            else { throw FinanceError.inconsistentBook }
        }
        for entry in entries {
            if entry.id.hasPrefix("receipt-"), !receipts.contains(where: { $0.entryID == entry.id }) {
                throw FinanceError.inconsistentBook
            }
            if entry.id.hasPrefix("payroll-"), !payroll.contains(where: { $0.entryID == entry.id }) {
                throw FinanceError.inconsistentBook
            }
        }
        if let opening = savingsOpening {
            guard (0...Money.maximumCents).contains(opening.amountCents),
                  opening.date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("初始存款") }
            try validateSavings(opening: opening, movements: savingsMovements)
        } else if !savingsMovements.isEmpty { throw FinanceError.savingsNotConfigured }
        try exchangeRate?.validate()
    }

    private func validateEntry(_ entry: LedgerEntry) throws {
        guard !entry.id.isEmpty, entry.amountCents > 0, entry.amountCents <= Money.maximumCents,
              !entry.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.date.timeIntervalSince1970.isFinite else { throw FinanceError.invalidField("收支记录") }
    }

    private func validateMerchant(_ merchant: MerchantProfile) throws {
        guard !merchant.id.isEmpty, !MerchantProfile.key(merchant.name).isEmpty,
              !merchant.businessType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, merchant.name.count <= 100,
              merchant.businessType.count <= 100, !merchant.keys.contains("") else {
            throw FinanceError.invalidField("商家名称、类型或别名")
        }
    }

    private func validateReceipt(_ receipt: ConfirmedReceipt) throws {
        try validateMerchant(receipt.merchant)
        guard !receipt.id.isEmpty, receipt.totalCents > 0, receipt.totalCents <= Money.maximumCents,
              (0...receipt.totalCents).contains(receipt.taxCents),
              receipt.date.timeIntervalSince1970.isFinite,
              receipt.items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && (0...Money.maximumCents).contains($0.lineTotalCents) }),
              receipt.adjustments.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && (-Money.maximumCents...Money.maximumCents).contains($0.amountCents) })
        else { throw FinanceError.invalidField("已核对的收据金额或明细") }
    }

    private func validateSavings(opening: SavingsOpening, movements: [SavingsMovement]) throws {
        guard Set(movements.map(\.id)).count == movements.count else { throw FinanceError.duplicateID }
        guard movements.allSatisfy({ !$0.id.isEmpty && $0.amountCents > 0 && $0.amountCents <= Money.maximumCents
            && $0.date.timeIntervalSince1970.isFinite }) else { throw FinanceError.invalidField("存款流水") }
        guard movements.allSatisfy({ $0.date >= opening.date }) else { throw FinanceError.savingsBeforeOpening }
        var balance = Decimal(opening.amountCents)
        // Equal timestamps have no defined order; validate the net movement at that instant.
        let groups = Dictionary(grouping: movements, by: \.date)
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            balance += group.reduce(Decimal.zero) {
                $0 + ($1.direction == .deposit ? Decimal($1.amountCents) : -Decimal($1.amountCents))
            }
            guard balance >= 0 else { throw FinanceError.insufficientSavings }
        }
    }
}

private struct HouseholdBookEnvelope: Codable {
    let version: Int
    let currency: Currency
    let book: HouseholdBook
}
