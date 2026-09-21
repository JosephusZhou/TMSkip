import XCTest
@testable import TMSkip

final class SettingsTests: XCTestCase {
    func testNormalizeSkipPathRepairsUnmatchableInput() {
        XCTAssertEqual(AppSettings.normalizeSkipPath("  ~/code///  "), "~/code")
        XCTAssertEqual(AppSettings.normalizeSkipPath("\u{FF5E}/x"), "~/x", "全角波浪号必须归一化为半角")
        XCTAssertEqual(AppSettings.normalizeSkipPath("/tmp/a/"), "/tmp/a")
        XCTAssertEqual(AppSettings.normalizeSkipPath("/"), "/")
        XCTAssertEqual(AppSettings.normalizeSkipPath("~"), "~")
        XCTAssertEqual(AppSettings.normalizeSkipPath("   "), "")
    }

    func testAbbreviateHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppSettings.abbreviateHome(home + "/Movies"), "~/Movies")
        XCTAssertEqual(AppSettings.abbreviateHome(home), "~")
        XCTAssertEqual(AppSettings.abbreviateHome("~/already"), "~/already")
        XCTAssertEqual(AppSettings.abbreviateHome("/usr/local"), "/usr/local")
    }

    func testDefaultSkipPathsCoverSensitiveTrees() {
        let defaults = AppSettings.defaultSkipPaths
        XCTAssertTrue(defaults.contains("~/Library"))
        XCTAssertTrue(defaults.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(defaults).count, defaults.count, "默认跳过路径不应重复")
    }

    func testBundledSnapshotIsWellFormed() {
        let pkg = RulePackage.bundledSnapshot
        XCTAssertFalse(pkg.rules.isEmpty)
        XCTAssertEqual(Set(pkg.rules.map(\.id)).count, pkg.rules.count, "规则 id 必须唯一")
        XCTAssertTrue(pkg.rules.allSatisfy { !$0.excludes.isEmpty && !$0.ifExists.isEmpty })
        XCTAssertTrue(pkg.rules.contains { $0.excludes == ["node_modules"] }, "必须包含 node_modules 规则")
    }

    func testMergingPreservesUserToggles() {
        let previous = RulePackage.bundledSnapshot
        // User disabled npm, enabled bower.
        var withToggles = previous
        withToggles.rules[withToggles.rules.firstIndex(where: { $0.id == "npm" })!].isEnabled = false
        withToggles.rules[withToggles.rules.firstIndex(where: { $0.id == "bower" })!].isEnabled = true

        var incoming = previous
        incoming.version = "next"
        let merged = incoming.mergingEnabledStates(from: withToggles)

        XCTAssertFalse(merged.rules.first { $0.id == "npm" }!.isEnabled)
        XCTAssertTrue(merged.rules.first { $0.id == "bower" }!.isEnabled)
        XCTAssertEqual(merged.version, "next")

        let fresh = incoming.mergingEnabledStates(from: nil)
        XCTAssertEqual(fresh, incoming, "无历史时应原样保留")
    }
}
