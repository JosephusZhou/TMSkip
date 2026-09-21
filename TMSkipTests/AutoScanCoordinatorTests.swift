import XCTest
@testable import TMSkip

/// Tests for the injectable-clock pure decision core of automatic scanning.
/// FSEvents / UNUserNotificationCenter / SMAppService stay thin shells and are
/// not unit-tested (PLAN §10).
final class AutoScanCoordinatorTests: XCTestCase {

    // MARK: Trigger sources per mode

    func testTriggerModeSourceSelection() {
        XCTAssertTrue(AutoScanLogic.usesTimer(.intervalOnly))
        XCTAssertFalse(AutoScanLogic.usesFSEvents(.intervalOnly))

        XCTAssertFalse(AutoScanLogic.usesTimer(.fsEventsOnly))
        XCTAssertTrue(AutoScanLogic.usesFSEvents(.fsEventsOnly))

        XCTAssertTrue(AutoScanLogic.usesTimer(.intervalAndFSEvents))
        XCTAssertTrue(AutoScanLogic.usesFSEvents(.intervalAndFSEvents))
    }

    // MARK: Minimum-interval throttle (合流节流)

    func testAllowsScanThrottleGate() {
        let now = Date(timeIntervalSince1970: 10_000)
        // Never scanned → allowed immediately.
        XCTAssertTrue(AutoScanLogic.allowsScan(now: now, lastScanAt: nil, minInterval: 300))
        // 4 minutes after last scan, 5-minute floor → blocked.
        let recent = now.addingTimeInterval(-240)
        XCTAssertFalse(AutoScanLogic.allowsScan(now: now, lastScanAt: recent, minInterval: 300))
        // 6 minutes after → allowed.
        let stale = now.addingTimeInterval(-360)
        XCTAssertTrue(AutoScanLogic.allowsScan(now: now, lastScanAt: stale, minInterval: 300))
        // Exactly at the boundary → allowed.
        let boundary = now.addingTimeInterval(-300)
        XCTAssertTrue(AutoScanLogic.allowsScan(now: now, lastScanAt: boundary, minInterval: 300))
    }

    /// Regression: a "每天" (1440 min) interval must also throttle FSEvents-driven
    /// scans. Before the fix, every trigger source only respected the 5-minute
    /// hard floor, so `intervalAndFSEvents` with a daily interval still rescanned
    /// every few minutes of file activity.
    func testEffectiveMinIntervalThrottlesFSEventsByConfiguredInterval() {
        // 5-minute hard floor applies when the interval is shorter.
        XCTAssertEqual(
            AutoScanLogic.effectiveMinInterval(minRescanInterval: 300, scanInterval: 60),
            300
        )
        // The configured interval wins when it is longer than the floor:
        // daily = 86_400s, so FSEvents can no longer rescan every 5 minutes.
        XCTAssertEqual(
            AutoScanLogic.effectiveMinInterval(minRescanInterval: 300, scanInterval: 86_400),
            86_400
        )
        XCTAssertEqual(
            AutoScanLogic.effectiveMinInterval(minRescanInterval: 300, scanInterval: 900),
            900
        )
    }

    /// The effective floor must actually gate `allowsScan` for every source:
    /// 2 minutes after a scan with a daily interval → blocked.
    func testEffectiveMinIntervalGatesScan() {
        let now = Date(timeIntervalSince1970: 10_000)
        let scanned = now.addingTimeInterval(-120)
        let minInterval = AutoScanLogic.effectiveMinInterval(
            minRescanInterval: 300,
            scanInterval: 86_400
        )
        XCTAssertFalse(AutoScanLogic.allowsScan(now: now, lastScanAt: scanned, minInterval: minInterval))
    }

    // MARK: Interval deadline / catch-up

    func testSecondsUntilDeadline() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AutoScanLogic.secondsUntilDeadline(now: now, lastScanAt: nil, interval: 1800), 0)

        let scanned = now.addingTimeInterval(-600)
        XCTAssertEqual(
            AutoScanLogic.secondsUntilDeadline(now: now, lastScanAt: scanned, interval: 1800),
            1200
        )
        // Overdue → 0 (catch-up immediately), never negative.
        let overdue = now.addingTimeInterval(-3600)
        XCTAssertEqual(
            AutoScanLogic.secondsUntilDeadline(now: now, lastScanAt: overdue, interval: 1800),
            0
        )
    }

    // MARK: Pending queue merge de-dup (队列合并去重)

    private func candidate(_ path: String) -> ScanCandidate {
        ScanCandidate(path: path, ruleName: "npm", exclusionState: .notExcluded)
    }

    func testMergePendingDeduplicatesByPathAndKeepsExisting() {
        var existing = candidate("~/a/node_modules")
        existing.byteSize = 1234
        existing.sizeState = .ready

        let incomingSame = candidate("~/a/node_modules")
        let incomingNew = candidate("~/b/node_modules")

        let merged = AutoScanLogic.mergePending(
            existing: [existing],
            incoming: [incomingSame, incomingNew]
        )

        XCTAssertEqual(merged.map(\.path), ["~/a/node_modules", "~/b/node_modules"])
        // Existing entry (with computed size) wins over the incoming duplicate.
        XCTAssertEqual(merged.first?.byteSize, 1234)
        XCTAssertEqual(merged.first?.sizeState, .ready)
    }

    func testMergePendingWithEmptyExisting() {
        let merged = AutoScanLogic.mergePending(existing: [], incoming: [candidate("x"), candidate("y")])
        XCTAssertEqual(merged.map(\.path), ["x", "y"])
    }

    // MARK: Result routing split (策略分流)

    private func hit(_ path: String, already: Bool?) -> ScanEngine.Hit {
        ScanEngine.Hit(path: path, ruleName: "npm", alreadyExcluded: already)
    }

    func testClassifiesAlreadyExcludedVsFresh() {
        let hits = [
            hit("/old/node_modules", already: true),
            hit("/new1/node_modules", already: false),
            hit("/new2/node_modules", already: nil)
        ]

        let already = AutoScanLogic.alreadyExcluded(from: hits)
        let fresh = AutoScanLogic.fresh(from: hits)

        XCTAssertEqual(already.map(\.path), ["/old/node_modules"])
        XCTAssertEqual(fresh.map(\.path), ["/new1/node_modules", "/new2/node_modules"],
                       "未排除与状态未知都属于待处理新候选")
    }
}
