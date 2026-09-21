import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: app.scanPhase == .running || app.isAutoScanning
                  ? "arrow.triangle.2.circlepath"
                  : "externaldrive.badge.timemachine")
            if app.pendingReview {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: -2, y: -4)
            }
        }
        .help(app.pendingReview ? "TMSkip · 有待处理结果" : "TMSkip")
    }
}

struct MenuBarPopoverView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TMSkip").font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.pendingReview {
                    Text("待处理")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                stat(title: "已忽略", value: "\(app.ignoreStore.records.count)")
                stat(title: "合计体积", value: ByteFormat.string(app.ignoreStore.totalExcludedBytes))
            }

            VStack(spacing: 4) {
                if app.autoPendingCandidates.count > 0 {
                    mbButton("查看 \(app.autoPendingCandidates.count) 项待处理", emphasized: true) {
                        app.openMainWindow(to: .manualScan)
                        app.promoteAutoPending()
                    }
                }
                mbButton("打开主窗口") { app.openMainWindow() }
                mbButton("立即扫描") {
                    app.openMainWindow(to: .manualScan)
                    app.startManualScan()
                }
                mbButton("忽略列表") { app.openMainWindow(to: .ignoreList) }
                mbButton("扫描配置") { app.openMainWindow(to: .scanSettings) }
            }

            Divider()

            Toggle("启用自动扫描", isOn: Binding(
                get: { app.settings.autoScanEnabled },
                set: { v in app.settingsStore.update { $0.autoScanEnabled = v } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button("退出 TMSkip") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var statusText: String {
        if app.pendingReview { return "有待处理扫描结果" }
        if app.scanPhase == .running || app.isAutoScanning { return "正在扫描…" }
        if !app.fdaService.isGranted { return "需要全盘访问权限" }
        if app.settings.autoScanEnabled {
            if let last = app.settings.lastAutoScanAt {
                let f = DateFormatter()
                f.locale = Locale(identifier: "zh-Hans")
                f.dateFormat = "MM-dd HH:mm"
                return "运行中 · 上次自动扫描 \(f.string(from: last))"
            }
            return "运行中 · 自动扫描已开启"
        }
        return "运行中 · 自动扫描已关闭"
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mbButton(_ title: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasized ? Color.accentColor : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(emphasized ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.0))
        )
    }
}
