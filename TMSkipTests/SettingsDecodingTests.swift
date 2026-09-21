import XCTest
@testable import TMSkip

/// Regression for PLAN-AutoScan PR1: adding a field to AppSettings must never
/// wipe an existing user's stored configuration (synthesized Codable would
/// throw KeyNotFound and silently reset everything to defaults).
final class SettingsDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testJSONMissingNewFieldsKeepsKnownValuesAndUsesDefaults() throws {
        // Simulates a v0.1.0 blob written before lastAutoScanAt/autoRuleSync.
        let oldJSON = """
        {
          "autoScanEnabled": false,
          "skipPaths": ["~/work"],
          "notificationsEnabled": false
        }
        """.data(using: .utf8)!

        let settings = try decoder.decode(AppSettings.self, from: oldJSON)

        // Known values survive.
        XCTAssertFalse(settings.autoScanEnabled)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(settings.skipPaths, ["~/work"])
        // Missing fields fall back to defaults instead of throwing.
        XCTAssertEqual(settings.scanInterval, .minutes30)
        XCTAssertEqual(settings.triggerMode, .intervalAndFSEvents)
        XCTAssertEqual(settings.applyPolicy, .notifyConfirm)
        XCTAssertTrue(settings.autoRuleSync, "新字段缺省时应为默认 true")
        XCTAssertNil(settings.lastAutoScanAt)
        // Missing rule package falls back to the non-empty bundled snapshot.
        XCTAssertFalse(settings.rulePackage.rules.isEmpty)
        XCTAssertFalse(settings.roots.isEmpty)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try decoder.decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.autoScanEnabled)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.noReinclude)
        XCTAssertTrue(settings.autoRuleSync)
        XCTAssertFalse(settings.rulePackage.rules.isEmpty)
        XCTAssertEqual(settings.skipPaths, AppSettings.defaultSkipPaths)
    }

    func testCorruptSingleFieldDoesNotWipeWholeConfig() throws {
        // An enum raw value this build doesn't know → that field defaults,
        // everything else survives.
        let json = """
        {
          "autoScanEnabled": false,
          "scanInterval": "bogus-value"
        }
        """.data(using: .utf8)!

        let settings = try decoder.decode(AppSettings.self, from: json)
        XCTAssertFalse(settings.autoScanEnabled)
        XCTAssertEqual(settings.scanInterval, .minutes30)
    }

    func testRoundTripPreservesNewFields() throws {
        var settings = AppSettings()
        settings.autoScanEnabled = false
        settings.autoRuleSync = false
        settings.lastAutoScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        settings.scanInterval = .hours6

        let data = try encoder.encode(settings)
        let decoded = try decoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.autoRuleSync)
        XCTAssertEqual(decoded.scanInterval, .hours6)
        XCTAssertEqual(decoded.lastAutoScanAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
