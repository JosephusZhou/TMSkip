import AppKit
import SwiftUI

/// Bridges system "reopen" events (Dock icon click, notification click while
/// the app is running with no visible window) to `AppModel.openMainWindow()`.
///
/// SwiftUI's default reopen handling recreates the WindowGroup scene; this
/// handler additionally routes through `WindowRouter` (which owns the
/// focus-or-recreate logic and the not-yet-bound fallback), so the main window
/// reliably comes back in the same process instead of leaving the user with
/// nothing — or, after a crash, with a fresh instance started by the system.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 关闭最后一个主窗口后切到 .accessory：Dock 图标消失，进程与
        // 状态栏图标（MenuBarExtra）保留；菜单栏「打开主窗口」再切回 .regular。
        // AppKit 只有 willClose 通知；把判断延后到下一轮 RunLoop，此时窗口
        // 已完成关闭、isVisible 为 false，不会把正在关闭的窗口误判为仍可见。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled)
            else { return }
            DispatchQueue.main.async {
                let hasVisibleTitledWindow = NSApp.windows.contains {
                    $0.styleMask.contains(.titled) && $0.isVisible
                }
                if !hasVisibleTitledWindow {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NotificationCenter.default.post(
                name: .tmskipRequestOpenMainWindow,
                object: nil
            )
        }
        // Returning true keeps SwiftUI's own scene recreation as a backup path;
        // `WindowRouter` de-duplicates against it.
        return true
    }
}

extension Notification.Name {
    /// Posted when the system asks the app to reopen its main window
    /// (Dock click / reopen event with no visible windows).
    static let tmskipRequestOpenMainWindow = Notification.Name(
        "app.tmskip.requestOpenMainWindow"
    )
}

@main
struct TMSkipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("TMSkip", id: "main") {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowBinder(app: appModel))
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appModel)
        } label: {
            MenuBarLabelView()
                .environmentObject(appModel)
        }
        .menuBarExtraStyle(.window)
    }
}
