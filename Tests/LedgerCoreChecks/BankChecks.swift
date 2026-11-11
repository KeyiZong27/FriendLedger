import Foundation
import FriendLedgerCore

func testBankTransaction(_ id: String, account: String = "account-a", source: BankImportSource = .wallet,
                         cents: Int64 = 1250, kind: EntryKind = .expense, date: Date,
                         status: BankTransactionStatus = .booked) -> BankTransaction {
    BankTransaction(source: source, accountID: account, transactionID: id, date: date,
                    amountCents: cents, kind: kind, description: "测试银行记录", status: status)
}

@MainActor
func runBankChecks() throws {
    var calendar = Calendar(identifier: .gregorian)
    guard let zone = TimeZone(identifier: "America/Los_Angeles") else { throw CheckFailure.failed("Missing timezone") }
    calendar.timeZone = zone
    let date = try localDate(2025, 3, 10, calendar: calendar)
    let previousMonth = try localDate(2025, 2, 28, calendar: calendar)
    let transaction = testBankTransaction("transaction-1", date: date)
    let different = testBankTransaction("transaction-2", date: date)
    var book = HouseholdBook()
    let first = try book.importBankTransactions(BankImportBatch(transactions: [transaction, different]), calendar: calendar)
    try check(first.reviewCount == 2 && first.duplicateCount == 0, "Equal dates and amounts are not definite duplicates")
    try check(book.entries.isEmpty && book.bankImports.records.count == 2, "Import must queue evidence, not invent cash entries")
    try book.resolveBankTransaction(id: transaction.id, action: .createEntry(category: "餐饮", author: "成员 A", note: "核对后入账"))
    try book.resolveBankTransaction(id: different.id, action: .createEntry(category: "交通", author: "成员 B", note: "另一笔"))
    try check(book.entries.count == 2, "Two equal real purchases must both be retained")
    let repeated = try book.importBankTransactions(BankImportBatch(transactions: [transaction, different]), calendar: calendar)
    try check(repeated.duplicateCount == 2 && book.entries.count == 2, "Stable bank IDs must skip repeat imports")
    try check(book.bankImports.reports.count == 2, "Skipped rows must retain an import report")
    let continued = try book.importBankTransactions(BankImportBatch(
        transactions: [transaction, testBankTransaction("after-duplicate", cents: 99, date: date)]
    ), calendar: calendar)
    try check(continued.duplicateCount == 1 && continued.reviewCount == 1,
              "A definite duplicate must not stop the next row")
    try expectFinanceError(.invalidField("核对状态，只有未解决的交易可以确认")) {
        try book.resolveBankTransaction(id: transaction.id, action: .createEntry(category: "其他", author: "成员 A", note: ""))
    }
    let otherAccount = testBankTransaction("transaction-1", account: "account-b", date: date)
    let otherSource = testBankTransaction("transaction-1", source: .statement, date: date)
    let scoped = try book.importBankTransactions(BankImportBatch(transactions: [otherAccount, otherSource]), calendar: calendar)
    try check(scoped.reviewCount == 2 && scoped.duplicateCount == 0, "Identifiers are scoped by account and channel")
    try check(try book.bankImports.candidates(for: otherAccount.id, entries: book.entries, calendar: calendar).count == 2,
              "Equal dates and amounts should be review candidates, not silently dropped")

    var pendingBook = HouseholdBook()
    let pending = testBankTransaction("pending-to-booked", cents: 1000, date: date, status: .pending)
    let pendingReport = try pendingBook.importBankTransactions(BankImportBatch(transactions: [pending]), calendar: calendar)
    try check(pendingReport.outcomes[0].disposition == .bankPending && pendingBook.entries.isEmpty,
              "Pending authorizations do not count as expenses")
    try expectFinanceError(.invalidField("银行入账状态或已变化的原关联账目")) {
        try pendingBook.resolveBankTransaction(id: pending.id, action: .createEntry(category: "其他", author: "成员 A", note: ""))
    }
    let booked = testBankTransaction("pending-to-booked", cents: 1200, date: date)
    let bookedReport = try pendingBook.importBankTransactions(BankImportBatch(transactions: [booked]), calendar: calendar)
    try check(bookedReport.reviewCount == 1 && bookedReport.duplicateCount == 0
              && pendingBook.bankImports.records.count == 1, "Posted amount must replace pending evidence without a new identity")
    try pendingBook.resolveBankTransaction(id: booked.id, action: .createEntry(category: "餐饮", author: "成员 A", note: ""))
    let changed = testBankTransaction("pending-to-booked", cents: 1500, date: date)
    let changeReport = try pendingBook.importBankTransactions(BankImportBatch(transactions: [changed]), calendar: calendar)
    try check(changeReport.outcomes[0].disposition == .changedNeedsReview && pendingBook.entries[0].amountCents == 1200,
              "Bank corrections must not quietly overwrite confirmed cash entries")
    try check(pendingBook.bankImports.records[0].previousEntryID == pendingBook.entries[0].id,
              "Changed bank evidence must retain its original association for review")
    try expectFinanceError(.invalidField("银行入账状态或已变化的原关联账目")) {
        try pendingBook.resolveBankTransaction(id: changed.id, action: .createEntry(category: "餐饮", author: "成员 A", note: ""))
    }
    let restoreReport = try pendingBook.importBankTransactions(BankImportBatch(transactions: [booked]), calendar: calendar)
    try check(restoreReport.reviewCount == 1, "A restored transaction still requires confirmation")
    try pendingBook.resolveBankTransaction(id: booked.id, action: .linkExistingEntry(id: pendingBook.entries[0].id))
    try check(pendingBook.entries.count == 1, "Reconfirming restored evidence must not duplicate the original expense")
    try pendingBook.removeEntry(id: pendingBook.entries[0].id)
    try check(pendingBook.bankImports.records[0].resolution == .unresolved,
              "Deleting cash entries must reopen linked bank evidence")
    try pendingBook.validate()

    var receiptBook = HouseholdBook()
    let merchant = MerchantProfile(id: "shop", name: "Test Store", businessType: "超市")
    try receiptBook.saveMerchant(merchant)
    let draft = try ReceiptTextParser.parse("TEST STORE\nTOTAL 12.50")
    let receipt = try receiptBook.confirmReceipt(draft, review: ReceiptReview(
        merchantID: merchant.id, totalCents: 1250, items: [], date: date, author: "成员 A"
    ), calendar: calendar)
    let receiptImport = try receiptBook.importBankTransactions(BankImportBatch(transactions: [transaction]), calendar: calendar)
    try check(receiptImport.outcomes[0].candidateEntryIDs == [receipt.entryID], "Bank evidence should find the existing receipt")
    try receiptBook.resolveBankTransaction(id: transaction.id, action: .linkExistingEntry(id: receipt.entryID))
    try check(receiptBook.entries.count == 1, "Receipt first, bank second must remain one expense")

    var bankFirst = HouseholdBook()
    try bankFirst.saveMerchant(merchant)
    _ = try bankFirst.importBankTransactions(BankImportBatch(transactions: [transaction]), calendar: calendar)
    try bankFirst.resolveBankTransaction(id: transaction.id, action: .createEntry(category: "其他", author: "成员 A", note: ""))
    let paymentID = bankFirst.entries[0].id
    _ = try bankFirst.confirmReceipt(draft, review: ReceiptReview(
        merchantID: merchant.id, totalCents: 1250, items: [ReceiptItem(name: "商品", lineTotalCents: 1250)],
        date: previousMonth, author: "成员 A"
    ), calendar: calendar, existingEntryID: paymentID)
    try check(bankFirst.entries.count == 1 && bankFirst.receipts[0].entryID == paymentID,
              "Bank first, receipt second must attach details without adding another expense")
    let bankFirstMonth = try bankFirst.monthlySummary(containing: date, calendar: calendar)
    try check(bankFirstMonth.expenseCents == 1250 && bankFirstMonth.businessTypeTotals["超市"] == 1250,
              "Merchant analysis follows the confirmed payment month even when receipt dates differ")
    try bankFirst.validate()

    var wageBook = HouseholdBook()
    let wage = PayrollRecord(id: "salary", member: "成员 A", date: date,
        grossCents: 100000, withheldTaxCents: 20000, otherDeductionCents: 10000, netCents: 70000)
    try wageBook.addPayroll(wage)
    let wageTransaction = testBankTransaction("salary-deposit", cents: 70000, kind: .income, date: date)
    _ = try wageBook.importBankTransactions(BankImportBatch(transactions: [wageTransaction]), calendar: calendar)
    try wageBook.resolveBankTransaction(id: wageTransaction.id, action: .linkExistingEntry(id: wage.entryID))
    try check(try wageBook.monthlySummary(containing: date, calendar: calendar).incomeCents == 70000,
              "Bank salary confirmation must not add a second income")
    var bankWageFirst = HouseholdBook()
    _ = try bankWageFirst.importBankTransactions(BankImportBatch(transactions: [wageTransaction]), calendar: calendar)
    try bankWageFirst.resolveBankTransaction(id: wageTransaction.id,
        action: .createEntry(category: "工资", author: "成员 A", note: "到账"))
    try bankWageFirst.addPayroll(PayrollRecord(id: "full-salary", member: "成员 A", date: previousMonth,
        grossCents: 100000, withheldTaxCents: 20000, otherDeductionCents: 10000, netCents: 70000,
        linkedEntryID: bankWageFirst.entries[0].id))
    let linkedWageMonth = try bankWageFirst.monthlySummary(containing: date, calendar: calendar)
    try check(linkedWageMonth.incomeCents == 70000 && linkedWageMonth.netPayrollCents == 70000,
              "Later payroll details should use existing bank income and the same cash month")
    try bankWageFirst.validate()
    try bankWageFirst.removePayroll(id: "full-salary")
    try check(bankWageFirst.bankImports.records[0].resolution == .unresolved, "Removing linked payroll reopens bank evidence")
    let transfer = testBankTransaction("card-payment", cents: 50000, date: date)
    _ = try wageBook.importBankTransactions(BankImportBatch(transactions: [transfer]), calendar: calendar)
    try wageBook.resolveBankTransaction(id: transfer.id, action: .exclude(reason: "信用卡还款，原消费已记账"))
    try check(wageBook.entries.count == 1, "Card repayment must be excludable without a false expense")
    try check(wageBook.bankImports.records.last?.resolution == .excluded(reason: "信用卡还款，原消费已记账"),
              "Exclusions must retain their reason")
    let rejected = testBankTransaction("rejected", date: date, status: .rejected)
    let rejectedReport = try wageBook.importBankTransactions(BankImportBatch(transactions: [rejected]), calendar: calendar)
    try check(rejectedReport.outcomes[0].disposition == .bankRejected && wageBook.entries.count == 1,
              "Rejected transactions must not enter cash accounting")

    let mapping = BankCSVMapping(accountID: "statement-account", dateColumn: "Date", dateFormat: "yyyy-MM-dd",
        descriptionColumn: "Description", amountColumns: .signed(column: "Amount", meaning: .negativeIsExpense),
        transactionIDColumn: "ID", currencyColumn: "Currency", timeZone: zone)
    let csv = #"""
    Date,Description,Amount,ID,Currency
    2025-03-10,"Shop, ""Corner""","-$1,234.56",csv-1,USD
    2025-03-10,Salary,700.00,csv-2,USD
    2025-02-30,Bad date,-1.00,csv-3,USD
    2025-03-10,Bad amount,NaN,csv-4,USD
    2025-03-10,Zero,0.00,csv-5,USD
    2025-03-10,Wrong currency,1.00,csv-6,CNY
    2025-03-10,"Two
    lines",(12.50),csv-7,USD
    """#
    let parsed = try BankCSVImporter.parse(Data(csv.utf8), mapping: mapping)
    try check(parsed.transactions.count == 3 && parsed.issues.count == 4, "Bad CSV rows must be reported while valid rows continue")
    try check(parsed.transactions[0].amountCents == 123456 && parsed.transactions[0].kind == .expense
              && parsed.transactions[0].description == "Shop, \"Corner\"", "CSV quoting, grouping, and signs must be exact")
    try check(parsed.transactions[1].kind == .income && parsed.transactions[1].amountCents == 70000,
              "Signed bank direction mapping must be explicit")
    try check(parsed.transactions[2].description == "Two\nlines" && parsed.transactions[2].amountCents == 1250,
              "Multiline CSV and parenthesized expenses must parse")
    var csvBook = HouseholdBook()
    let parsedReport = try csvBook.importBankTransactions(parsed, calendar: calendar)
    try check(parsedReport.issues.count == 4 && parsedReport.reviewCount == 3, "Import reports must preserve parsing errors")
    let csvRepeat = try csvBook.importBankTransactions(parsed, calendar: calendar)
    try check(csvRepeat.duplicateCount == 3 && csvBook.bankImports.records.count == 3, "CSV IDs must prevent repeat ingestion")
    let separateMapping = BankCSVMapping(accountID: "separate-account", dateColumn: "Date", dateFormat: "MM/dd/yyyy",
        descriptionColumn: "Memo", amountColumns: .separate(expense: "Debit", income: "Credit"), timeZone: zone)
    let separateCSV = "Date,Memo,Debit,Credit\r\n03/10/2025,Shop,12.50,\r\n03/10/2025,Salary,,700.00\r\n03/10/2025,Both,1,2\r\n"
    let separate = try BankCSVImporter.parse(Data(separateCSV.utf8), mapping: separateMapping)
    try check(separate.transactions.count == 2 && separate.issues.count == 1, "Separate debit/credit columns must reject double amounts")
    let rowRepeat = try csvBook.importBankTransactions(separate, calendar: calendar)
    let rowAgain = try csvBook.importBankTransactions(separate, calendar: calendar)
    try check(rowRepeat.reviewCount == 2 && rowAgain.duplicateCount == 2, "Same file and row are definite repeat imports without bank IDs")
    let overlapping = try BankCSVImporter.parse(Data(separateCSV.replacingOccurrences(of: "Shop", with: "SHOP").utf8),
                                               mapping: separateMapping)
    let overlapReport = try csvBook.importBankTransactions(overlapping, calendar: calendar)
    try check(overlapReport.reviewCount == 2 && overlapReport.duplicateCount == 0,
              "Overlapping files without stable bank IDs must be reviewed, not silently discarded")
    let withBOM = try BankCSVImporter.parse(Data(("\u{FEFF}" + separateCSV).utf8), mapping: separateMapping)
    try check(withBOM.transactions.count == 2 && withBOM.issues.count == 1, "UTF-8 BOM must not break header mapping")
    try expectFinanceError(.invalidField("银行文件格式，当前只支持 CSV，尚未支持 PDF 或 Excel")) {
        _ = try BankCSVImporter.parse(Data("%PDF-1.7".utf8), mapping: mapping)
    }
    try expectFinanceError(.invalidField("银行文件格式，当前只支持 CSV，尚未支持 PDF 或 Excel")) {
        _ = try BankCSVImporter.parse(Data([0x50, 0x4B, 0x03, 0x04]), mapping: mapping)
    }
    try expectFinanceError(.invalidField("CSV 引号未闭合")) {
        _ = try BankCSVImporter.parse(Data("Date,Memo,Debit,Credit\n03/10/2025,\"broken,1,0".utf8), mapping: separateMapping)
    }
    let positiveMapping = BankCSVMapping(accountID: "card-account", dateColumn: "Date", dateFormat: "MM/dd/yyyy",
        descriptionColumn: "Memo", amountColumns: .signed(column: "Amount", meaning: .positiveIsExpense), timeZone: zone)
    let positive = try BankCSVImporter.parse(Data("Date,Memo,Amount\n03/10/2025,Shop,12.50\n03/10/2025,Refund,-2.00".utf8),
                                            mapping: positiveMapping)
    try check(positive.transactions.map(\.kind) == [.expense, .income], "Credit card positive-debit conventions must be configurable")

    let archive = try bankFirst.encoded()
    try check(try HouseholdBook.decode(archive).encoded() == archive, "Bank associations and reports must survive persistence")
    var legacy = HouseholdBook()
    try legacy.addPayroll(wage)
    guard var envelope = try JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any],
          var originalBook = envelope["book"] as? [String: Any] else { throw CheckFailure.failed("Invalid archive fixture") }
    originalBook.removeValue(forKey: "bankImports")
    envelope["book"] = originalBook
    let migrated = try HouseholdBook.decode(JSONSerialization.data(withJSONObject: envelope))
    try check(migrated.payroll.count == 1 && migrated.bankImports.records.isEmpty, "Old snapshots must decode without inventing bank records")
    var atomic = HouseholdBook()
    try expectFinanceError(.invalidField("银行交易标识、币种、日期或金额")) {
        _ = try atomic.importBankTransactions(BankImportBatch(transactions: [
            transaction, testBankTransaction("invalid", cents: 0, date: date)
        ]), calendar: calendar)
    }
    try check(atomic.bankImports.records.isEmpty && atomic.bankImports.reports.isEmpty,
              "Invalid normalized input must not partially mutate the bank ledger")
    guard let exact = Decimal(string: "12.50"), let fractional = Decimal(string: "12.501") else {
        throw CheckFailure.failed("Invalid decimal fixtures")
    }
    try check(try Money.exactCents(amount: exact) == 1250, "FinanceKit Decimal amounts must become exact cents")
    do {
        _ = try Money.exactCents(amount: fractional)
        throw CheckFailure.failed("Fractional cents were accepted")
    } catch let error as AmountError { try check(error == .invalid, "Never round a bank amount silently") }
}
