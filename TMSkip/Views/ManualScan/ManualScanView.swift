import SwiftUI

struct ManualScanView: View {
    @EnvironmentObject private var app: AppModel
    @State private var search = ""
    @State private var sort: ResultSort = .sizeDesc
    @State private var statusFilter: StatusFilter = .all

    private enum ResultSort: String, CaseIterable, Identifiable {
        case sizeDesc, path, rule
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sizeDesc: return "按体积降序"
            case .path: return "按路径"
            case .rule: return "按规则"
            }
        }
    }

    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all, needExclude, alreadyExcluded
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .needExclude: return "仅待排除"
            case .alreadyExcluded: return "仅已排除"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onAppear { app.manualScanDidAppear() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("手动扫描")
                    .font(.largeTitle.weight(.bold))
                Text("默认扫描你的用户主目录 · 结果需确认后才会写入排除")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                chip("规则 · \(app.activeRulePackage.origin.title) · \(app.activeRulePackage.version)")
                chip("跳过 \(app.settings.skipPaths.count) 个目录")
                chip("根目录 ~/")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch app.scanPhase {
        case .idle:
            idleCard
        case .running:
            runningCard
        case .result:
            resultSection
        case .applying:
            applyingCard
        case .done:
            doneCard
        }
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            Text("准备扫描用户目录")
                .font(.title2.weight(.semibold))

            Text("TMSkip 将在 \(app.homeDisplayPath) 下按 Asimov 规则查找可再生目录（如 node_modules、target），并估算体积。不会删除任何文件。")
                .foregroundStyle(.secondary)

            HStack {
                Button("开始扫描") { app.startManualScan() }
                    .buttonStyle(.prominent)
                    .controlSize(.large)
                Button("调整扫描配置") { app.selectedSidebar = .scanSettings }
                    .buttonStyle(.secondary)
                    .controlSize(.large)
            }

            Text("提示：首次使用建议先跑一遍手动扫描，再开启自动扫描。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("正在扫描系统…")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") { app.cancelManualScan() }
                    .buttonStyle(.secondary)
            }
            Text(app.scanProgress.currentPath.isEmpty ? "…" : app.scanProgress.currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(app.scanProgress.currentPath)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            if app.scanProgress.totalDirs == nil, app.scanProgress.walked == 0 {
                ProgressView()
                    .progressViewStyle(.linear)
                HStack(spacing: 16) {
                    Text("正在统计目录规模…")
                    Text("发现候选 \(app.scanProgress.found)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ProgressView(value: app.scanProgress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 16) {
                    Text(counterText)
                    Text("发现候选 \(app.scanProgress.found)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private var counterText: String {
        if let total = app.scanProgress.totalDirs {
            return "已遍历 \(app.scanProgress.walked.formatted()) / \(total.formatted()) 个目录"
        }
        return "已遍历 \(app.scanProgress.walked.formatted()) 个目录"
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                summaryCard(
                    title: "待排除",
                    value: "\(app.newExcludeCandidates.count)",
                    extra: ByteFormat.string(app.newExcludeBytes)
                )
                summaryCard(
                    title: "此前已排除",
                    value: "\(app.alreadyExcludedCandidates.count)",
                    extra: ByteFormat.string(app.alreadyExcludedBytes) + " · 含 tmexclude 等"
                )
                summaryCard(
                    title: "已选待应用",
                    value: ByteFormat.string(app.selectedBytes),
                    extra: "\(app.selectedCandidates.filter(\.needsExclude).count) 项",
                    accent: true
                )
            }

            Text("「此前已排除」表示磁盘上已有 Time Machine 排除标记（可能来自 tmexclude / Asimov / 手动 tmutil）。默认不会勾选，避免重复应用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("筛选路径…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("排序", selection: $sort) {
                    ForEach(ResultSort.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("筛选", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Button {
                    let news = app.newExcludeCandidates
                    let allSelected = !news.isEmpty && news.allSatisfy(\.isSelected)
                    app.setAllCandidatesSelected(!allSelected)
                } label: {
                    HStack(spacing: 6) {
                        Checkbox(state: selectAllCandidatesState, action: nil)
                        Text("全选待排除")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button("丢弃结果") { app.discardResults() }
                    .buttonStyle(.secondary)
                Button("应用所选") { app.applySelected() }
                    .buttonStyle(.prominent)
            }

            Table(filteredCandidates) {
                TableColumn("") { (item: ScanCandidate) in
                    Checkbox(isOn: item.isSelected) { selected in
                        app.toggleCandidate(id: item.id, selected: selected)
                    }
                    // Allow user to still select already-excluded if they want (no-op apply);
                    // default remains unselected.
                }
                .width(28)

                TableColumn("路径") { item in
                    Text(item.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .help(item.path)
                        .foregroundStyle(item.exclusionState == .alreadyExcluded ? .secondary : .primary)
                }
                .width(min: 240, ideal: 380)

                TableColumn("状态") { item in
                    Text(item.exclusionState.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(statusColor(item.exclusionState).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(item.exclusionState))
                }
                .width(72)

                TableColumn("规则") { item in
                    Text(item.ruleName)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .width(110)

                TableColumn("体积") { item in
                    Text(sizeText(item))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(100)
            }
            .frame(minHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func statusColor(_ state: ExistingExclusionState) -> Color {
        switch state {
        case .alreadyExcluded: return .green
        case .notExcluded: return .orange
        case .unknown: return .secondary
        }
    }

    private var applyingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在应用排除标记…")
                .font(.title3.weight(.semibold))
            Text("设置 Time Machine 排除属性，不会删除文件")
                .foregroundStyle(.secondary)
            Text(app.applyCurrentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(app.lastOutcome.failedPaths.isEmpty ? Color.green : Color.orange)
            Text("应用完成")
                .font(.title2.weight(.semibold))
            Text("已排除 \(app.lastOutcome.excludedCount) 项，合计 \(ByteFormat.string(app.lastOutcome.excludedBytes))。可在「忽略列表」中查看或撤销。")
                .foregroundStyle(.secondary)

            if !app.lastOutcome.appBundleBlockedPaths.isEmpty {
                outcomeNote(
                    icon: "shippingbox.fill",
                    tint: .orange,
                    title: "已跳过 \(app.lastOutcome.appBundleBlockedPaths.count) 项（位于其他应用包内）",
                    paths: app.lastOutcome.appBundleBlockedPaths,
                    hint: "按产品规则不修改其他应用的包内容。"
                )
            }

            if !app.lastOutcome.failedPaths.isEmpty {
                outcomeNote(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    title: "未写入 \(app.lastOutcome.failedPaths.count) 项",
                    paths: app.lastOutcome.failedPaths,
                    hint: app.lastOutcome.permissionBlocked
                        ? "写入被系统权限拦截（如「App 管理」）。授予后重新扫描并应用即可。"
                        : "路径可能不存在或无写入权限。"
                )
                if app.lastOutcome.permissionBlocked {
                    Button("打开「隐私与安全性」设置") { app.openAppManagementSettings() }
                        .buttonStyle(.secondary)
                }
            }

            HStack {
                Button("查看忽略列表") { app.selectedSidebar = .ignoreList }
                    .buttonStyle(.prominent)
                Button("返回") { app.scanPhase = .idle }
                    .buttonStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(app.lastOutcome.failedPaths.isEmpty ? Color.green.opacity(0.3) : Color.orange.opacity(0.4)))
    }

    @ViewBuilder
    private func outcomeNote(icon: String, tint: Color, title: String, paths: [String], hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(paths.prefix(5), id: \.self) { path in
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .foregroundStyle(.secondary)
            }
            if paths.count > 5 {
                Text("… 等共 \(paths.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25)))
    }

    private var selectAllCandidatesState: CheckboxState {
        let news = app.newExcludeCandidates
        if news.isEmpty { return .off }
        let selectedCount = news.filter(\.isSelected).count
        if selectedCount == 0 { return .off }
        return selectedCount == news.count ? .on : .partial
    }

    private var filteredCandidates: [ScanCandidate] {
        var rows = app.candidates
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter { $0.path.lowercased().contains(q) }
        }
        switch statusFilter {
        case .all: break
        case .needExclude:
            rows = rows.filter { $0.exclusionState != .alreadyExcluded }
        case .alreadyExcluded:
            rows = rows.filter { $0.exclusionState == .alreadyExcluded }
        }
        switch sort {
        case .sizeDesc:
            // New items first, then by size
            rows.sort {
                if $0.exclusionState != $1.exclusionState {
                    return $0.needsExclude && !$1.needsExclude
                }
                return ($0.byteSize ?? -1) > ($1.byteSize ?? -1)
            }
        case .path:
            rows.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        case .rule:
            rows.sort { $0.ruleName.localizedCaseInsensitiveCompare($1.ruleName) == .orderedAscending }
        }
        return rows
    }

    private func sizeText(_ item: ScanCandidate) -> String {
        switch item.sizeState {
        case .pending, .computing: return "计算中…"
        case .timedOut: return "超时"
        case .unavailable: return "不可用"
        case .ready: return ByteFormat.string(item.byteSize)
        }
    }

    private func summaryCard(title: String, value: String, extra: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(extra).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(accent ? Color.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
        )
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
