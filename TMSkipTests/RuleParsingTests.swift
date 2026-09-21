import XCTest
@testable import TMSkip

final class RuleParsingTests: XCTestCase {
    private static let sampleTSV = """
    # dir\tsentinel\tecosystem\tnote
    node_modules\tpackage.json\tjavascript\tnpm, Yarn
    target\tCargo.toml\trust\tCargo
    # comment lines are ignored
    vendor\tcomposer.json\tphp\tComposer
    node_modules\tpackage.json\tjavascript\tduplicate
    only-one-token
    """

    func testParsesPairsDeduplicatesAndGroups() throws {
        let rules = try RulePackageService.parseSentinelsTSV(Self.sampleTSV)

        XCTAssertEqual(rules.count, 3, "重复对与无效 token 应被去重/丢弃")

        let npm = try XCTUnwrap(rules.first { $0.excludes == ["node_modules"] })
        XCTAssertEqual(npm.ifExists, ["package.json"])
        XCTAssertEqual(npm.group, "Node.js")
        XCTAssertTrue(npm.isEnabled)

        let cargo = try XCTUnwrap(rules.first { $0.excludes == ["target"] })
        XCTAssertEqual(cargo.ifExists, ["Cargo.toml"])
        XCTAssertEqual(cargo.group, "Rust")

        let composer = try XCTUnwrap(rules.first { $0.excludes == ["vendor"] })
        XCTAssertEqual(composer.group, "PHP")
    }

    func testGroupMappingMatchesBundledSnapshot() throws {
        // Every enabled-flag decision of the remote parser must agree with the
        // bundled snapshot's per-rule flags for the same pair.
        let remote = try RulePackageService.parseSentinelsTSV(Self.sampleTSV)
        let bundled = RulePackage.bundledSnapshot.rules
        for rule in remote {
            let bundledMatch = bundled.first { $0.excludes == rule.excludes && $0.ifExists == rule.ifExists }
            XCTAssertNotNil(bundledMatch, "远程规则 \(rule.id) 应存在于内置快照中")
            if let b = bundledMatch {
                XCTAssertEqual(b.group, rule.group, "分组应一致: \(rule.id)")
                XCTAssertEqual(b.isEnabled, rule.isEnabled, "默认启用状态应一致: \(rule.id)")
            }
        }
    }

    func testGlobSentinelsParseVerbatim() throws {
        let tsv = """
        bin\t*.csproj\tdotnet\tC# build output
        DerivedData\t*.xcodeproj\tswift\tXcode DerivedData
        """
        let rules = try RulePackageService.parseSentinelsTSV(tsv)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.first { $0.excludes == ["bin"] }?.ifExists, ["*.csproj"], "glob 哨兵必须原样保留，不得转义")
        XCTAssertEqual(rules.first { $0.excludes == ["DerivedData"] }?.group, "Apple")
    }

    func testRuleIDsAreStableAndUnique() throws {
        let rules = try RulePackageService.parseSentinelsTSV(Self.sampleTSV)
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count)
        XCTAssertTrue(rules.allSatisfy { $0.id.hasPrefix("asimov-") })
    }

    func testDotAndUnderscoreDirsDoNotCollide() throws {
        // `.build` and `_build` must keep distinct ids (upstream has both rows).
        let tsv = """
        _build\tmix.exs\telixir\tMix build output
        .build\tmix.exs\telixir\tMix build files
        """
        let rules = try RulePackageService.parseSentinelsTSV(tsv)
        XCTAssertEqual(rules.count, 2, "`.build` 与 `_build` 不得因 id 归一化而撞车")
        XCTAssertEqual(Set(rules.map(\.id)).count, 2)
        XCTAssertNotEqual(rules[0].id, rules[1].id)
    }

    func testMissingSentinelRowsThrows() {
        XCTAssertThrowsError(try RulePackageService.parseSentinelsTSV("#!/bin/bash\necho hi\n"))
    }

    func testEmptyDataThrows() {
        let tsv = """
        # nothing here
        """
        XCTAssertThrowsError(try RulePackageService.parseSentinelsTSV(tsv))
    }

    func testVersionStampOmitsDateAndReflectsContent() {
        let rules = [
            RuleDefinition(id: "npm", name: "npm", excludes: ["node_modules"], ifExists: ["package.json"], group: "Node.js", isEnabled: true),
        ]
        let launcher = "readonly ASIMOV_VERSION='0.12.0'\n"
        let stamp = RulePackageService.versionStamp(for: rules, scriptHeader: launcher)
        XCTAssertTrue(stamp.hasPrefix("asimov-0.12.0-1r-"), "应为 asimov-<上游版本>-<条数>r-<摘要>: \(stamp)")
        XCTAssertFalse(stamp.contains("-2026-") || stamp.contains("-2027-"), "版本戳不应包含日期")

        // The old `@version` header format is still supported for compatibility.
        let legacy = RulePackageService.versionStamp(for: rules, scriptHeader: "# @version 1.2.3\n")
        XCTAssertTrue(legacy.hasPrefix("asimov-1.2.3-1r-"))

        let headerless = RulePackageService.versionStamp(for: rules, scriptHeader: "# no version\n")
        XCTAssertTrue(headerless.hasPrefix("asimov-remote-1r-"))

        var changed = rules
        changed[0].ifExists = ["bower.json"]
        let digest = String(stamp.suffix(8))
        let changedDigest = String(RulePackageService.versionStamp(for: changed, scriptHeader: launcher).suffix(8))
        XCTAssertNotEqual(digest, changedDigest, "规则内容变化必须反映在版本戳中")
    }
}
