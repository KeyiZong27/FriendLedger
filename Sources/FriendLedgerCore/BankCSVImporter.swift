import CryptoKit
import Foundation

public enum SignedBankAmountMeaning: Sendable {
    case negativeIsExpense
    case positiveIsExpense
}

public enum BankAmountColumns: Sendable {
    case signed(column: String, meaning: SignedBankAmountMeaning)
    case separate(expense: String, income: String)
}

public struct BankCSVMapping: Sendable {
    public let accountID: String
    public let dateColumn: String
    public let dateFormat: String
    public let descriptionColumn: String
    public let amountColumns: BankAmountColumns
    public let transactionIDColumn: String?
    public let currencyColumn: String?
    public let timeZone: TimeZone

    public init(accountID: String, dateColumn: String, dateFormat: String, descriptionColumn: String,
                amountColumns: BankAmountColumns, transactionIDColumn: String? = nil,
                currencyColumn: String? = nil, timeZone: TimeZone) {
        self.accountID = accountID
        self.dateColumn = dateColumn
        self.dateFormat = dateFormat
        self.descriptionColumn = descriptionColumn
        self.amountColumns = amountColumns
        self.transactionIDColumn = transactionIDColumn
        self.currencyColumn = currencyColumn
        self.timeZone = timeZone
    }
}

public enum BankCSVImporter {
    public static func parse(_ data: Data, mapping: BankCSVMapping) throws -> BankImportBatch {
        guard !data.starts(with: Data("%PDF-".utf8)), !data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw FinanceError.invalidField("银行文件格式，当前只支持 CSV，尚未支持 PDF 或 Excel")
        }
        guard !mapping.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.dateFormat.isEmpty else { throw FinanceError.invalidField("银行 CSV 账户及日期映射") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FinanceError.invalidField("银行文件编码，当前只支持 UTF-8 CSV，不是 PDF 或 Excel")
        }
        let rows = try CSVRows.parse(text)
        guard let header = rows.first, rows.count > 1 else {
            throw FinanceError.invalidField("银行 CSV，至少需要表头和一条流水")
        }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(normalizedHeader).count == normalizedHeader.count else {
            throw FinanceError.invalidField("CSV 表头，存在重复列名")
        }
        func column(_ name: String) throws -> Int {
            guard let index = normalizedHeader.firstIndex(of: name) else {
                throw FinanceError.invalidField("CSV 列映射，缺少 \(name)")
            }
            return index
        }
        let dateColumn = try column(mapping.dateColumn)
        let descriptionColumn = try column(mapping.descriptionColumn)
        let idColumn = try mapping.transactionIDColumn.map(column)
        let currencyColumn = try mapping.currencyColumn.map(column)
        let signedColumn: Int?
        let separateColumns: (Int, Int)?
        switch mapping.amountColumns {
        case .signed(let name, _):
            signedColumn = try column(name)
            separateColumns = nil
        case .separate(let expense, let income):
            let indices = (try column(expense), try column(income))
            guard indices.0 != indices.1 else { throw FinanceError.invalidField("支出和收入不能映射到同一列") }
            separateColumns = indices
            signedColumn = nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = mapping.timeZone
        formatter.dateFormat = mapping.dateFormat
        formatter.isLenient = false
        let fileID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var transactions: [BankTransaction] = []
        var issues: [BankImportIssue] = []
        for (index, row) in rows.dropFirst().enumerated() {
            do {
                guard row.count == header.count else { throw FinanceError.invalidField("CSV 列数") }
                let dateValue = row[dateColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let date = formatter.date(from: dateValue), formatter.string(from: date) == dateValue else {
                    throw FinanceError.invalidField("流水日期，与指定格式不符")
                }
                if let currencyColumn {
                    guard row[currencyColumn].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "USD" else {
                        throw FinanceError.invalidField("流水币种，当前只支持 USD")
                    }
                }
                let amount: Int64
                let kind: EntryKind
                if let signedColumn, case .signed(_, let meaning) = mapping.amountColumns {
                    let parsed = try parseAmount(row[signedColumn])
                    guard parsed.cents > 0 else { throw FinanceError.invalidField("流水金额为零") }
                    amount = parsed.cents
                    switch meaning {
                    case .negativeIsExpense: kind = parsed.negative ? .expense : .income
                    case .positiveIsExpense: kind = parsed.negative ? .income : .expense
                    }
                } else if let separateColumns {
                    let expense = try parseAmount(row[separateColumns.0], emptyIsZero: true)
                    let income = try parseAmount(row[separateColumns.1], emptyIsZero: true)
                    guard !expense.negative, !income.negative,
                          (expense.cents > 0) != (income.cents > 0) else {
                        throw FinanceError.invalidField("流水支出和收入，必须且只能有一列为正数")
                    }
                    amount = max(expense.cents, income.cents)
                    kind = expense.cents > 0 ? .expense : .income
                } else { throw FinanceError.invalidField("流水金额列映射") }
                let transactionID = idColumn.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                if transactionID?.isEmpty == true { throw FinanceError.invalidField("银行交易编号为空") }
                let transaction = BankTransaction(
                    source: .statement, accountID: mapping.accountID, transactionID: transactionID,
                    importRowID: "\(fileID):\(index + 2)", date: date, amountCents: amount,
                    kind: kind, description: row[descriptionColumn]
                )
                try transaction.validate()
                transactions.append(transaction)
            } catch let error as FinanceError {
                issues.append(BankImportIssue(row: index + 2, message: error.localizedDescription))
            } catch let error as AmountError {
                issues.append(BankImportIssue(row: index + 2, message: error.localizedDescription))
            }
        }
        return BankImportBatch(transactions: transactions, issues: issues)
    }

    private static func parseAmount(_ raw: String, emptyIsZero: Bool = false) throws -> (cents: Int64, negative: Bool) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if emptyIsZero && text.isEmpty { return (0, false) }
        let parenthesized = text.hasPrefix("(") && text.hasSuffix(")")
        if parenthesized { text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        let sign = text.first
        if sign == "-" || sign == "+" { text.removeFirst() }
        if text.hasPrefix("$") { text.removeFirst() }
        guard !parenthesized || (sign != "-" && sign != "+") else { throw AmountError.invalid }
        if text.contains(",") {
            let pattern = try NSRegularExpression(pattern: #"^\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?$"#)
            guard pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil else {
                throw AmountError.invalid
            }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        return (try Money.parseNonnegative(text), parenthesized || sign == "-")
    }
}

private enum CSVRows {
    static func parse(_ input: String) throws -> [[String]] {
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var quoteClosed = false
        var index = 0
        func finishRow() {
            row.append(field)
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
            field = ""
            quoteClosed = false
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else { quoted = false; quoteClosed = true }
                } else { field.append(character) }
            } else if character == "," {
                row.append(field)
                field = ""
                quoteClosed = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                finishRow()
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else if character == "\"" {
                guard field.isEmpty, !quoteClosed else { throw FinanceError.invalidField("CSV 引号格式") }
                quoted = true
            } else {
                guard !quoteClosed else { throw FinanceError.invalidField("CSV 引号后的内容") }
                field.append(character)
            }
            index += 1
        }
        guard !quoted else { throw FinanceError.invalidField("CSV 引号未闭合") }
        if !field.isEmpty || !row.isEmpty || quoteClosed { finishRow() }
        return rows
    }
}
