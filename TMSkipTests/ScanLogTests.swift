import XCTest
@testable import TMSkip

/// ScanLogService 的 JSONL 事件格式与轮转回归测试（临时目录注入，不落真实
/// Application Support）。
@MainActor
final class ScanLogTests: XCTestCase {
    private var directory: URL!
    private var logURL: URL { directory.appendingPathComponent("scan-log.jsonl") }
    private let decoder = JSONDecoder()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanlog-tests-\(UUID().uuidString)", isDirectory: true)
        decoder.dateDecodingStrategy = .iso8601
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines() throws -> [ScanLogService.Entry] {
        let data = try Data(contentsOf: logURL)
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(ScanLogService.Entry.self, from: Data(line))
        }
    }

    // MARK: - 事件格式

    func testBeginFinishWritesStartedThenFinishedWithSameScanId() throws {
        let service = ScanLogService(directory: directory)
        let scanId = service.begin(kind: .manual, trigger: .userInitiated)
        service.finish(scanId: scanId, foundCount: 3, alreadyExcludedCount: 2, pendingCount: 1)

        let entries = try lines()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].event, .scanStarted)
        XCTAssertEqual(entries[0].kind, .manual)
        XCTAssertEqual(entries[0].trigger, .userInitiated)
        XCTAssertEqual(entries[0].scanId, scanId)
        XCTAssertFalse(entries[0].appVersion.isEmpty)

        XCTAssertEqual(entries[1].event, .scanFinished)
        XCTAssertEqual(entries[1].scanId, scanId)
        XCTAssertEqual(entries[1].foundCount, 3)
        XCTAssertEqual(entries[1].alreadyExcludedCount, 2)
        XCTAssertEqual(entries[1].pendingCount, 1)
        XCTAssertNotNil(entries[1].durationMs, "finished 应推算出耗时")
    }

    func testAutoScanTriggerIsRecorded() throws {
        let service = ScanLogService(directory: directory)
        let scanId = service.begin(kind: .auto, trigger: .interval)
        service.finish(scanId: scanId, foundCount: 0, alreadyExcludedCount: 0, pendingCount: 0)

        let entries = try lines()
        XCTAssertEqual(entries[0].kind, .auto)
        XCTAssertEqual(entries[0].trigger, .interval)
        // 0 结果也必须产生 finished 记录（扫描发生过）。
        XCTAssertEqual(entries.count, 2)
    }

    func testCancelWritesCancelledAndDropsDuration() throws {
        let service = ScanLogService(directory: directory)
        let scanId = service.begin(kind: .manual, trigger: .userInitiated)
        service.cancel(scanId: scanId, reason: "userCancel")

        let entries = try lines()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].event, .scanCancelled)
        XCTAssertEqual(entries[1].reason, "userCancel")
        XCTAssertNil(entries[1].durationMs)
    }

    func testApplyFinishedRecordsOutcome() throws {
        let service = ScanLogService(directory: directory)
        let scanId = service.begin(kind: .auto, trigger: .fsEvents)
        service.logApply(
            scanId: scanId,
            source: .autoScan,
            appliedCount: 2,
            failedCount: 1,
            permissionBlocked: true,
            appBundleBlockedCount: 3
        )

        let entries = try lines()
        let apply = entries[1]
        XCTAssertEqual(apply.event, .applyFinished)
        XCTAssertEqual(apply.source, .autoScan)
        XCTAssertEqual(apply.appliedCount, 2)
        XCTAssertEqual(apply.failedCount, 1)
        XCTAssertEqual(apply.permissionBlocked, true)
        XCTAssertEqual(apply.appBundleBlockedCount, 3)
        XCTAssertEqual(apply.scanId, scanId)
    }

    // MARK: - 轮转

    func testRotationKeepsAtMostFiveFiles() throws {
        // 每条记录 ~200 字节，maxBytes=100 时每次写入都会轮转，正好压测轮转。
        let service = ScanLogService(directory: directory, maxBytes: 100)
        for i in 0..<12 {
            let scanId = service.begin(kind: .manual, trigger: .userInitiated)
            service.finish(scanId: scanId, foundCount: i, alreadyExcludedCount: 0, pendingCount: 0)
        }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: logURL.path), "当前文件必须存在")
        XCTAssertTrue(
            fm.fileExists(atPath: directory.appendingPathComponent("scan-log.1.jsonl").path),
            "轮转后应产生 scan-log.1.jsonl"
        )
        let kept = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("scan-log.") && $0.hasSuffix(".jsonl") }
        XCTAssertLessThanOrEqual(kept.count, ScanLogService.maxKeptFiles, "轮转文件总数不得超过 5 份")
    }
}
