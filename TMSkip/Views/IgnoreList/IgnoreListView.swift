import SwiftUI
import AppKit

struct IgnoreListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .time
    @State private var now = Date()
    private let timer = Timer.publish(every: 1800, on: .main, in: .common).autoconnect()

    // Manual-add sheet state
    @State private var showAddSheet = false
    @State private var addPathText = ""
    @State private var addError: String?

    private enum Filter: String, CaseIterable, Identifiable {
        case all, app, anomaly, missing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .app: return "本 App 标记"
            case .anomaly: return "状态异常"
            case .missing: return "路径不存在"
            }
        }
    }

    private enum Sort: String, CaseIterable, Identifiable {
        case time, sizeDesc, path
        var id: String { rawValue }
        var title: String {
            switch self {
            case .time: return "按时间"
            case .sizeDesc: return "按体积降序"
            case .path: return "按路径"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("忽略列表")
                        .font(.largeTitle.weight(.bold))
                    Text("已被 Time Machine 排除的路径 · 可搜索、筛选与撤销")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    chip("共 \(app.ignoreStore.records.count) 项")
                    chip(ByteFormat.string(app.ignoreStore.totalExcludedBytes), accent: true)
                }
            }

            VStack(spacing: 8) {
                // 过滤行：搜索 + 筛选 + 排序
                HStack(spacing: 8) {
                    TextField("搜索路径…", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("筛选", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Picker("排序", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                // 操作行：左侧主操作「添加」，右侧批量管理操作
                HStack(spacing: 8) {
                    Button {
                        addPathText = ""
                        addError = nil
                        showAddSheet = true
                    } label: {
                        Label("添加忽略", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.prominent)
                    .help("手动将某个目录标记为 Time Machine 排除")
                    Spacer()
                    Button("刷新状态") { app.refreshIgnoreStatuses() }
                        .buttonStyle(.secondary)
                    Button("重新忽略") { app.reignoreSelected() }
                        .disabled(!canReignore)
                        .help("将选中的状态异常路径重新加入 Time Machine 排除")
                    Button("撤销忽略") { app.unignoreSelected() }
                        .buttonStyle(.destructive)
                        .disabled(app.ignoreStore.records.filter(\.isSelected).isEmpty)
                }
            }

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("还没有已忽略的路径")
                        .font(.headline)
                    Text("先运行一次手动扫描，或手动添加一个要排除的目录。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("去手动扫描") { app.selectedSidebar = .manualScan }
                            .buttonStyle(.prominent)
                        Button("手动添加路径") {
                            addPathText = ""
                            addError = nil
                            showAddSheet = true
                        }
                        .buttonStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                Table(filtered) {
                    TableColumn("") { (item: IgnoreRecord) in
                        Checkbox(isOn: item.isSelected) { selected in
                            app.ignoreStore.updateSelection(id: item.id, selected: selected)
                        }
                    }
                    .width(28)

                    TableColumn("路径") { item in
                        Text(item.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .help(item.path)
                    }

                    TableColumn("来源") { item in
                        Text(item.source.title).font(.callout)
                    }
                    .width(90)

                    TableColumn("时间") { item in
                        Text(Self.relativeTime(item.updatedAt, now: now))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .width(90)

                    TableColumn("状态") { item in
                        Text(item.status.title)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(statusColor(item.status).opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor(item.status))
                    }
                    .width(90)

                    TableColumn("体积") { item in
                        Text(ByteFormat.string(item.byteSize))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(100)
                }
                .frame(minHeight: 360)
                // SwiftUI Table 列头只支持文本，通过 AppKit 桥接把全选勾选框
                // 直接嵌入 NSTableView 第一列表头，与数据行处于同一布局体系，天然对齐
                .background(TableHeaderCheckboxInstaller(state: selectAllState, onToggle: toggleSelectAll))
            }

            HStack {
                Text("已选 \(app.ignoreStore.records.filter(\.isSelected).count) 项")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("撤销将取消 Time Machine 排除标记，不会删除文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onReceive(timer) { now = $0 }
        .sheet(isPresented: $showAddSheet) {
            addSheet
        }
    }

    // MARK: - Add-manual-ignore sheet

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动添加忽略")
                .font(.headline)
            Text("将某个目录标记为 Time Machine 排除，不会删除文件。适合未命中任何规则、但确实无需备份的目录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("路径，如 ~/Documents/OldProject", text: $addPathText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAdd)
                Button {
                    chooseDirectoryForAdd()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.secondary)
                .help("浏览并选择要排除的目录…")
            }

            if let addError {
                Text(addError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { showAddSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { submitAdd() }
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submitAdd() {
        let trimmed = addPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let error = app.addManualIgnorePath(trimmed) {
            addError = error
        } else {
            showAddSheet = false
        }
    }

    private func chooseDirectoryForAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "选择要从 Time Machine 排除的目录"
        panel.prompt = "添加"

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                addPathText = url.path
                addError = nil
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            addPathText = url.path
            addError = nil
        }
    }

    private var selectAllState: CheckboxState {
        let rows = filtered
        let selectedCount = rows.lazy.filter(\.isSelected).count
        if selectedCount == 0 { return .off }
        return selectedCount == rows.count ? .on : .partial
    }

    /// 重新忽略仅对选中项全为「状态异常」时可用。
    private var canReignore: Bool {
        let selected = app.ignoreStore.records.filter(\.isSelected)
        return !selected.isEmpty && selected.allSatisfy { $0.status == .anomaly }
    }

    private func toggleSelectAll() {
        let rows = filtered
        let allSelected = rows.allSatisfy(\.isSelected)
        app.ignoreStore.setAllSelection(!allSelected, in: rows.map(\.id))
    }

    private var filtered: [IgnoreRecord] {
        var rows = app.ignoreStore.records
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter { $0.path.lowercased().contains(q) }
        }
        switch filter {
        case .all: break
        case .app: rows = rows.filter { $0.source != .unknown }
        case .anomaly: rows = rows.filter { $0.status == .anomaly }
        case .missing: rows = rows.filter { $0.status == .missing }
        }
        switch sort {
        case .time:
            rows.sort { $0.updatedAt > $1.updatedAt }
        case .sizeDesc:
            rows.sort { ($0.byteSize ?? -1) > ($1.byteSize ?? -1) }
        case .path:
            rows.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }
        return rows
    }

    private func statusColor(_ status: IgnoreStatus) -> Color {
        switch status {
        case .excluded: return .green
        case .anomaly: return .orange
        case .missing: return .red
        }
    }

    /// 粗粒度相对时间：不到 1 小时显示「刚刚」，否则按小时/天展示，不显示分钟和秒。
    private static func relativeTime(_ date: Date, now: Date) -> String {
        let comps = Calendar.current.dateComponents([.day, .hour], from: date, to: now)
        if let day = comps.day, day >= 1 {
            return "\(day) 天前"
        }
        if let hour = comps.hour, hour >= 1 {
            return "\(hour) 小时前"
        }
        return "刚刚"
    }

    private func chip(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)), in: Capsule())
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
    }
}

// MARK: - AppKit 表头全选勾选框桥接

/// 通过 AppKit 在 SwiftUI Table 第一列表头中嵌入全选勾选框。
/// 勾选框直接挂在 NSTableHeaderView 上，水平位置读取自第一行数据单元格，
/// 与数据行勾选框处于同一 NSTableView 布局体系，保证精确对齐。
private struct TableHeaderCheckboxInstaller: NSViewRepresentable {
    let state: CheckboxState
    let onToggle: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.state = state
        nsView.onToggle = onToggle
        nsView.installIfNeeded()
    }

    final class ProbeView: NSView {
        var state: CheckboxState = .off
        var onToggle: (() -> Void)?
        private weak var hostingView: NSHostingView<AnyView>?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        override func layout() {
            super.layout()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let headerView = findHeaderView() else {
                scheduleRetry()
                return
            }

            // 表头字号统一加大一级（默认 smallSystemFont 12pt → 13pt）
            if let tableView = headerView.tableView {
                let headerFont = NSFont.systemFont(ofSize: 14)
                for column in tableView.tableColumns {
                    column.headerCell.font = headerFont
                }
            }

            // 数据行尚未渲染时（如筛选后短暂为空再刷新），延迟重试以读取准确位置
            if headerView.tableView?.numberOfRows == 0 {
                scheduleRetry()
            }

            let targetFrame = resolveFrame(headerView: headerView)

            if let existing = hostingView, existing.superview === headerView {
                existing.frame = targetFrame
                existing.rootView = AnyView(checkboxRoot)
            } else {
                hostingView?.removeFromSuperview()
                let hosting = NSHostingView(rootView: AnyView(checkboxRoot))
                hosting.frame = targetFrame
                headerView.addSubview(hosting)
                hostingView = hosting
            }
        }

        private var retryCount = 0
        private func scheduleRetry() {
            retryCount += 1
            guard retryCount < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.installIfNeeded()
            }
        }

        private var checkboxRoot: some View {
            Checkbox(state: state) { [weak self] in
                self?.onToggle?()
            }
        }

        /// 计算勾选框在表头中的 frame：x 读取自第一行数据单元格中的勾选框，y 垂直居中
        private func resolveFrame(headerView: NSTableHeaderView) -> NSRect {
            let column = 0
            let headerRect = headerView.headerRect(ofColumn: column)
            let y = (headerRect.height - 14) / 2

            if let tableView = headerView.tableView,
               tableView.numberOfRows > 0,
               let rowView = tableView.rowView(atRow: 0, makeIfNecessary: false),
               let cellView = rowView.view(atColumn: column) as? NSView,
               let checkbox = findCheckbox(in: cellView) {
                let rectInHeader = checkbox.convert(checkbox.bounds, to: headerView)
                return NSRect(x: rectInHeader.minX, y: y, width: 14, height: 14)
            }

            // 回退：表头列区域水平居中
            return NSRect(x: headerRect.midX - 7, y: y, width: 14, height: 14)
        }

        /// 递归查找单元格中的勾选框可见视图。
        /// SwiftUI Checkbox 底层不是 NSButton，而是 14×14 的私有 _FocusRingView/KeyViewProxy，
        /// 因此按尺寸精确匹配（Checkbox 已通过 .frame 锁定为 14×14）。
        private func findCheckbox(in view: NSView) -> NSView? {
            let size = view.frame.size
            if abs(size.width - 14) < 0.5 && abs(size.height - 14) < 0.5 {
                return view
            }
            for subview in view.subviews {
                if let found = findCheckbox(in: subview) {
                    return found
                }
            }
            return nil
        }

        private func findHeaderView() -> NSTableHeaderView? {
            var current: NSView? = superview
            while let view = current {
                if let found = searchHeaderView(in: view) { return found }
                current = view.superview
            }
            return nil
        }

        private func searchHeaderView(in view: NSView) -> NSTableHeaderView? {
            if let headerView = view as? NSTableHeaderView { return headerView }
            for subview in view.subviews {
                if let found = searchHeaderView(in: subview) { return found }
            }
            return nil
        }
    }
}
