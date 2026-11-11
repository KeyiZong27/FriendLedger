import Charts
import SwiftUI

private struct CategoryRoute: Hashable {
    let name: String
}

private struct MerchantRoute: Hashable {
    let category: String
    let key: String
}

private func dollars(_ cents: Int64) -> String {
    Money.format(cents: Decimal(cents), currency: .usd)
}

private func percent(_ share: Double) -> String {
    share.formatted(.percent.precision(.fractionLength(1)))
}

struct SpendingView: View {
    @ObservedObject var store: LedgerStore
    let recordID: String
    @Environment(\.dismiss) private var dismiss
    @State private var month = Date()

    private var book: HouseholdBook? { store.record(id: recordID)?.book }

    private var firstMonth: Date? {
        book?.entries.map(\.date).min().flatMap { Calendar.current.dateInterval(of: .month, for: $0)?.start }
    }

    private var canGoBack: Bool {
        guard let firstMonth, let current = Calendar.current.dateInterval(of: .month, for: month) else { return false }
        return current.start > firstMonth
    }

    private var canGoForward: Bool {
        guard let current = Calendar.current.dateInterval(of: .month, for: month),
              let now = Calendar.current.dateInterval(of: .month, for: Date()) else { return false }
        return current.start < now.start
    }

    private func step(_ months: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: months, to: month) { month = next }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let spending = try? book?.monthlySpending(containing: month, calendar: .current) {
                    overview(spending)
                } else {
                    ContentUnavailableView("无法计算这个月份", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("月度分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .navigationDestination(for: CategoryRoute.self) { route in
                CategoryDetailView(book: book, month: month, category: route.name)
            }
            .navigationDestination(for: MerchantRoute.self) { route in
                MerchantEntriesView(book: book, month: month, category: route.category, key: route.key)
            }
        }
    }

    @ViewBuilder private func overview(_ spending: MonthlySpending) -> some View {
        List {
            Section {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!canGoBack).accessibilityLabel("上个月").accessibilityIdentifier("month-previous")
                    Spacer()
                    Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.headline)
                        .accessibilityIdentifier("month-title")
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!canGoForward).accessibilityLabel("下个月").accessibilityIdentifier("month-next")
                }
                .buttonStyle(.borderless)
                LabeledContent("总支出") {
                    Text(dollars(spending.expenseCents)).monospacedDigit().accessibilityIdentifier("month-expense")
                }
                LabeledContent("总收入") { Text(dollars(spending.incomeCents)).monospacedDigit().foregroundStyle(.green) }
            } footer: {
                Text("美元；按手机当前时区划分月份。占比是占本月总支出的比例，收入不计入。")
            }
            if spending.categories.isEmpty {
                Section {
                    Text("这个月没有支出记录。").foregroundStyle(.secondary)
                        .accessibilityIdentifier("month-empty")
                }
            } else {
                Section {
                    Chart(spending.categories) { category in
                        SectorMark(
                            angle: .value("金额", Double(category.totalCents) / 100),
                            innerRadius: .ratio(0.62), angularInset: 1
                        )
                        .foregroundStyle(by: .value("分类", category.name))
                    }
                    .frame(height: 220)
                    .accessibilityIdentifier("spending-chart")
                }
                Section("钱花在哪里（点开看每家店）") {
                    ForEach(spending.categories) { category in
                        NavigationLink(value: CategoryRoute(name: category.name)) {
                            row(
                                title: category.name, cents: category.totalCents,
                                share: spending.share(of: category.totalCents), count: category.count
                            )
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("category-\(category.name)")
                    }
                }
            }
        }
    }

    private func row(title: String, cents: Int64, share: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(dollars(cents)).monospacedDigit()
            }
            HStack {
                ProgressView(value: min(max(share, 0), 1)).tint(.accentColor)
                Text(percent(share)).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("\(count) 笔").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct CategoryDetailView: View {
    let book: HouseholdBook?
    let month: Date
    let category: String

    var body: some View {
        let spending = try? book?.monthlySpending(containing: month, calendar: .current)
        let found = spending?.categories.first { $0.name == category }
        List {
            if let spending, let found {
                Section {
                    LabeledContent("本类支出") { Text(dollars(found.totalCents)).monospacedDigit() }
                    LabeledContent("占本月总支出") { Text(percent(spending.share(of: found.totalCents))).monospacedDigit() }
                    LabeledContent("笔数") { Text("\(found.count)") }
                }
                Section("按商店（占本类的比例）") {
                    ForEach(found.merchants) { merchant in
                        NavigationLink(value: MerchantRoute(category: category, key: merchant.key)) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(merchant.name).font(.headline)
                                    Spacer()
                                    Text(dollars(merchant.totalCents)).monospacedDigit()
                                }
                                HStack {
                                    let inCategory = found.totalCents > 0
                                        ? Double(merchant.totalCents) / Double(found.totalCents) : 0
                                    ProgressView(value: min(max(inCategory, 0), 1))
                                    Text(percent(inCategory)).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text("\(merchant.count) 笔 · 占本月 \(percent(spending.share(of: merchant.totalCents)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("merchant-\(merchant.name)")
                    }
                }
            } else {
                Text("这个月没有这一类的支出。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MerchantEntriesView: View {
    let book: HouseholdBook?
    let month: Date
    let category: String
    let key: String

    var body: some View {
        let merchant = (try? book?.monthlySpending(containing: month, calendar: .current))?
            .categories.first { $0.name == category }?.merchants.first { $0.key == key }
        List {
            if let merchant {
                Section {
                    LabeledContent("合计") { Text(dollars(merchant.totalCents)).monospacedDigit() }
                    LabeledContent("笔数") { Text("\(merchant.count)") }
                }
                Section("明细") {
                    ForEach(merchant.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Text(entry.author).font(.caption).foregroundStyle(.secondary)
                                if entry.id.hasPrefix("auto-") {
                                    Label("自动记录", systemImage: "bolt.horizontal.circle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text(dollars(entry.amountCents)).monospacedDigit()
                        }
                    }
                }
            } else {
                Text("没有找到这家店的记录。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(merchant?.name ?? "商店")
        .navigationBarTitleDisplayMode(.inline)
    }
}
