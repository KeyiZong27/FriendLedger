import PhotosUI
import SwiftUI
import UIKit
import VisionKit

enum ReceiptSource {
    case pages([Data])
    case library(PhotosPickerItem)
}

struct ReceiptImageItem: Identifiable {
    let id = UUID()
    let source: ReceiptSource
}

struct DocumentScanner: UIViewControllerRepresentable {
    let onPages: ([Data]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<min(scan.pageCount, 6)).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9) }
            if pages.isEmpty { parent.onCancel() } else { parent.onPages(pages) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

struct ReceiptReviewView: View {
    private enum Phase {
        case working(String)
        case failed(String)
        case ready(ReceiptDraft)
    }

    private enum TypeSource {
        case remembered, guessed, unknown, chosen
    }

    @ObservedObject var store: LedgerStore
    let recordID: String
    let image: ReceiptImageItem
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.working("正在读取照片…")
    @State private var merchantName = ""
    @State private var businessType = "其他"
    @State private var typeSource = TypeSource.unknown
    @State private var amountText = ""
    @State private var date = Date()
    @State private var message: String?
    @State private var confirmingDuplicate = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("识别收据")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    if case .ready = phase {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { save(allowDuplicate: false) }
                                .disabled(store.isMutating).accessibilityIdentifier("save-receipt")
                        }
                    }
                }
        }
        .task { await recognize() }
        .alert("可能重复", isPresented: $confirmingDuplicate) {
            Button("确认是另一张，仍然保存") { save(allowDuplicate: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已有同商店、同一天、同金额的收据。")
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .working(let text):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).accessibilityIdentifier("receipt-progress")
                Text(text).foregroundStyle(.secondary)
                Text("识别在手机本机完成，不上传照片。").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let text):
            ContentUnavailableView(
                "没有识别成功", systemImage: "doc.text.magnifyingglass",
                description: Text("\(text)\n可以重新拍照，或返回后选择手动输入。")
            )
            .accessibilityIdentifier("receipt-failed")
        case .ready(let draft):
            form(draft)
        }
    }

    private func form(_ draft: ReceiptDraft) -> some View {
        Form {
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("receipt-error") }
            }
            let problems = draft.checks.problems
            if !draft.checks.confirmations.isEmpty || !problems.isEmpty {
                Section {
                    ForEach(draft.checks.confirmations, id: \.self) {
                        Label($0, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                    }
                    ForEach(problems, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("自动核对")
                } footer: {
                    Text("这是自动交叉检查，不能代替你对照小票确认。")
                }
                .accessibilityIdentifier("receipt-checks")
            }
            Section {
                HStack {
                    TextField("商店名称", text: $merchantName)
                        .accessibilityIdentifier("receipt-merchant")
                        .onChange(of: merchantName) { _, _ in refreshType(draft) }
                    badge(typeSource == .remembered ? .high : draft.checks.merchant)
                }
                Picker("分类", selection: Binding(
                    get: { businessType },
                    set: { businessType = $0; typeSource = .chosen }
                )) {
                    ForEach(typeOptions, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("receipt-type")
                Text(typeHint).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("receipt-type-hint")
            } header: {
                Text("商店")
            }
            Section {
                HStack {
                    TextField("总额（美元）", text: $amountText).keyboardType(.decimalPad)
                        .accessibilityIdentifier("receipt-amount")
                    badge(draft.checks.total)
                }
                let candidates = Array(Set(draft.totalCandidates.map(\.amountCents))).sorted()
                if candidates.count > 1 {
                    ForEach(candidates, id: \.self) { cents in
                        Button("使用 \(Money.format(cents: Decimal(cents), currency: .usd))") {
                            amountText = Self.plain(cents)
                        }
                    }
                }
                HStack {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    badge(draft.checks.date)
                }
            } header: {
                Text("金额与日期")
            } footer: {
                Text("将以“\(store.nickname)”记一笔支出；商品明细仅用于分析，不会重复记账。")
            }
            if !draft.suggestedItems.isEmpty || draft.suggestedTaxCents != nil {
                Section("识别到的明细") {
                    ForEach(Array(draft.suggestedItems.enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.name, value: Money.format(cents: Decimal(item.lineTotalCents), currency: .usd))
                    }
                    if let tax = draft.suggestedTaxCents {
                        LabeledContent("税", value: Money.format(cents: Decimal(tax), currency: .usd))
                    }
                }
            }
            let extraWarnings = draft.warnings.dropFirst().filter { !$0.contains("TOTAL") && !$0.contains("多个不同总额") }
            if !extraWarnings.isEmpty {
                Section("请核对") {
                    ForEach(extraWarnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                }
            }
        }
    }

    @ViewBuilder private func badge(_ level: ReceiptConfidence) -> some View {
        switch level {
        case .high:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("识别可信度高")
        case .medium:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("识别可信度一般，请核对")
        case .low:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("识别可信度低，请核对")
        }
    }

    private var typeOptions: [String] {
        MerchantTypeClassifier.types.contains(businessType)
            ? MerchantTypeClassifier.types : MerchantTypeClassifier.types + [businessType]
    }

    private var typeHint: String {
        switch typeSource {
        case .remembered: "已记住这家商店，自动使用之前的分类。"
        case .guessed: "已自动判断，可在不对时修改一次，下次会记住。"
        case .unknown: "未能判断，请选择一次，下次会记住。"
        case .chosen: "保存后会记住这家商店的分类。"
        }
    }

    private static func plain(_ cents: Int64) -> String {
        String(format: "%lld.%02lld", cents / 100, cents % 100)
    }

    private func recognize() async {
        do {
            let pages: [Data]
            switch image.source {
            case .pages(let scanned): pages = scanned
            case .library(let item):
                guard let bytes = try await item.loadTransferable(type: Data.self) else {
                    phase = .failed("无法读取所选照片。")
                    return
                }
                pages = [bytes]
            }
            phase = .working("正在优化图片并在本机识别…")
            let draft = try await LocalReceiptRecognizer.recognize(pages: pages)
            merchantName = draft.suggestedMerchantName ?? ""
            if let cents = draft.suggestedTotalCents { amountText = Self.plain(cents) }
            if let day = draft.suggestedDay,
               let detected = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) {
                date = detected
            }
            refreshType(draft)
            phase = .ready(draft)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func refreshType(_ draft: ReceiptDraft) {
        guard typeSource != .chosen else { return }
        if let known = store.record(id: recordID)?.book.merchant(matching: merchantName) {
            businessType = known.businessType
            typeSource = .remembered
        } else if let guess = MerchantTypeClassifier.suggest(
            merchantName: merchantName, itemNames: draft.suggestedItems.map(\.name)
        ) {
            businessType = guess
            typeSource = .guessed
        } else {
            businessType = "其他"
            typeSource = .unknown
        }
    }

    private func save(allowDuplicate: Bool) {
        guard case .ready(let draft) = phase else { return }
        let cents: Int64
        do { cents = try Money.parse(amountText) }
        catch {
            message = error.localizedDescription
            return
        }
        let submission = ReceiptSubmission(
            merchantName: merchantName, businessType: businessType, totalCents: cents, date: date,
            author: store.nickname, allowPossibleDuplicate: allowDuplicate
        )
        switch store.saveReceipt(draft, submission, recordID: recordID) {
        case .saved: dismiss()
        case .possibleDuplicate: confirmingDuplicate = true
        case .failed(let text): message = text
        }
    }
}

#if DEBUG
/// UI tests cannot drive the system camera or the out-of-process photo picker, so a test profile
/// can feed this synthetic receipt through the same Vision recognizer used for real photos.
enum SampleReceipt {
    static func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000))
        return renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Helvetica", size: 48) ?? UIFont.systemFont(ofSize: 48),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in ["TRADER JOES", "11/10/2026", "MILK 4.00", "BREAD 3.00",
                                  "SUBTOTAL 7.00", "TAX 0.56", "TOTAL 7.56"].enumerated() {
                line.draw(at: CGPoint(x: 70, y: 70 + index * 120), withAttributes: attributes)
            }
        }
    }
}
#endif
