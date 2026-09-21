import Foundation

/// Read/write Time Machine "excluded from backup" resource value.
enum TimeMachineExclusionService {
    enum ExclusionError: LocalizedError {
        case invalidURL
        case setFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "路径无效"
            case .setFailed(let msg): return msg
            }
        }
    }

    static func isExcluded(at path: String) -> Bool? {
        let url = URL(fileURLWithPath: expand(path))
        do {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            return values.isExcludedFromBackup
        } catch {
            return nil
        }
    }

    static func setExcluded(_ excluded: Bool, at path: String) throws {
        var url = URL(fileURLWithPath: expand(path))
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        do {
            try url.setResourceValues(values)
        } catch {
            throw ExclusionError.setFailed(error.localizedDescription)
        }
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
