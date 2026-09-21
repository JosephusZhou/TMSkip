import AppKit
import SwiftUI

struct ScanSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var newSkip = ""
    /// PRD §6.4.2: choosing autoApply requires an explicit risk confirmation.
    @State private var showAutoApplyConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("扫描配置")
                            .font(.largeTitle.weight(.bold))
                        Text("自动扫描、应用策略、规则包与跳过目录 · 更改即时保存")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                card("自动扫描") {
                    toggleRow("启用自动扫描", subtitle: "后台按策略发现可排除目录", isOn: autoScanBinding)
                    pickerRow("触发间隔") {
                        DownwardPicker(selection: intervalBinding, titleFor: { $0.title })
                            .frame(width: 140)
                    }
                    pickerRow("触发模式") {
                        DownwardPicker(selection: triggerBinding, titleFor: { $0.title })
                            .frame(width: 200)
                    }
                    toggleRow("登录时启动", subtitle: loginSubtitle, isOn: loginBinding)
                    if let error = app.loginItemError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.leading, 4)
                    }

                    Divider().padding(.top, 2)

                    Text("结果处理")
                        .font(.headline.weight(.semibold))
                    ForEach(ApplyPolicy.allCases) { policy in
                        policyRow(policy)
                    }
                    toggleRow("允许系统通知", subtitle: "关闭后仍保留菜单栏点标", isOn: notifyBinding)
                }
                .alert("启用自动应用？", isPresented: $showAutoApplyConfirm) {
                    Button("保持通知确认", role: .cancel) {}
                    Button("仍要自动应用", role: .destructive) {
                        app.settingsStore.update { $0.applyPolicy = .autoApply }
                    }
                } message: {
                    Text("自动应用会在扫描后立即排除匹配目录。若你不确定，请保持「通知并手动确认」。")
                }

                card("扫描范围") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扫描根目录").font(.headline.weight(.medium))
                        }
                        Spacer()
                        Text(app.homeDisplayPath)
                            .font(.system(.callout, design: .monospaced))
                            .padding(6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Text("跳过的目录")
                        .font(.headline.weight(.medium))
                        .padding(.top, 6)

                    FlowSkipList(paths: app.settings.skipPaths) { path in
                        app.removeSkipPath(path)
                    }

                    HStack {
                        TextField("添加跳过路径，如 ~/Movies", text: $newSkip)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            chooseSkipDirectory()
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(.secondary)
                        .help("浏览并选择要跳过的目录…")
                        Button("添加") {
                            app.addSkipPath(newSkip)
                            newSkip = ""
                        }
                        .buttonStyle(.secondary)
                    }
                }

                card("规则（Asimov）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("规则默认使用应用内置的 Asimov 兼容规则包（离线可用）。「检查更新」会尝试从 Asimov 开源仓库同步最新规则；失败时继续使用当前规则，不阻断扫描。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Three-state status
                        HStack(spacing: 8) {
                            originBadge(app.activeRulePackage.origin)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前生效：\(app.activeRulePackage.summaryLine)")
                                    .font(.callout)
                                Text(app.activeRulePackage.source)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                        if let msg = app.settings.lastRuleCheckMessage {
                            Text(msg)
                                .font(.footnote)
                                .foregroundStyle(app.settings.lastRuleCheckSucceeded == true ? Color.green : Color.orange)
                        }

                        HStack(spacing: 8) {
                            Button {
                                app.checkRuleUpdates()
                            } label: {
                                if app.isCheckingRules {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("正在检查…")
                                    }
                                } else {
                                    Text("检查更新")
                                }
                            }
                            .disabled(app.isCheckingRules)
                            .buttonStyle(.prominent)

                            Button("恢复内置兜底") {
                                app.restoreBundledRules()
                            }
                            .buttonStyle(.secondary)
                            .disabled(app.activeRulePackage.origin == .bundled && app.settings.remoteRuleCache == nil)

                            if let cache = app.settings.remoteRuleCache,
                               cache.origin == .remoteCache,
                               app.activeRulePackage.origin == .bundled {
                                Button("使用远程缓存") {
                                    app.activateRemoteRuleCache()
                                }
                                .buttonStyle(.secondary)
                            }
                        }

                        toggleRow("每日自动检查规则更新", subtitle: "启动后及每 24 小时后台同步，失败静默回退", isOn: autoRuleSyncBinding)
                    }

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(app.activeRulePackage.rules) { rule in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rule.name).font(.system(size: 14))
                                        Text("\(rule.group) · excludes: \(rule.excludes.joined(separator: ", ")) · if: \(rule.ifExists.joined(separator: ", "))")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Checkbox(isOn: rule.isEnabled) { enabled in
                                        app.setRuleEnabled(id: rule.id, enabled: enabled)
                                    }
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.visible)

                    toggleRow("不自动恢复备份（no re-include）", subtitle: "规则不再匹配时，不自动取消排除", isOn: noReincludeBinding)
                }
            }
            .padding(20)
        }
    }


    /// System folder picker; selected paths go through AppModel like typed input.
    private func chooseSkipDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "选择要在扫描时跳过的目录"
        panel.prompt = "添加"

        let addSelection = {
            for url in panel.urls {
                app.addSkipPath(url.path)
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { _ in addSelection() }
        } else if panel.runModal() == .OK {
            addSelection()
        }
    }

    private func originBadge(_ origin: RulePackageOrigin) -> some View {
        Text(origin.title)
            .font(.footnote.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(origin == .bundled ? Color.blue.opacity(0.15) : Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(origin == .bundled ? Color.blue : Color.green)
    }

    private var autoScanBinding: Binding<Bool> {
        Binding(
            get: { app.settings.autoScanEnabled },
            set: { v in app.settingsStore.update { $0.autoScanEnabled = v } }
        )
    }
    private var intervalBinding: Binding<ScanInterval> {
        Binding(
            get: { app.settings.scanInterval },
            set: { v in app.settingsStore.update { $0.scanInterval = v } }
        )
    }
    private var triggerBinding: Binding<ScanTriggerMode> {
        Binding(
            get: { app.settings.triggerMode },
            set: { v in app.settingsStore.update { $0.triggerMode = v } }
        )
    }
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { app.settings.launchAtLogin },
            set: { v in app.settingsStore.update { $0.launchAtLogin = v } }
        )
    }
    private var loginSubtitle: String {
        app.loginItemService.isRegistered
            ? "保证自动扫描在后台存活 · 系统已注册"
            : "保证自动扫描在后台存活"
    }
    private var autoRuleSyncBinding: Binding<Bool> {
        Binding(
            get: { app.settings.autoRuleSync },
            set: { v in app.settingsStore.update { $0.autoRuleSync = v } }
        )
    }
    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { app.settings.notificationsEnabled },
            set: { v in app.settingsStore.update { $0.notificationsEnabled = v } }
        )
    }
    private var noReincludeBinding: Binding<Bool> {
        Binding(
            get: { app.settings.noReinclude },
            set: { v in app.settingsStore.update { $0.noReinclude = v } }
        )
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Checkbox(state: isOn.wrappedValue ? .on : .off, action: nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.weight(.medium))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func pickerRow(_ title: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack {
            Text(title).font(.headline.weight(.medium))
            Spacer()
            picker()
        }
        .padding(.vertical, 4)
    }

    private func policyRow(_ policy: ApplyPolicy) -> some View {
        let selected = app.settings.applyPolicy == policy
        return Button {
            // PRD §6.4.2: autoApply needs an explicit risk confirmation.
            if policy == .autoApply, app.settings.applyPolicy != .autoApply {
                showAutoApplyConfirm = true
            } else {
                app.settingsStore.update { $0.applyPolicy = policy }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(policy.title).font(.headline.weight(.medium)).foregroundStyle(.primary)
                    Text(policy.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FlowSkipList: View {
    let paths: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlexibleTags(paths: paths, onRemove: onRemove)
    }
}

private struct FlexibleTags: View {
    let paths: [String]
    let onRemove: (String) -> Void

    var body: some View {
        // Simple wrapping via LazyVGrid
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 4) {
                    Text(path)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                    Button {
                        onRemove(path)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
        }
    }
}

// MARK: - 向下弹出的 Picker（AppKit 桥接）

/// 子类化 NSPopUpButton，重写 mouseDown 手动弹出菜单，
/// 用屏幕坐标把定位点设在按钮底部下方，强制菜单向下展开，并对齐宽度。
private final class DownwardPopUpButton: NSPopUpButton {
    override func mouseDown(with event: NSEvent) {
        guard let menu = self.menu else {
            super.mouseDown(with: event)
            return
        }
        isHighlighted = true

        // 菜单最小宽度与按钮对齐
        menu.minimumWidth = bounds.width

        // 按钮底部下方 2pt → 屏幕坐标
        let localPoint = NSPoint(x: 0, y: -2)
        let windowPoint = convert(localPoint, to: nil)
        let screenPoint = window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        menu.popUp(positioning: nil, at: screenPoint, in: nil)

        isHighlighted = false
    }
}

/// 用 DownwardPopUpButton 包装，强制菜单向下弹出。
private struct DownwardPicker<Selection: Hashable & CaseIterable>: NSViewRepresentable
where Selection.AllCases: RandomAccessCollection {
    @Binding var selection: Selection
    let titleFor: (Selection) -> String

    func makeNSView(context: Context) -> DownwardPopUpButton {
        let button = DownwardPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.itemSelected(_:))
        return button
    }

    func updateNSView(_ nsView: DownwardPopUpButton, context: Context) {
        let items = Array(Selection.allCases)
        nsView.removeAllItems()
        for item in items {
            nsView.addItem(withTitle: titleFor(item))
        }
        if let index = items.firstIndex(where: { $0 == selection }) {
            nsView.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: DownwardPicker
        init(_ parent: DownwardPicker) { self.parent = parent }

        @objc func itemSelected(_ sender: NSPopUpButton) {
            let items = Array(Selection.allCases)
            let index = sender.indexOfSelectedItem
            guard index >= 0, index < items.count else { return }
            parent.selection = items[index]
        }
    }
}
