import XCTest
@testable import TMSkip

final class ExclusionServiceTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmskip-excl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testExclusionRoundTrip() throws {
        let dir = workDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertEqual(TimeMachineExclusionService.isExcluded(at: dir.path), false, "新建目录默认未被排除")

        try TimeMachineExclusionService.setExcluded(true, at: dir.path)
        XCTAssertEqual(TimeMachineExclusionService.isExcluded(at: dir.path), true)

        try TimeMachineExclusionService.setExcluded(false, at: dir.path)
        XCTAssertEqual(TimeMachineExclusionService.isExcluded(at: dir.path), false)
    }

    func testTildePathsAreExpanded() throws {
        XCTAssertEqual(
            TimeMachineExclusionService.expand("~/x"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("x").path
        )
    }

    func testExistingUnexcludedPathIsQueryable() throws {
        // A missing path may return either false or nil depending on OS
        // behavior; an existing unexcluded directory must report false.
        let dir = workDir.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(TimeMachineExclusionService.isExcluded(at: dir.path), false)
    }

    @MainActor
    func testPathTouchesAppBundle() {
        XCTAssertTrue(AppModel.pathTouchesAppBundle("/Applications/Foo.app/Contents/Resources/node_modules"))
        XCTAssertTrue(AppModel.pathTouchesAppBundle("~/tools/Foo.APP/build"), "大小写不敏感")
        XCTAssertTrue(AppModel.pathTouchesAppBundle("~/Downloads/Something.app"), "路径本身是 .app 包")
        XCTAssertFalse(AppModel.pathTouchesAppBundle("~/dev/node_modules"))
        XCTAssertFalse(AppModel.pathTouchesAppBundle("~/dev/apps"))
    }

    @MainActor
    func testUnignorePlanDropsStaleRecordWithoutWriting() {
        func record(_ path: String, status: IgnoreStatus) -> IgnoreRecord {
            IgnoreRecord(
                path: path,
                source: .manualScan,
                status: status,
                ruleName: nil,
                byteSize: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastVerifiedAt: nil,
                isSelected: true
            )
        }
        let stale = record("~/dev/gone/node_modules", status: .missing)
        let present = record("~/dev/here/node_modules", status: .excluded)
        let inBundle = record("~/tools/Foo.app/Contents/Resources/node_modules", status: .excluded)

        var cleared: [String] = []
        let outcome = AppModel.planUnignore(
            of: [stale, present, inBundle],
            fileExists: { $0.hasSuffix("/here/node_modules") },
            setExcluded: { _, path in cleared.append(path) }
        )

        XCTAssertEqual(outcome.staleIDs, [stale.id], "路径不存在时应直接清理记录")
        XCTAssertEqual(outcome.clearedIDs, [present.id])
        // setExcluded on a missing path throws; it must never be attempted.
        XCTAssertEqual(cleared, [TimeMachineExclusionService.expand(present.path)])
        XCTAssertEqual(outcome.bundleBlockedIDs, [inBundle.id])
        XCTAssertTrue(outcome.failedPaths.isEmpty)
    }

    @MainActor
    func testUnignorePlanSurfacesFailures() {
        let rec = IgnoreRecord(
            path: "~/dev/node_modules",
            source: .manualScan,
            status: .excluded,
            ruleName: nil,
            byteSize: nil,
            createdAt: Date(),
            updatedAt: Date(),
            lastVerifiedAt: nil,
            isSelected: true
        )
        let outcome = AppModel.planUnignore(
            of: [rec],
            fileExists: { _ in true },
            setExcluded: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
            }
        )

        XCTAssertTrue(outcome.clearedIDs.isEmpty)
        XCTAssertEqual(outcome.failedPaths, [rec.path], "撤销失败不能被静默吞掉")
    }

    // MARK: - Re-ignore (planReignore)

    @MainActor
    func testReignorePlanOnlyAppliesAnomalyRecords() {
        func record(_ path: String, status: IgnoreStatus) -> IgnoreRecord {
            IgnoreRecord(
                path: path,
                source: .manualScan,
                status: status,
                ruleName: nil,
                byteSize: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastVerifiedAt: nil,
                isSelected: true
            )
        }
        let anomaly = record("~/dev/node_modules", status: .anomaly)
        let healthy = record("~/dev/ok/node_modules", status: .excluded)
        let inBundle = record("~/tools/Foo.app/Contents/Resources/node_modules", status: .anomaly)
        let stale = record("~/dev/gone/node_modules", status: .anomaly)

        var written: [String] = []
        let outcome = AppModel.planReignore(
            of: [anomaly, healthy, inBundle, stale],
            fileExists: { $0.hasSuffix("/dev/node_modules") || $0.hasSuffix("/ok/node_modules") },
            setExcluded: { _, path in written.append(path) }
        )

        XCTAssertEqual(outcome.reappliedIDs, [anomaly.id], "仅状态异常且存在的路径被重新排除")
        XCTAssertEqual(outcome.bundleBlockedIDs, [inBundle.id])
        XCTAssertEqual(written, [TimeMachineExclusionService.expand(anomaly.path)], "已忽略项与缺失路径不得触发写入")
        XCTAssertTrue(outcome.failedPaths.isEmpty)
    }

    @MainActor
    func testReignorePlanSurfacesFailures() {
        let rec = IgnoreRecord(
            path: "~/dev/node_modules",
            source: .manualScan,
            status: .anomaly,
            ruleName: nil,
            byteSize: nil,
            createdAt: Date(),
            updatedAt: Date(),
            lastVerifiedAt: nil,
            isSelected: true
        )
        let outcome = AppModel.planReignore(
            of: [rec],
            fileExists: { _ in true },
            setExcluded: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
        )

        XCTAssertTrue(outcome.reappliedIDs.isEmpty)
        XCTAssertEqual(outcome.failedPaths, [rec.path], "排除失败不能被静默吞掉")
    }
}
