import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String?
    @State private var showingNewLedger = false
    @State private var showingNewEntry = false
    @State private var sharePresentation: SharePresentation?
    @State private var entryToDelete: LedgerEntry?
    @State private var showingConflictConfirmation = false

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
                        Picker("账本", selection: Binding(
                            get: { self.selected?.id ?? "" }, set: { selectedID = $0 }
                        )) {
                            ForEach(store.records) { item in Text(item.ledger.name).tag(item.id) }
                        }
                        .accessibilityIdentifier("ledger-picker")
                        let totals = LedgerTotals(entries: selected.book.entries)
                        totalRow("总支出", amount: totals.expenseCents, color: .primary)
                        totalRow("总收入", amount: totals.incomeCents, color: .green)
                        totalRow("收支结余", amount: totals.balanceCents, color: .blue)
                    } footer: {
                        Text("美元 · 收支结余不等于实际存款。保存先在本地完成。")
                    }
                    Section {
                        Label(status(selected), systemImage: selected.syncEnabled ? "icloud" : "iphone")
                            .accessibilityIdentifier("local-sync-status")
                        Toggle("此账本 iCloud 同步", isOn: Binding(
                            get: { self.selected?.syncEnabled ?? false },
                            set: { enabled in
                                if enabled { Task { await store.enableSync(recordID: selected.id) } }
                                else { store.disableSync(recordID: selected.id) }
                            }
                        ))
                        .disabled(store.isLoading || !store.storageReady)
                        .accessibilityIdentifier("sync-toggle")
                        if selected.ledger.isOwner {
                            Button("邀请对方 / 管理共享", systemImage: "person.badge.plus") {
                                Task { sharePresentation = await store.prepareShare(recordID: selected.id) }
                            }
                            .disabled(store.isLoading)
                        }
                        if selected.hasConflict {
                            Button("保留本地副本并核对云端版本") { showingConflictConfirmation = true }
                                .disabled(store.isLoading)
                        }
                    } header: {
                        Text("保存与共享")
                    } footer: {
                        Text("默认只在本机。主动开启后可在自己的同账号设备同步，或邀请其他 Apple ID（对方需接受）。停用只影响本设备，不删除云端、不结束共享。")
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
                        "先创建自己的账本", systemImage: "book.closed",
                        description: Text("无需联网或登录 iCloud，先在本地记账。需要时再开启同步或邀请家人。")
                    )
                    Button("创建本地账本") { showingNewLedger = true }
                        .disabled(!store.storageReady)
                        .accessibilityIdentifier("create-local-ledger")
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
                    Menu {
                        Button("新建本地账本", systemImage: "folder.badge.plus") { showingNewLedger = true }
                            .disabled(!store.storageReady)
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
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("ledger-menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记一笔", systemImage: "plus") { showingNewEntry = true }
                        .disabled(selected == nil || !store.storageReady
                                  || (selected?.ledger.isOwner == false && selected?.isAvailable == false))
                        .accessibilityIdentifier("new-entry")
                }
            }
            .sheet(isPresented: $showingNewLedger) {
                NewLedgerView(store: store) { selectedID = $0.id }
            }
            .sheet(isPresented: $showingNewEntry) {
                if let selected { NewEntryView(store: store, selected: selected) }
            }
            .sheet(item: $sharePresentation) { SharingView(presentation: $0, store: store) }
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
            .confirmationDialog(
                "会先保存当前修改为独立本地副本，再用云端版本更新原账本，不覆盖云端。",
                isPresented: $showingConflictConfirmation, titleVisibility: .visible
            ) {
                if let selected {
                    Button("保留副本并继续") { Task { await store.keepCopyAndReloadConflict(recordID: selected.id) } }
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

    private func status(_ stored: StoredLedger) -> String {
        if !stored.isAvailable { return "共享已不可用，本地缓存保留" }
        if stored.hasConflict { return "同步有冲突，本地修改未丢弃" }
        if !stored.syncEnabled { return "仅保存在本机" }
        if stored.cloudAccountID != store.selectedCloudAccountID { return "绑定其他 iCloud 账号，当前仅在本地" }
        return stored.needsUpload ? "本地已保存，等待同步" : "上次已同步到 iCloud"
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

struct NewLedgerView: View {
    @ObservedObject var store: LedgerStore
    let onCreated: (StoredLedger) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("账本名称，例如：家庭日常", text: $name).accessibilityIdentifier("ledger-name")
                Text("立即保存在本机，不需要 iCloud。之后可以选择启用同步或发送共享邀请。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = store.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("新建本地账本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task {
                            if let stored = await store.createLedger(name: trimmedName) { onCreated(stored); dismiss() }
                        }
                    }
                    .disabled(trimmedName.isEmpty || trimmedName.count > 40 || store.isMutating)
                    .accessibilityIdentifier("save-ledger")
                }
            }
        }
    }
}

struct NewEntryView: View {
    @ObservedObject var store: LedgerStore
    let selected: StoredLedger
    @Environment(\.dismiss) private var dismiss
    @State private var author: String
    @State private var amount = ""
    @State private var kind = EntryKind.expense
    @State private var category = "餐饮"
    @State private var note = ""
    @State private var date = Date()
    @State private var validationError: String?
    @State private var pendingID = UUID().uuidString
    private let categories = ["餐饮", "交通", "购物", "住宿", "娱乐", "工资", "其他"]

    init(store: LedgerStore, selected: StoredLedger) {
        self.store = store
        self.selected = selected
        _author = State(initialValue: store.memberNickname)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(selected.ledger.name) {
                    Picker("类型", selection: $kind) {
                        ForEach(EntryKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("金额（美元）", text: $amount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("entry-amount")
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("备注（选填）", text: $note).accessibilityIdentifier("entry-note")
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section {
                    TextField("你的称呼，例如：小明", text: $author).accessibilityIdentifier("entry-author")
                } footer: {
                    Text("先在本地保存。只有主动启用同步或共享后，称呼才会随记录上传给选定账本成员。")
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
            let member = author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !member.isEmpty, member.count <= 30, note.count <= 200 else {
                validationError = "请填写 1–30 字的称呼，备注最多 200 字。"
                return
            }
            validationError = nil
            let entry = LedgerEntry(
                id: pendingID, amountCents: cents, kind: kind, category: category,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines), author: member, date: date
            )
            Task {
                if await store.addEntry(entry, recordID: selected.id) {
                    store.rememberNickname(member)
                    dismiss()
                }
            }
        } catch { validationError = error.localizedDescription }
    }
}
