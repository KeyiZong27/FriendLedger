import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String?
    @State private var showingSettings = false
    @State private var showingNewEntry = false
    @State private var entryToDelete: LedgerEntry?

    private var selected: StoredLedger? {
        store.records.first { $0.id == selectedID } ?? store.records.first
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("ledger-error")
                        if !store.storageReady {
                            Button("重新读取本地账本") { store.retryLocalLoad() }
                        } else if store.cloudEnabled {
                            Button("重试同步") { Task { await store.reload() } }
                                .disabled(store.isLoading)
                        }
                        Button("关闭提示") { store.errorMessage = nil }
                    }
                }
                if let selected {
                    Section {
                        if store.records.count > 1 {
                            Picker("账本", selection: Binding(
                                get: { self.selected?.id ?? "" }, set: { selectedID = $0 }
                            )) {
                                ForEach(store.records) { item in Text(item.ledger.name).tag(item.id) }
                            }
                            .accessibilityIdentifier("ledger-picker")
                        } else {
                            LabeledContent("账本", value: selected.ledger.name)
                                .accessibilityIdentifier("ledger-name-label")
                        }
                        let totals = LedgerTotals(entries: selected.book.entries)
                        totalRow("总支出", amount: totals.expenseCents, color: .primary)
                        totalRow("总收入", amount: totals.incomeCents, color: .green)
                        totalRow("收支结余", amount: totals.balanceCents, color: .blue)
                    } footer: {
                        Text("美元 · 收支结余不等于实际存款。保存先在本地完成。")
                    }
                    Section("收支记录") {
                        let entries = store.entries(for: selected.id)
                        if entries.isEmpty {
                            Text("还没有记录，点击右上角 + 记第一笔。").foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .accessibilityIdentifier("entry-\(entry.id)")
                                .swipeActions {
                                    Button(role: .destructive) { entryToDelete = entry } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .disabled(!selected.ledger.isOwner && !selected.isAvailable)
                                }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "账本暂时无法打开", systemImage: "exclamationmark.triangle",
                        description: Text("本地文件没有被改动。请查看上方提示并重新读取。")
                    )
                }
                Section {
                    if let date = store.savedAt {
                        Text("本地更新时间：\(date.formatted(date: .omitted, time: .standard))")
                    }
                    if let date = store.syncedAt {
                        Text("上次云端核对：\(date.formatted(date: .omitted, time: .standard))")
                    }
                    Text(store.cloudEnabled
                         ? "同步在后台进行，不阻塞本地输入；失败后保留待上传修改，可以重试。"
                         : "尚未开启 iCloud，不会在后台请求云端。关闭重开后仍可读取本地账本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
            .navigationTitle("家庭账本")
            .refreshable { await store.reload() }
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.isLoading {
                    HStack {
                        ProgressView().accessibilityIdentifier("sync-progress")
                        Text(store.syncMessage).font(.footnote)
                        Spacer()
                    }
                    .padding().background(.thinMaterial)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: store.isLoading)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("设置", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("settings-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记一笔", systemImage: "plus") { showingNewEntry = true }
                        .disabled(selected == nil || !store.storageReady
                                  || (selected?.ledger.isOwner == false && selected?.isAvailable == false))
                        .accessibilityIdentifier("new-entry")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(store: store, selectedID: $selectedID)
            }
            .fullScreenCover(isPresented: Binding(get: { store.needsSetup }, set: { _ in })) {
                SetupView(store: store)
            }
            .sheet(isPresented: $showingNewEntry) {
                if let selected { NewEntryView(store: store, selected: selected) }
            }
            .confirmationDialog(
                "删除此记录？先保存到本地，已开启同步的账本会随后同步删除。",
                isPresented: Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let entry = entryToDelete, let selected {
                    Button("删除", role: .destructive) {
                        Task { await store.deleteEntry(entry, recordID: selected.id) }
                        entryToDelete = nil
                    }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.reload()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    if store.cloudEnabled { await store.reload() }
                }
            }
        }
    }

    private func totalRow(_ title: String, amount: Decimal, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Money.format(cents: amount, currency: .usd)).foregroundStyle(color).monospacedDigit()
                .accessibilityIdentifier(title == "总支出" ? "expense-total" : title == "总收入" ? "income-total" : "balance-total")
        }
    }

    private func entryRow(_ entry: LedgerEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.note.isEmpty ? entry.category : entry.note).font(.headline).foregroundStyle(.primary)
                Text("\(entry.category) · \(entry.author)")
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(entry.kind == .expense ? "−" : "+")\(Money.format(cents: Decimal(entry.amountCents), currency: .usd))")
                .foregroundStyle(entry.kind == .expense ? Color.primary : Color.green).monospacedDigit()
        }.padding(.vertical, 3)
    }
}

struct SetupView: View {
    @ObservedObject var store: LedgerStore
    @State private var nickname = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("你的称呼，例如：小明", text: $nickname)
                        .focused($focused)
                        .accessibilityIdentifier("setup-nickname")
                } header: {
                    Text("欢迎使用")
                } footer: {
                    Text("设置后会为你创建一个只在本机的个人账本，不需要联网或登录 iCloud。称呼之后可在设置中修改，共享账本时会显示给对方。")
                }
                if let message = store.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("ledger-error")
                }
                Button("开始记账") {
                    Task { _ = await store.completeSetup(nickname: nickname) }
                }
                .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMutating)
                .accessibilityIdentifier("setup-continue")
            }
            .navigationTitle("创建你的账本")
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled()
    }
}

