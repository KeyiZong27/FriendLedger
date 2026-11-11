import Foundation
#if canImport(FinanceKit) && os(iOS)
import FinanceKit
#endif

enum WalletImportError: LocalizedError {
    case requiresApproval
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Wallet 导入尚未启用，需要先获得 Apple FinanceKit 权限审批并完成签名配置。"
        case .unavailable:
            "此设备或 Wallet 账户没有可用的 FinanceKit 数据，需要 iOS 17.4 及受支持账户。"
        case .denied:
            "未获得读取金融数据的授权，未导入任何 Wallet 交易。"
        }
    }
}

enum WalletTransactionImporter {
    @MainActor
    static func fetch() async throws -> BankImportBatch {
        guard Bundle.main.object(forInfoDictionaryKey: "WalletImportEnabled") as? Bool == true else {
            throw WalletImportError.requiresApproval
        }
        #if canImport(FinanceKit) && os(iOS)
        guard #available(iOS 17.4, *), FinanceStore.isDataAvailable(.financialData) else {
            throw WalletImportError.unavailable
        }
        let store = FinanceStore.shared
        guard try await store.requestAuthorization() == .authorized else { throw WalletImportError.denied }
        // An unlimited query avoids quietly truncating the user's authorized transaction range.
        let transactions = try await store.transactions(query: TransactionQuery())
        var imported: [BankTransaction] = []
        var issues: [BankImportIssue] = []
        for (index, transaction) in transactions.enumerated() {
            do {
                guard transaction.transactionAmount.currencyCode == "USD" else {
                    throw FinanceError.invalidField("Wallet 交易币种，当前只支持 USD")
                }
                let kind: EntryKind
                switch transaction.creditDebitIndicator {
                case .credit: kind = .income
                case .debit: kind = .expense
                @unknown default: throw FinanceError.invalidField("Wallet 交易收支方向")
                }
                let status: BankTransactionStatus
                switch transaction.status {
                case .booked: status = .booked
                case .authorized, .memo, .pending: status = .pending
                case .rejected: status = .rejected
                @unknown default: throw FinanceError.invalidField("Wallet 交易状态")
                }
                let amount = transaction.transactionAmount.amount
                let record = BankTransaction(
                    source: .wallet, accountID: transaction.accountID.uuidString,
                    transactionID: transaction.id.uuidString, date: transaction.transactionDate,
                    postedDate: transaction.postedDate,
                    amountCents: try Money.exactCents(amount: amount < 0 ? -amount : amount),
                    kind: kind, description: transaction.transactionDescription, status: status
                )
                imported.append(record)
            } catch let error as FinanceError {
                issues.append(BankImportIssue(row: index + 1, message: error.localizedDescription))
            } catch let error as AmountError {
                issues.append(BankImportIssue(row: index + 1, message: error.localizedDescription))
            }
        }
        return BankImportBatch(transactions: imported, issues: issues)
        #else
        throw WalletImportError.unavailable
        #endif
    }
}
