import XCTest
@testable import TMSkip

final class ScanEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmskip-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, content: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan(skipPaths: [String] = []) -> [ScanEngine.Hit] {
        let engine = ScanEngine()
        let config = ScanEngine.Configuration(
            roots: [root.path],
            skipPaths: skipPaths,
            rules: RulePackage.bundledSnapshot.rules
        )
        return engine.scan(config: config, progress: { _ in }, isCancelled: { false })
    }

    func testFindsRuleMatchesWithSentinel() throws {
        try write("projectA/package.json")
        try write("projectA/node_modules/lib/index.js")
        try write("projectB/Cargo.toml")
        try write("projectB/target/debug/binary")

        let hits = scan()
        XCTAssertEqual(hits.map(\.path).sorted(), [
            root.appendingPathComponent("projectA/node_modules").path,
            root.appendingPathComponent("projectB/target").path,
        ])
        XCTAssertTrue(hits.contains { $0.ruleName.contains("npm") && $0.path.hasSuffix("node_modules") })
        XCTAssertTrue(hits.contains { $0.ruleName.contains("Cargo") && $0.path.hasSuffix("target") })
    }

    func testNoSentinelMeansNoHit() throws {
        // node_modules without package.json must not match (if-exists rule).
        try write("orphan/node_modules/lib/index.js")
        let hits = scan()
        XCTAssertTrue(hits.isEmpty)
    }

    func testGlobSentinelMatchesSiblingFile() throws {
        // Upstream Asimov uses `*.csproj` as a glob sentinel (dotnet bin/obj).
        try write("dotnet/MyApp.csproj")
        try write("dotnet/bin/Debug/net8.0/app.dll")
        try write("dotnet/obj/Debug/net8.0/app.dll")

        let hits = scan()
        XCTAssertEqual(Set(hits.map(\.path)), [
            root.appendingPathComponent("dotnet/bin").path,
            root.appendingPathComponent("dotnet/obj").path,
        ])
    }

    func testGlobSentinelRequiresSibling() throws {
        // A plain `bin` directory without a *.csproj sibling must not match.
        try write("plain/bin/tool")
        let hits = scan()
        XCTAssertTrue(hits.isEmpty)
    }

    func testXcodeDerivedDataMatchesXcodeprojSibling() throws {
        try write("App.xcodeproj/project.pbxproj")
        try write("DerivedData/Build/Products/App.app/Contents/MacOS/App")

        let hits = scan()
        XCTAssertTrue(hits.contains { $0.path.hasSuffix("DerivedData") && $0.ruleName.contains("DerivedData") })
    }

    func testGlobMatchHelper() {
        XCTAssertTrue(ScanEngine.globMatch("*.csproj", "MyApp.csproj"))
        XCTAssertTrue(ScanEngine.globMatch("*.csproj", "a.csproj"))
        XCTAssertFalse(ScanEngine.globMatch("*.csproj", "MyApp.xcodeproj"))
        XCTAssertTrue(ScanEngine.globMatch("*.xcodeproj", "App.xcodeproj"))
        XCTAssertTrue(ScanEngine.globMatch("a?c", "abc"))
        XCTAssertFalse(ScanEngine.globMatch("a?c", "ac"))
        XCTAssertTrue(ScanEngine.globMatch("a*c", "ac"))
        XCTAssertTrue(ScanEngine.globMatch("a*c", "a123c"))
        XCTAssertFalse(ScanEngine.globMatch("a*c", "a123b"))
        XCTAssertTrue(ScanEngine.globMatch("*", "anything"))
        XCTAssertFalse(ScanEngine.globMatch("*.csproj", "csproj"))
    }

    func testSkipPathsAreNotScanned() throws {
        try write("kept/package.json")
        try write("kept/node_modules/lib/index.js")
        try write("skipped/package.json")
        try write("skipped/node_modules/lib/index.js")

        let hits = scan(skipPaths: [root.appendingPathComponent("skipped").path])
        XCTAssertEqual(hits.map(\.path), [root.appendingPathComponent("kept/node_modules").path])
    }

    func testAppBundleContentsAreNeverEntered() throws {
        try write("SomeApp.app/Contents/MacOS/SomeApp")
        try write("SomeApp.app/Contents/Resources/package.json")
        try write("SomeApp.app/Contents/Resources/node_modules/lib/index.js")

        let hits = scan()
        XCTAssertTrue(hits.isEmpty, "不得报告或进入其他应用的 .app 包")
    }

    func testDotGitIsNotEntered() throws {
        try write("repo/.git/package.json")
        try write("repo/.git/node_modules/lib/index.js")

        let hits = scan()
        XCTAssertTrue(hits.isEmpty)
    }

    func testIsAppBundleNameIsCaseInsensitive() {
        XCTAssertTrue(ScanEngine.isAppBundleName("Foo.app"))
        XCTAssertTrue(ScanEngine.isAppBundleName("Foo.APP"))
        XCTAssertFalse(ScanEngine.isAppBundleName("appendix"))
        XCTAssertFalse(ScanEngine.isAppBundleName("node_modules"))
    }

    func testTraversableDirectoryDoesNotFollowSymlinks() throws {
        let target = root.appendingPathComponent("real-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(ScanEngine.isTraversableDirectory(target.path))
        XCTAssertFalse(ScanEngine.isTraversableDirectory(link.path), "符号链接不得跟随（防环，PRD 6.5）")
        XCTAssertFalse(ScanEngine.isTraversableDirectory(root.appendingPathComponent("missing").path))
    }
}