struct SettingsView: View {
    @ObservedObject var store: LedgerStore
    @Binding var selectedID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var sharePresentation: SharePresentation?
    @State private var showingConflictConfirmation = false

    private var selected: StoredLedger? {
        store.records.first { $0.id == selectedID } ?? store.records.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("称呼", text: $nickname).accessibilityIdentifier("settings-nickname")
                    Button("保存称呼") { _ = store.updateNickname(nickname) }
                        .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines) == store.nickname)
                } header: {
                    Text("我")
                } footer: {
                    Text("新增记录使用这个称呼。已保存的旧记录不会被改写。")
                }
                if let selected {
                    Section {
                        Label(status(selected), systemImage: selected.syncEnabled ? "icloud" : "iphone")
                            .accessibilityIdentifier("local-sync-status")
                        Toggle("iCloud 同步", isOn: Binding(
                            get: { self.selected?.syncEnabled ?? false },
                            set: { enabled in
                                if enabled { Task { await store.enableSync(recordID: selected.id) } }
                                else { store.disableSync(recordID: selected.id) }
                            }
                        ))
                        .disabled(store.isLoading || !store.storageReady)
                        .accessibilityIdentifier("sync-toggle")
                        if store.isLoading {
                            HStack {
                                ProgressView()
                                Text(store.syncMessage).font(.footnote)
                            }
                        }
                        if selected.hasConflict {
                            Button("保留本地副本并核对云端版本") { showingConflictConfirmation = true }
                                .disabled(store.isLoading)
                        }
                    } header: {
                        Text("账本：\(selected.ledger.name)")
                    } footer: {
                        Text("默认只在本机。开启后可在同一 Apple ID 的其他设备使用。停用只影响本设备，不删除云端、不结束共享。")
                    }
                    if selected.ledger.isOwner {
                        Section {
                            Button("邀请对方共享账本", systemImage: "person.badge.plus") {
                                Task { sharePresentation = await store.prepareShare(recordID: selected.id) }
                            }
                            .disabled(store.isLoading)
                            .accessibilityIdentifier("share-ledger")
                        } header: {
                            Text("共享")
                        } footer: {
                            Text("对方接受邀请后，可一起往这个账本里添加记录。对方必须主动接受。")
                        }
                    }
                }
                Section("云端") {
                    Button("从当前 iCloud 加载账本", systemImage: "icloud.and.arrow.down") {
                        Task { await store.restoreFromCloud() }
                    }
                    .disabled(store.isLoading || !store.storageReady)
                    if let selected {
                        Button("保存为独立本地副本", systemImage: "doc.on.doc") {
                            Task {
                                if let copy = await store.copyLocally(recordID: selected.id) { selectedID = copy.id }
                            }
                        }
                        .disabled(!store.storageReady)
                    }
                }
                if let message = store.errorMessage {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear { nickname = store.nickname }
            .sheet(item: $sharePresentation) { SharingView(presentation: $0, store: store) }
            .confirmationDialog(
                "会先保存当前修改为独立本地副本，再用云端版本更新原账本，不覆盖云端。",
                isPresented: $showingConflictConfirmation, titleVisibility: .visible
            ) {
                if let selected {
                    Button("保留副本并继续") { Task { await store.keepCopyAndReloadConflict(recordID: selected.id) } }
                }
            }
        }
    }

    private func status(_ stored: StoredLedger) -> String {
        if !stored.isAvailable { return "共享已不可用，本地缓存保留" }
        if stored.hasConflict { return "同步有冲突，本地修改未丢弃" }
        if !stored.syncEnabled { return "仅保存在本机" }
        if stored.cloudAccountID != store.selectedCloudAccountID { return "绑定其他 iCloud 账号，当前仅在本地" }
        return stored.needsUpload ? "本地已保存，等待同步" : "上次已同步到 iCloud"
    }
}

struct NewEntryView: View {
    @ObservedObject var store: LedgerStore
    let selected: StoredLedger
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var kind = EntryKind.expense
    @State private var note = ""
    @State private var date = Date()
    @State private var validationError: String?
    @State private var pendingID = UUID().uuidString

    init(store: LedgerStore, selected: StoredLedger) {
        self.store = store
        self.selected = selected
    }

    private var autoCategory: String {
        if kind == .income { return MerchantTypeClassifier.incomeType }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = store.record(id: selected.id)?.book.merchant(matching: text) { return known.businessType }
        return MerchantTypeClassifier.suggest(merchantName: text) ?? "其他"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(EntryKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("金额（美元）", text: $amount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("entry-amount")
                    TextField("商店或备注（选填）", text: $note).accessibilityIdentifier("entry-note")
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                } header: {
                    Text(selected.ledger.name)
                } footer: {
                    Text("分类自动设为“\(autoCategory)”；以“\(store.nickname)”记录，先保存在本地。")
                }
                if let error = validationError ?? store.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("记一笔")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存到本地") { save() }
                        .disabled(store.isMutating).accessibilityIdentifier("save-entry")
                }
            }
        }
    }

    private func save() {
        do {
            let cents = try Money.parse(amount)
            guard note.count <= 200 else {
                validationError = "备注最多 200 字。"
                return
            }
            validationError = nil
            let entry = LedgerEntry(
                id: pendingID, amountCents: cents, kind: kind, category: autoCategory,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines), author: store.nickname, date: date
            )
            Task {
                if await store.addEntry(entry, recordID: selected.id) { dismiss() }
            }
        } catch { validationError = error.localizedDescription }
    }
}
