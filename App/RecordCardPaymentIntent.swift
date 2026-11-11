import AppIntents
import Foundation

/// The action to add to a Shortcuts "Wallet" (transaction) automation. It runs inside this app on the
/// phone; nothing is sent anywhere. Local files stay readable while the phone is locked after first unlock.
struct RecordCardPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "记录刷卡交易"
    static let description = IntentDescription(
        "把刚完成的刷卡付款记入家庭账本，标记为自动记录。通常放在快捷指令的“钱包”自动化里。"
    )
    static let openAppWhenRun = false

    @Parameter(title: "金额", description: "自动化提供的付款金额，例如 12.34")
    var amount: String

    @Parameter(title: "商店", description: "自动化提供的商家名称")
    var merchant: String

    static var parameterSummary: some ParameterSummary {
        Summary("记录 \(\.$amount) 在 \(\.$merchant)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch LedgerStore.shared.capturePurchase(amountText: amount, merchant: merchant) {
        case .recorded(let category):
            return .result(dialog: "已记录 \(amount) · \(merchant)（\(category)）")
        case .duplicate:
            return .result(dialog: "这笔付款刚刚已经记录过，已跳过")
        case .failed(let message):
            throw CaptureError.failed(message)
        }
    }
}

enum CaptureError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let message): "\(message)"
        }
    }
}

struct FriendLedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordCardPaymentIntent(),
            phrases: ["用 \(.applicationName) 记录刷卡交易"],
            shortTitle: "记录刷卡交易",
            systemImageName: "creditcard"
        )
    }
}
