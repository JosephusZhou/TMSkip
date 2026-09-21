import AppKit
import Foundation

/// Best-effort Full Disk Access detection + settings deep link.
/// Exact FDA APIs are private; we probe readable paths that typically require FDA.
@MainActor
final class FullDiskAccessService: ObservableObject {
    @Published private(set) var isGranted: Bool = false
    @Published private(set) var lastCheckedAt: Date?

    func refresh() {
        isGranted = Self.probe()
        lastCheckedAt = Date()
    }

    func openSystemSettings() {
        // macOS Ventura+ Privacy pane for Full Disk Access
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Fallback: open System Settings app
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    nonisolated private static func probe() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard (try? FileManager.default.contentsOfDirectory(atPath: home.path)) != nil else {
            return false
        }
        // Only list trees TCC actually gates behind FDA. Permissive spots such
        // as ~/Library/Caches are readable without FDA and would report a false
        // "granted". Safari exists on every macOS install; Mail is the second
        // (optional) signal. One readable gated tree means FDA is on.
        let gated: [URL] = [
            home.appendingPathComponent("Library/Safari"),
            home.appendingPathComponent("Library/Mail"),
        ]
        return gated.contains { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
    }
}
