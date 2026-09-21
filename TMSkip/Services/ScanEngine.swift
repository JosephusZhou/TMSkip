import Foundation

/// Rule-based directory scan over configured roots (default ~/).
/// Matching model: same-directory name match + if-exists (tmexclude/asimov style).
struct ScanEngine: Sendable {
    struct Configuration: Sendable {
        var roots: [String]
        var skipPaths: [String]
        var rules: [RuleDefinition]
    }

    struct Hit: Sendable, Hashable {
        var path: String
        var ruleName: String
        /// true = already excluded on disk; nil = could not determine
        var alreadyExcluded: Bool?
    }

    /// Progress denominator is calibrated by a cheap pre-count that mirrors the
    /// walk's traversal rules (skip paths, symlinks, `.app` and rule-hit
    /// pruning). If the pre-count cannot finish within the cap/timeout budget,
    /// the walk falls back to a growing estimate so the bar keeps moving
    /// instead of stalling at a wrong total.
    private let countCap = 100_000
    private let countTimeout: TimeInterval = 8

    func scan(
        config: Configuration,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> [Hit] {
        let skipExpanded = Set(config.skipPaths.map { ($0 as NSString).expandingTildeInPath })
        let enabledRules = config.rules.filter(\.isEnabled)
        var hits: [Hit] = []
        var walked = 0
        var found = 0

        let counted = countDirectories(
            roots: config.roots,
            skip: skipExpanded,
            rules: enabledRules,
            cap: countCap,
            timeout: countTimeout,
            progress: progress,
            isCancelled: isCancelled
        )
        if isCancelled() { return hits }
        // A trusted denominator requires the pre-count to have finished within
        // its budget — including the timeout case, where a partial count would
        // otherwise peg the bar at 99% with "walked" exceeding "total".
        let calibrating = counted.complete
        var estimate = counted.value
        var lastFraction = 0.0

        for root in config.roots {
            let rootPath = (root as NSString).expandingTildeInPath
            walk(
                directory: rootPath,
                skip: skipExpanded,
                rules: enabledRules,
                hits: &hits,
                walked: &walked,
                found: &found,
                estimate: &estimate,
                lastFraction: &lastFraction,
                calibrating: calibrating,
                progress: progress,
                isCancelled: isCancelled
            )
            if isCancelled() { break }
        }
        return hits
    }

    private func walk(
        directory: String,
        skip: Set<String>,
        rules: [RuleDefinition],
        hits: inout [Hit],
        walked: inout Int,
        found: inout Int,
        estimate: inout Int,
        lastFraction: inout Double,
        calibrating: Bool,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        if isCancelled() { return }
        if skip.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) {
            return
        }

        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: directory) else { return }

        walked += 1
        if walked % 25 == 0 {
            if !calibrating, walked > estimate * 9 / 10 {
                estimate = max(estimate + 1, walked * 3 / 2)
            }
            let fraction = min(0.99, Double(walked) / Double(max(estimate, 1)))
            lastFraction = max(lastFraction, fraction)
            progress(ScanProgress(
                currentPath: displayPath(directory),
                walked: walked,
                found: found,
                fraction: lastFraction,
                totalDirs: calibrating ? estimate : nil,
                partialBytes: 0
            ))
        }

        let childSet = Set(children)
        for rule in rules {
            guard Self.ifExistsOK(rule, children: childSet) else { continue }
            for excludeName in rule.excludes where childSet.contains(excludeName) {
                let full = (directory as NSString).appendingPathComponent(excludeName)
                if skip.contains(where: { full == $0 || full.hasPrefix($0 + "/") }) { continue }
                // Avoid duplicates
                if hits.contains(where: { $0.path == full }) { continue }
                let already = TimeMachineExclusionService.isExcluded(at: full)
                hits.append(Hit(path: full, ruleName: rule.name, alreadyExcluded: already))
                found += 1
            }
        }

        // Recurse into subdirectories, pruning excluded hits.
        let hitNames = Set(hits.filter { ($0.path as NSString).deletingLastPathComponent == directory }.map {
            ($0.path as NSString).lastPathComponent
        })

        for name in children {
            if isCancelled() { return }
            if hitNames.contains(name) { continue } // prune excluded trees
            if Self.isAppBundleName(name) { continue } // never enter other apps' bundles
            let childPath = (directory as NSString).appendingPathComponent(name)
            guard Self.isTraversableDirectory(childPath) else { continue }
            // Skip common noisy/hidden deep caches lightly
            if name == ".git" || name == ".Trash" { continue }
            walk(
                directory: childPath,
                skip: skip,
                rules: rules,
                hits: &hits,
                walked: &walked,
                found: &found,
                estimate: &estimate,
                lastFraction: &lastFraction,
                calibrating: calibrating,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    /// Application bundles belong to other apps: writing exclusion metadata
    /// inside them triggers the system App Management (修改其他应用程序) prompt,
    /// and they are not regenerable dev directories anyway.
    static func isAppBundleName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".app")
    }

