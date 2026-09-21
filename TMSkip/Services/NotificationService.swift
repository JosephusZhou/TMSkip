import Foundation
import UserNotifications

/// UserNotifications thin shell: authorization, one replaceable pending
/// notification, a weak auto-applied notification, and click → open + promote.
///
/// Timing requirement (PLAN §4 / §11): the UN delegate MUST be installed
/// before the app finishes launching, otherwise the click callback is dropped.
/// `AppModel.init` (created inside `TMSkipApp.init`) therefore calls
/// `install()` immediately.
@MainActor
final class NotificationService: NSObject {
    /// Fixed identifiers so a new wave *replaces* the old banner instead of
    /// stacking duplicates (PRD §16.2 防打扰).
    static let pendingIdentifier = "tmskip.auto-pending"
    static let appliedIdentifier = "tmskip.auto-applied"

    private let center = UNUserNotificationCenter.current()
    private var hasRequested = false
    private(set) var isAuthorized = false
    private var hasWarnedDenied = false

    /// Tap on the pending notification → open main window + promote the queue.
    var onOpenPending: (() -> Void)?
    /// Authorization was denied once → AppModel flashes the menu-badge fallback.
    var onAuthorizationDenied: (() -> Void)?

    func install() {
        center.delegate = self
    }

    /// Lazily request authorization before the first real notification.
    @discardableResult
    private func ensureAuthorization() async -> Bool {
        if hasRequested { return isAuthorized }
        hasRequested = true
        isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        if !isAuthorized, !hasWarnedDenied {
            hasWarnedDenied = true
            onAuthorizationDenied?()
        }
        return isAuthorized
    }

    /// notifyConfirm: "发现 N 个可排除目录，点击处理". Replaces any prior banner.
    func notifyPending(count: Int, enabled: Bool) {
        guard enabled, count > 0 else { return }
        Task {
            guard await ensureAuthorization() else { return }
            let content = UNMutableNotificationContent()
            content.title = "TMSkip"
            content.body = "发现 \(count) 个可排除目录，点击处理"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.pendingIdentifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// autoApply weak notification: no sound, informational only.
    func notifyAutoApplied(count: Int, enabled: Bool) {
        guard enabled, count > 0 else { return }
        Task {
            guard await ensureAuthorization() else { return }
            let content = UNMutableNotificationContent()
            content.title = "TMSkip"
            content.body = "已自动排除 \(count) 个可再生目录"
            let request = UNNotificationRequest(
                identifier: Self.appliedIdentifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Remove a stale pending banner once the user has opened the queue.
    func clearPendingBanner() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.pendingIdentifier])
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Keep banners visible even when the menu-bar app is frontmost.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            guard identifier == Self.pendingIdentifier else { return }
            self.onOpenPending?()
        }
    }
}
