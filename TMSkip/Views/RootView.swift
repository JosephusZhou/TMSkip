import Combine
import SwiftUI

extension UIMode {
    /// 解析当前应生效的 SwiftUI 环境色，**永不返回 nil**：
    /// `.system` 时实时读取系统当前外观（浅/深）并返回具体值，
    /// 显式模式下返回固定值。避免 macOS 上「先设显式外观、再设
    /// `preferredColorScheme(nil)` 无法恢复跟随系统」的已知问题。
    var resolvedColorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return Self.systemIsDark() ? .dark : .light
        }
    }

    /// 与 `resolvedColorScheme` 同源的 NSAppearance（永不返回 nil），
    /// 供窗口级同步器直接赋值。
    var resolvedAppearance: NSAppearance {
        resolvedColorScheme == .dark
            ? NSAppearance(named: .darkAqua)!
            : NSAppearance(named: .aqua)!
    }

    /// 系统当前是否为深色外观。
    /// 直接读系统设置（Apple Global Domain 的 AppleInterfaceStyle），
    /// **不依赖 NSApp.effectiveAppearance**——macOS 上把 `NSApp.appearance`
    /// 设为显式值后再置 nil 并不总能还原系统外观，effectiveAppearance
    /// 可能停留在旧值，导致跟随系统解析出错。
    static func systemIsDark() -> Bool {
        let style = UserDefaults.standard
            .persistentDomain(forName: "Apple Global Domain")?["AppleInterfaceStyle"] as? String
        return style == "Dark"
    }
}

/// 外观同步器：每个承载窗口（主窗口 / MenuBarExtra 弹窗）自己订阅设置变化、
/// 系统主题变化，并**直接写本窗口外观**。不依赖 `applyUIMode()` 遍历
/// `NSApp.windows`——MenuBarExtra 面板不在该列表内，打开状态切换模式时
/// 只能由本窗口自己兜底。自身不缓存模式值，全部从当前设置实时解析。
struct AppearanceSynchronizer: NSViewRepresentable {
    let app: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let host = AppearanceHostView()
        host.onWindowChange = { [weak coordinator] in
            coordinator?.applyToOwnWindow()
        }
        coordinator.attach(to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.applyToOwnWindow()
    }

    final class Coordinator: NSObject {
        private weak var app: AppModel?
        private weak var view: NSView?
        private var observers: [Any] = []
        private var settingsCancellable: AnyCancellable?

        init(app: AppModel) { self.app = app }

        func attach(to view: NSView) {
            self.view = view
            Task { @MainActor [weak self] in
                self?.subscribe()
            }
        }

        @MainActor
        private func subscribe() {
            guard settingsCancellable == nil else { return }
            // 1) 设置变化（含模式切换）→ 直接把本窗口外观写成当前解析值。
            //    弹窗开着时从主窗口切换模式也走这条订阅，实时生效。
            settingsCancellable = app?.settingsStore.$settings
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.applyToOwnWindow()
                }
            // 2) 系统主题变化（跟随系统模式）→ 重新解析并写本窗口。
            if observers.isEmpty {
                observers = [
                    DistributedNotificationCenter().addObserver(
                        forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        self?.applyToOwnWindow()
                    },
                ]
            }
        }

        /// 直接写本窗口外观（从当前设置实时解析，不缓存旧值）。
        func applyToOwnWindow() {
            Task { @MainActor [weak self] in
                guard let self, let window = self.view?.window else { return }
                window.appearance = self.app?.settings.uiMode.resolvedAppearance
            }
        }
    }
}

/// 在视图挂入窗口/切窗口时回调（弹窗每次重开都会新建内容视图，
/// 此时窗口已存在，需要重新应用一次外观）。
private final class AppearanceHostView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

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
        .preferredColorScheme(app.settings.uiMode.resolvedColorScheme)
        .background(AppearanceSynchronizer(app: app))
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