    /// Rule sentinel check: exact name match, or glob match when the sentinel
    /// contains `*`/`?` (upstream Asimov data uses e.g. `*.csproj`, `*.xcodeproj`).
    private static func ifExistsOK(_ rule: RuleDefinition, children: Set<String>) -> Bool {
        if rule.ifExists.isEmpty { return true }
        for entry in rule.ifExists {
            if children.contains(entry) { return true }
            if entry.contains("*") || entry.contains("?") {
                if children.contains(where: { globMatch(entry, $0) }) { return true }
            }
        }
        return false
    }

    /// Glob match supporting `*` and `?`, applied to a single path component
    /// (no path separators involved). `*` matches any run (incl. empty).
    static func globMatch(_ pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern)
        let v = Array(candidate)
        var pi = 0
        var vi = 0
        var star: Int?
        var starVi = 0
        while vi < v.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == v[vi]) {
                pi += 1
                vi += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi
                starVi = vi
                pi += 1
            } else if let s = star {
                pi = s + 1
                starVi += 1
                vi = starVi
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Directory probe that deliberately does NOT follow symlinks (PRD 6.5 防环).
    /// Following aliases into e.g. ~/Library would bypass the skipPaths prefix
    /// check, because matching is done on the walked path string.
    static func isTraversableDirectory(_ path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs?[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    /// Pre-count with the exact traversal semantics of `walk` (same skip
    /// paths, symlink handling, `.app` pruning and rule-hit pruning) so the
    /// progress denominator matches what the walk will actually visit.
    /// Returns the count plus whether it finished within the cap/timeout
    /// budget; `complete == false` means the walk must use a growing estimate.
    private func countDirectories(
        roots: [String],
        skip: Set<String>,
        rules: [RuleDefinition],
        cap: Int,
        timeout: TimeInterval,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> (value: Int, complete: Bool) {
        var count = 0
        var complete = true
        let deadline = Date().addingTimeInterval(timeout)
        for root in roots {
            if isCancelled() || count >= cap || Date() > deadline {
                complete = false
                break
            }
            if !countDirectories(
                in: (root as NSString).expandingTildeInPath,
                skip: skip,
                rules: rules,
                cap: cap,
                deadline: deadline,
                count: &count,
                progress: progress,
                isCancelled: isCancelled
            ) {
                complete = false
                break
            }
        }
        return (count, complete)
    }

    /// Returns false when the budget (cap/timeout) ran out inside this subtree.
    @discardableResult
    private func countDirectories(
        in directory: String,
        skip: Set<String>,
        rules: [RuleDefinition],
        cap: Int,
        deadline: Date,
        count: inout Int,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        if isCancelled() || count >= cap || Date() > deadline { return false }
        if skip.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) { return true }

        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: directory) else { return true }

        count += 1
        if count % 2000 == 0 {
            progress(ScanProgress(
                currentPath: displayPath(directory),
                walked: 0,
                found: 0,
                fraction: 0,
                totalDirs: nil,
                partialBytes: 0
            ))
        }

        // Same hit pruning as walk: never descend into directories the scan
        // would report (node_modules 等), so counted and walked stay comparable.
        let childSet = Set(children)
        var hitNames = Set<String>()
        for rule in rules {
            guard Self.ifExistsOK(rule, children: childSet) else { continue }
            for excludeName in rule.excludes where childSet.contains(excludeName) {
                let full = (directory as NSString).appendingPathComponent(excludeName)
                if skip.contains(where: { full == $0 || full.hasPrefix($0 + "/") }) { continue }
                hitNames.insert(excludeName)
            }
        }

        for name in children {
            if count >= cap { return false }
            if hitNames.contains(name) { continue }
            if name == ".git" || name == ".Trash" { continue }
            if Self.isAppBundleName(name) { continue }
            let childPath = (directory as NSString).appendingPathComponent(name)
            guard Self.isTraversableDirectory(childPath) else { continue }
            if !countDirectories(
                in: childPath,
                skip: skip,
                rules: rules,
                cap: cap,
                deadline: deadline,
                count: &count,
                progress: progress,
                isCancelled: isCancelled
            ) {
                return false
            }
        }
        return true
    }

    private func displayPath(_ absolute: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absolute.hasPrefix(home) {
            return "~" + absolute.dropFirst(home.count)
        }
        return absolute
    }
}

extension ScanEngine.Hit {
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
