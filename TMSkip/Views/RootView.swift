import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
            } detail: {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewStyle(.balanced)
            .disabled(app.showOnboarding)

            if app.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }

            if let message = app.statusMessage {
                VStack {
                    Text(message)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 8, y: 2)
                        .padding(.top, 24)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.showOnboarding)
        .animation(.easeInOut(duration: 0.2), value: app.statusMessage)
    }

    @ViewBuilder
    private var detailView: some View {
        switch app.selectedSidebar {
        case .manualScan:
            ManualScanView()
        case .ignoreList:
            IgnoreListView()
        case .scanSettings:
            ScanSettingsView()
        case .about:
            AboutView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List(selection: $app.selectedSidebar) {
            ForEach([SidebarItem.manualScan, .ignoreList, .scanSettings, .about], id: \.self) { item in
                Label {
                    HStack {
                        Text(item.title)
                        if item == .manualScan, app.pendingReview {
                            Spacer()
                            Text("1")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                } icon: {
                    Image(systemName: item.systemImage)
                }
                .tag(item)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(app.fdaService.isGranted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(app.fdaService.isGranted ? "全盘访问已授权" : "需要全盘访问")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }
}

// MARK: - 自定义按钮样式

/// 两种自定义按钮样式（Prominent / Secondary）共享的尺寸度量，
/// 确保任意 controlSize 下主按钮与次按钮高度、圆角、内边距完全一致。
private enum ButtonMetrics {
    static func horizontalPadding(for size: ControlSize) -> CGFloat {
        switch size {
        case .large: return 16
        case .regular: return 12
        case .small: return 10
        case .mini: return 8
        @unknown default: return 12
        }
    }

    static func verticalPadding(for size: ControlSize) -> CGFloat {
        switch size {
        case .large: return 8
        case .regular: return 6
        case .small: return 4
        case .mini: return 3
        @unknown default: return 6
        }
    }

    static func cornerRadius(for size: ControlSize) -> CGFloat {
        switch size {
        case .large: return 8
        case .regular: return 6
        case .small: return 5
        case .mini: return 4
        @unknown default: return 6
        }
    }
}

/// 解决 macOS 窗口失焦时系统 `.borderedProminent` 按钮被淡化至不可见的问题。
/// 系统在非 key 窗口中会自动降低 bezelColor 饱和度，浅色模式下淡化后的灰色
/// 与白色卡片背景几乎无差异，导致按钮"消失"。此样式自行绘制背景，不受窗口
/// 焦点状态影响，失焦时保持蓝色。
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let hPad = ButtonMetrics.horizontalPadding(for: controlSize)
        let vPad = ButtonMetrics.verticalPadding(for: controlSize)
        let radius = ButtonMetrics.cornerRadius(for: controlSize)

        return configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundFill(configuration))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.accentColor.opacity(0.25), radius: 2, y: 1)
            .opacity(isEnabled ? 1 : 0.5)
    }

    private func backgroundFill(_ configuration: Configuration) -> Color {
        guard isEnabled else { return Color.accentColor.opacity(0.4) }
        return Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    /// 固定外观的 Prominent 按钮，窗口失焦时保持蓝色不被系统淡化
    static var prominent: ProminentButtonStyle { .init() }
}

/// 次要按钮样式，与 `ProminentButtonStyle` 共享尺寸度量，确保并排时高度一致。
/// 灰底描边外观，不受窗口焦点状态影响。
/// `isDestructive` 为 true 时使用红色语义，用于删除/撤销等破坏性操作。
struct SecondaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let hPad = ButtonMetrics.horizontalPadding(for: controlSize)
        let vPad = ButtonMetrics.verticalPadding(for: controlSize)
        let radius = ButtonMetrics.cornerRadius(for: controlSize)
        let tint = isDestructive ? Color.red : Color.primary

        return configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundFill(configuration, tint: tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(0.12), lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }

    private func backgroundFill(_ configuration: Configuration, tint: Color) -> Color {
        guard isEnabled else { return tint.opacity(0.04) }
        return tint.opacity(configuration.isPressed ? 0.14 : 0.08)
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    /// 次要按钮，灰底描边，与 Prominent 按钮高度一致
    static var secondary: SecondaryButtonStyle { .init() }
    /// 破坏性次要按钮，红底描边，与 Prominent 按钮高度一致
    static var destructive: SecondaryButtonStyle { .init(isDestructive: true) }
}
