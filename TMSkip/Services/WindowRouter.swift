import AppKit
import SwiftUI

/// Reopens / focuses the main window even after the user closed it.
///
/// `NSApp.windows` no longer contains the WindowGroup window once it has been
/// closed (PLAN §4 hidden pitfall), so focusing an existing window is not
/// enough. The SwiftUI scene binds its `openWindow` action here via
/// `WindowBinder`; when no titled window exists we recreate the scene.
///
/// Binding-order pitfall: a notification tap (or Dock reopen) can arrive before
/// the `WindowGroup` scene has ever appeared in this process — e.g. the app was
/// launched by the login item and kept running as a menu-bar app, or it was
/// cold-launched by the notification itself. At that point `openWindowAction`
/// is still nil and the open request would be silently dropped, leaving the
/// user with no window. `openMainWindow` therefore records a pending request
/// and `bind` replays it as soon as the scene appears.
@MainActor
final class WindowRouter: ObservableObject {
    private var openWindowAction: OpenWindowAction?
    private var pendingOpen = false

    /// Captured from `@Environment(\.openWindow)` inside the main scene.
    func bind(_ action: OpenWindowAction) {
        openWindowAction = action
        if pendingOpen {
            pendingOpen = false
            openMainWindow()
        }
    }

    /// Focus an existing titled main window, otherwise recreate the scene.
    /// `select` runs first to update the selected sidebar item.
    func openMainWindow(select: (() -> Void)? = nil) {
        // 恢复常规策略，Dock 图标重新出现。必须在建窗/置前之前调用：
        // .accessory 下新建窗口可能不置前，后面的 activate 负责兜底。
        NSApp.setActivationPolicy(.regular)
        select?()

        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let openWindowAction else {
            // Scene not bound yet: remember the intent and replay it on bind
            // instead of dropping the request.
            pendingOpen = true
            return
        }

        openWindowAction(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Invisible bridge that hands the scene-scoped `openWindow` action to the
/// `WindowRouter` (environment values are only available inside a View).
/// `app` is passed explicitly: a `.background()` view does not reliably
/// inherit an `.environmentObject` attached earlier in the modifier chain.
struct WindowBinder: View {
    @Environment(\.openWindow) private var openWindow
    let app: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { app.windowRouter.bind(openWindow) }
    }
}
