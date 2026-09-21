import Foundation

// MARK: - Navigation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case manualScan
    case ignoreList
    case scanSettings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manualScan: return "手动扫描"
        case .ignoreList: return "忽略列表"
        case .scanSettings: return "扫描配置"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .manualScan: return "dot.radiowaves.left.and.right"
        case .ignoreList: return "eye.slash"
        case .scanSettings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Scan

enum ScanPhase: Equatable {
    case idle
    case running
    case result
    case applying
    case done
}

enum ApplyPolicy: String, CaseIterable, Identifiable, Codable {
    case notifyConfirm
    case autoApply

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifyConfirm: return "通知我，手动确认后应用"
        case .autoApply: return "自动应用"
        }
    }

    var subtitle: String {
        switch self {
        case .notifyConfirm: return "系统通知 + 菜单栏点标 + App 内待处理（推荐）"
        case .autoApply: return "扫描后立即写入排除；可发弱通知"
        }
    }
}

enum ScanTriggerMode: String, CaseIterable, Identifiable, Codable {
    case intervalOnly
    case fsEventsOnly
    case intervalAndFSEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intervalOnly: return "仅定时"
        case .fsEventsOnly: return "仅 FSEvents（防抖 30s）"
        case .intervalAndFSEvents: return "定时 + FSEvents"
        }
    }
}

enum ScanInterval: Int, CaseIterable, Identifiable, Codable {
    case minutes15 = 15
    case minutes30 = 30
    case hour1 = 60
    case hours6 = 360
    case hours12 = 720
    case daily = 1440

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .minutes15: return "15 分钟"
        case .minutes30: return "30 分钟"
        case .hour1: return "1 小时"
        case .hours6: return "6 小时"
        case .hours12: return "12 小时"
        case .daily: return "每天"
        }
    }
}

struct ScanRoot: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// Tilde form for display/config, e.g. "~"
    var path: String
    /// Resolved absolute path when available
    var resolvedPath: String?

    static var home: ScanRoot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ScanRoot(path: "~", resolvedPath: home)
    }
}

/// Whether the path is already excluded from Time Machine (by TMSkip, tmexclude, asimov, or manual tmutil).
enum ExistingExclusionState: String, Hashable, Codable {
    case notExcluded
    case alreadyExcluded
    case unknown

    var title: String {
        switch self {
        case .notExcluded: return "未排除"
        case .alreadyExcluded: return "已排除"
        case .unknown: return "状态未知"
        }
    }
}

struct ScanCandidate: Identifiable, Hashable {
    var id: UUID = UUID()
    var path: String
    var ruleName: String
    var byteSize: Int64?
    var sizeState: SizeComputeState = .pending
    /// Current TM exclusion on disk (shared with tmexclude / asimov / tmutil).
    var exclusionState: ExistingExclusionState = .unknown
    /// Default: only select paths that are NOT already excluded.
    var isSelected: Bool = true

    var needsExclude: Bool { exclusionState != .alreadyExcluded }
}

enum SizeComputeState: Equatable, Hashable {
    case pending
    case computing
    case ready
    case unavailable
    case timedOut
}

struct ScanProgress: Equatable {
    var currentPath: String = ""
    var walked: Int = 0
    var found: Int = 0
    var fraction: Double = 0
    /// Exact directory total once the calibration pre-count finishes; nil while
    /// counting or when the pre-count hit its cap/timeout budget (fraction then
    /// uses a growing estimate).
    var totalDirs: Int? = nil
    var partialBytes: Int64 = 0
}

struct ScanOutcome: Equatable {
    var excludedCount: Int = 0
    var excludedBytes: Int64 = 0
    var failedCount: Int = 0
    /// Paths that could not be written (permission or other I/O errors).
    var failedPaths: [String] = []
    /// At least one failure looked like a system permission block (e.g. App Management).
    var permissionBlocked: Bool = false
    /// Candidates inside other applications' bundles — intentionally not written.
    var appBundleBlockedPaths: [String] = []
}

