import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+, matching the deployment
/// target). Kept as a shell so registration mechanics stay out of AppModel.
///
/// Reliability note (PLAN §5 / §11): under ad-hoc signing registration works
/// but is not stable across recompiles (same designated-requirement logic as
/// TCC). A Developer ID signed release build is what makes login items stick.
@MainActor
final class LoginItemService {
    private let service = SMAppService.mainApp

    /// Current system registration state.
    var isRegistered: Bool { service.status == .enabled }

    /// Sync the login item with the desired toggle. No-op when state already
    /// matches; throws the underlying SMAppService error otherwise so AppModel
    /// can flash the concrete reason (e.g. invalid signature).
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
