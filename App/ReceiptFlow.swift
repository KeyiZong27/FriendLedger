import PhotosUI
import SwiftUI
import UIKit

enum ReceiptSource {
    case data(Data)
    case library(PhotosPickerItem)
}

struct ReceiptImageItem: Identifiable {
    let id = UUID()
    let source: ReceiptSource
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
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
            Section {
                TextField("商店名称", text: $merchantName)
                    .accessibilityIdentifier("receipt-merchant")
                    .onChange(of: merchantName) { _, _ in refreshType(draft) }
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
                TextField("总额（美元）", text: $amountText).keyboardType(.decimalPad)
                    .accessibilityIdentifier("receipt-amount")
                let candidates = Array(Set(draft.totalCandidates.map(\.amountCents))).sorted()
                if candidates.count > 1 {
                    ForEach(candidates, id: \.self) { cents in
                        Button("使用 \(Money.format(cents: Decimal(cents), currency: .usd))") {
                            amountText = Self.plain(cents)
                        }
                    }
                }
                DatePicker("日期", selection: $date, displayedComponents: .date)
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
            if !draft.warnings.isEmpty {
                Section("请核对") {
                    ForEach(draft.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                }
            }
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
            let data: Data
            switch image.source {
            case .data(let bytes): data = bytes
            case .library(let item):
                guard let bytes = try await item.loadTransferable(type: Data.self) else {
                    phase = .failed("无法读取所选照片。")
                    return
                }
                data = bytes
            }
            phase = .working("正在本机识别收据…")
            let draft = try await LocalReceiptRecognizer.recognize(imageData: data)
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