// MARK: - Ignore list

enum IgnoreStatus: String, Codable, CaseIterable, Identifiable {
    case excluded
    case anomaly
    case missing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excluded: return "已忽略"
        case .anomaly: return "状态异常"
        case .missing: return "路径不存在"
        }
    }
}

enum IgnoreSource: String, Codable {
    case manualScan
    case autoScan
    case thisApp
    case manualAdd
    case unknown

    var title: String {
        switch self {
        case .manualScan: return "手动扫描"
        case .autoScan: return "自动扫描"
        case .thisApp: return "本 App"
        case .manualAdd: return "手动添加"
        case .unknown: return "未知"
        }
    }
}

struct IgnoreRecord: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var path: String
    var source: IgnoreSource
    var status: IgnoreStatus
    var ruleName: String?
    var byteSize: Int64?
    var createdAt: Date
    var updatedAt: Date
    var lastVerifiedAt: Date?

    var isSelected: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, path, source, status, ruleName, byteSize, createdAt, updatedAt, lastVerifiedAt
    }
}

// MARK: - Rules

struct RuleDefinition: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var excludes: [String]
    var ifExists: [String]
    var group: String
    var isEnabled: Bool
}

enum RulePackageOrigin: String, Codable, Equatable {
    case bundled
    case remoteCache

    var title: String {
        switch self {
        case .bundled: return "内置兜底"
        case .remoteCache: return "远程缓存"
        }
    }

    var detail: String {
        switch self {
        case .bundled: return "随应用发布的 Asimov 兼容规则，离线可用"
        case .remoteCache: return "上次成功从 Asimov 上游同步的规则"
        }
    }
}

struct RulePackage: Codable, Equatable {
    var version: String
    var origin: RulePackageOrigin
    /// Human-readable source, e.g. "Asimov develop@abc1234"
    var source: String
    var syncedAt: Date?
    var upstreamURL: String?
    var rules: [RuleDefinition]

    var enabledCount: Int { rules.filter(\.isEnabled).count }

    var summaryLine: String {
        let originText = origin.title
        let sync: String
        if let syncedAt {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            sync = f.string(from: syncedAt)
        } else {
            sync = "未同步"
        }
        return "\(originText) · \(version) · \(rules.count) 条 · 已启用 \(enabledCount) · \(sync)"
    }

    /// Preserve user enable toggles when replacing package content.
    func mergingEnabledStates(from previous: RulePackage?) -> RulePackage {
        guard let previous else { return self }
        var copy = self
        let map = Dictionary(uniqueKeysWithValues: previous.rules.map { ($0.id, $0.isEnabled) })
        for i in copy.rules.indices {
            if let enabled = map[copy.rules[i].id] {
                copy.rules[i].isEnabled = enabled
            }
        }
        return copy
    }
}

struct RuleUpdateReport: Equatable {
    enum Kind: Equatable {
        case success
        case failedUsingActive
        case restoredBundled
    }

    var kind: Kind
    var message: String
    var checkedAt: Date
}


// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var autoScanEnabled: Bool = true
    var scanInterval: ScanInterval = .minutes30
    var triggerMode: ScanTriggerMode = .intervalAndFSEvents
    var launchAtLogin: Bool = true
    var applyPolicy: ApplyPolicy = .notifyConfirm
    var notificationsEnabled: Bool = true
    var noReinclude: Bool = true
    var supportDump: Bool = false
    var roots: [ScanRoot] = [.home]
    var skipPaths: [String] = AppSettings.defaultSkipPaths
    var rulePackage: RulePackage = .bundledSnapshot
    /// Last successful remote package (may equal rulePackage when origin == remoteCache).
    var remoteRuleCache: RulePackage? = nil
    var lastRuleCheckAt: Date? = nil
    var lastRuleCheckSucceeded: Bool? = nil
    var lastRuleCheckMessage: String? = nil
    /// Anchor for the interval trigger; the coordinator catches up on launch
    /// when the gap since this date exceeds `scanInterval`.
    var lastAutoScanAt: Date? = nil
    /// PRD §6.4.4 daily background rule check (user-toggleable).
    var autoRuleSync: Bool = true

    /// Explicit coding keys so the custom decoder below can evolve independently
    /// of the synthesized memberwise initializer; new fields simply get a key here.
    enum CodingKeys: String, CodingKey {
        case autoScanEnabled
        case scanInterval
        case triggerMode
        case launchAtLogin
        case applyPolicy
        case notificationsEnabled
        case noReinclude
        case supportDump
        case roots
        case skipPaths
        case rulePackage
        case remoteRuleCache
        case lastRuleCheckAt
        case lastRuleCheckSucceeded
        case lastRuleCheckMessage
        case lastAutoScanAt
        case autoRuleSync
    }

    static let defaultSkipPaths = [
        "~/Library",
        "~/Pictures",
        "~/Downloads",
        "~/Desktop",
        "~/Documents",
        "~/.Trash",
        "~/.npm",
        "~/.pnpm-store",
        "~/.vscode",
        "~/Dropbox",
        "~/.dropbox",
    ]

    /// Shared repair for user-typed and stored skip paths: full-width tilde
    /// (～ U+FF5E) never matches the half-width paths the scanner walks, and
    /// trailing slashes ("/a/b/") can never match its "/a/b" path strings.
    static func normalizeSkipPath(_ raw: String) -> String {
        var path = raw
            .replacingOccurrences(of: "\u{FF5E}", with: "~")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// "~/..." form for paths under the home directory (display consistency
    /// with the built-in skip list).
    static func abbreviateHome(_ path: String) -> String {
        guard !path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension AppSettings {
    /// Hardened decoding: every field uses `decodeIfPresent ?? default`, and a
    /// single corrupt field (e.g. an enum raw value unknown to an older build)
    /// falls back to its default instead of throwing KeyNotFound/typeMismatch
    /// and wiping the whole configuration. This is the forward-compatibility
    /// floor: adding a field with a default must never reset a user's settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func fallback<T: Decodable>(_ key: CodingKeys, _ fallbackValue: T) -> T {
            // `try?` also swallows a mismatched/garbage value for this one field.
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallbackValue
        }

        autoScanEnabled = fallback(.autoScanEnabled, true)
        scanInterval = fallback(.scanInterval, ScanInterval.minutes30)
        triggerMode = fallback(.triggerMode, ScanTriggerMode.intervalAndFSEvents)
        launchAtLogin = fallback(.launchAtLogin, true)
        applyPolicy = fallback(.applyPolicy, ApplyPolicy.notifyConfirm)
        notificationsEnabled = fallback(.notificationsEnabled, true)
        noReinclude = fallback(.noReinclude, true)
        supportDump = fallback(.supportDump, false)
        roots = fallback(.roots, [ScanRoot.home])
        skipPaths = fallback(.skipPaths, AppSettings.defaultSkipPaths)
        rulePackage = fallback(.rulePackage, RulePackage.bundledSnapshot)
        remoteRuleCache = try? c.decodeIfPresent(RulePackage.self, forKey: .remoteRuleCache) ?? nil
        lastRuleCheckAt = try? c.decodeIfPresent(Date.self, forKey: .lastRuleCheckAt) ?? nil
        lastRuleCheckSucceeded = try? c.decodeIfPresent(Bool.self, forKey: .lastRuleCheckSucceeded) ?? nil
        lastRuleCheckMessage = try? c.decodeIfPresent(String.self, forKey: .lastRuleCheckMessage) ?? nil
        lastAutoScanAt = try? c.decodeIfPresent(Date.self, forKey: .lastAutoScanAt) ?? nil
        autoRuleSync = fallback(.autoRuleSync, true)
    }
}

// MARK: - Formatting

enum ByteFormat {
    static func string(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return "约 \(formatter.string(fromByteCount: bytes))"
    }
}
