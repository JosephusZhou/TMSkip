import CryptoKit
import Foundation

/// Manages L0 bundled fallback, L1 remote cache, and L2 live fetch from Asimov.
///
/// Priority for scanning:
/// 1. Active `settings.rulePackage` (user-facing package, may be bundled or remote cache)
/// 2. On fetch failure: keep active package; never block scan
///
/// Asimov has no rule API — rules live in `data/sentinels.tsv` as
/// `dir<TAB>sentinel<TAB>ecosystem` rows (the v0.12.0 restructure replaced the
/// old `ASIMOV_VENDOR_DIR_SENTINELS` bash array). We fetch that data file and
/// parse rows; the upstream version comes best-effort from `bin/asimov`'s
/// `ASIMOV_VERSION`.
actor RulePackageService {
    static let shared = RulePackageService()

    /// Prefer the default branch (`main`); keep `master` as a fallback in case
    /// upstream renames it. `develop` no longer exists after the v0.12.0 restructure.
    private let candidateBranches = ["main", "master"]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    struct FetchResult: Sendable {
        var package: RulePackage
        var rawByteCount: Int
        var sourceURL: URL
    }

    enum ServiceError: Error, LocalizedError {
        case allEndpointsFailed
        case parseFailed(String)
        case emptyRules

        var errorDescription: String? {
            switch self {
            case .allEndpointsFailed: return "无法连接 Asimov 上游"
            case .parseFailed(let m): return "解析 Asimov 规则失败：\(m)"
            case .emptyRules: return "上游未解析到任何规则"
            }
        }
    }

    func fetchLatestFromAsimov() async throws -> FetchResult {
        var lastError: Error?
        for branch in candidateBranches {
            do {
                let dataURL = URL(string: "https://raw.githubusercontent.com/stevegrunwell/asimov/\(branch)/data/sentinels.tsv")!
                let (data, response) = try await session.data(from: dataURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = ServiceError.allEndpointsFailed
                    continue
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    lastError = ServiceError.parseFailed("非 UTF-8 内容")
                    continue
                }
                let rules = try Self.parseSentinelsTSV(text)
                guard !rules.isEmpty else { throw ServiceError.emptyRules }

                // Best-effort upstream version from the launcher on the same
                // branch; if that fails the stamp falls back to `asimov-remote`.
                var launcherHeader = ""
                if let launcherURL = URL(string: "https://raw.githubusercontent.com/stevegrunwell/asimov/\(branch)/bin/asimov"),
                   let (launcherData, launcherResponse) = try? await session.data(from: launcherURL),
                   (launcherResponse as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
                   let launcher = String(data: launcherData, encoding: .utf8) {
                    launcherHeader = launcher
                }

                let version = Self.versionStamp(for: rules, scriptHeader: launcherHeader)
                let package = RulePackage(
                    version: version,
                    origin: .remoteCache,
                    source: "Asimov 上游（sentinels.tsv @ \(branch)）",
                    syncedAt: Date(),
                    upstreamURL: dataURL.absoluteString,
                    rules: rules
                )
                return FetchResult(package: package, rawByteCount: data.count, sourceURL: dataURL)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? ServiceError.allEndpointsFailed
    }

    /// Parse `data/sentinels.tsv`: `dir<TAB>sentinel<TAB>ecosystem<TAB>note`.
    /// Blank lines and `#` comments are ignored; entries with fewer than two
    /// columns are dropped.
    nonisolated static func parseSentinelsTSV(_ text: String) throws -> [RuleDefinition] {
        var rules: [RuleDefinition] = []
        var seen = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2 else { continue }
            let exclude = cols[0]
            let sentinel = cols[1]
            guard !exclude.isEmpty, !sentinel.isEmpty else { continue }
            let ecosystem = cols.count >= 3 ? cols[2] : ""

            // id stable-ish from pair. Only `/` is normalized (path hygiene);
            // `.` must stay verbatim or `.build` and `_build` would collide.
            let id = "asimov-\(exclude)-\(sentinel)"
                .replacingOccurrences(of: "/", with: "_")
            if seen.contains(id) { continue }
            seen.insert(id)

            let group = groupName(ecosystem: ecosystem)
            let name = displayName(exclude: exclude, sentinel: sentinel)
            rules.append(
                RuleDefinition(
                    id: id,
                    name: name,
                    excludes: [exclude],
                    ifExists: [sentinel],
                    group: group,
                    isEnabled: defaultEnabled(group: group, exclude: exclude)
                )
            )
        }

        if rules.isEmpty {
            throw ServiceError.parseFailed("未匹配到有效目录/哨兵对")
        }
        return rules.sorted { ($0.group, $0.name) < ($1.group, $1.name) }
    }

    /// Stable stamp: upstream version when present (either `@version X` in the
    /// old script header or `ASIMOV_VERSION='X'` in the v0.12.0+ launcher), plus
    /// rule count and a short digest of the parsed rule content. No wall-clock
    /// date — syncing identical rules must not bump the version the user sees.
    /// Internal (not private) so TMSkipTests can pin its format.
    nonisolated static func versionStamp(for rules: [RuleDefinition], scriptHeader script: String) -> String {
        let base: String
        if let r = try? NSRegularExpression(pattern: #"@version\s+([0-9.]+)|ASIMOV_VERSION='([0-9.]+)'"#),
           let m = r.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) {
            if let range = Range(m.range(at: 1), in: script), !script[range].isEmpty {
                base = "asimov-\(script[range])"
            } else if let range = Range(m.range(at: 2), in: script), !script[range].isEmpty {
                base = "asimov-\(script[range])"
            } else {
                base = "asimov-remote"
            }
        } else {
            base = "asimov-remote"
        }
        return "\(base)-\(rules.count)r-\(contentDigest(of: rules))"
    }

    nonisolated private static func contentDigest(of rules: [RuleDefinition]) -> String {
        let payload = rules
            .map { "\($0.id)|\($0.excludes.joined(separator: ","))|\($0.ifExists.joined(separator: ","))" }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Maps the upstream ecosystem column to the app's display groups. Must stay
    /// in sync with `RulePackage.bundledSnapshot` so remote and bundled rules
    /// land in the same groups and share the same default-on policy.
    nonisolated private static func groupName(ecosystem: String) -> String {
        switch ecosystem {
        case "javascript": return "Node.js"
        case "gradle", "java", "scala": return "JVM"
        case "swift": return "Apple"
        case "terraform", "aws": return "Infra"
        case "vagrant": return "Other"
        case "shell": return "Shell"
        case "dotnet": return ".NET"
        case "php": return "PHP"
        default:
            if ecosystem.isEmpty { return "Other" }
            return ecosystem.prefix(1).uppercased() + ecosystem.dropFirst()
        }
    }

    nonisolated private static func displayName(exclude: String, sentinel: String) -> String {
        "\(exclude) ← \(sentinel)"
    }

    nonisolated private static func defaultEnabled(group: String, exclude: String) -> Bool {
        // Keep noisy/legacy off by default, same spirit as bundled snapshot.
        if exclude == "bower_components" { return false }
        if group == "Other" || group == "Infra" { return false }
        return true
    }
}
