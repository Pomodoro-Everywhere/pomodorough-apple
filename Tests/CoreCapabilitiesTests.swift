import Foundation
import Testing
@testable import Pomodorough

/// Core version gate for task rename: numeric semver at or above 0.54.0.
@Suite("Core capabilities version gate")
struct CoreCapabilitiesTests {
    @Test(arguments: [
        ("0.53.0", false),
        ("0.53.99", false),
        ("0.54.0", true),
        ("0.54.1", true),
        ("0.55.0", true),
        ("1.0.0", true),
        ("0.54.0-rc.1", true),
        ("0.54.0+build.7", true),
    ])
    func taskRenameGate(version: String, expected: Bool) {
        #expect(CoreCapabilities(coreVersionText: version).supportsTaskRename == expected)
    }

    @Test(arguments: ["", "0.54", "0.54.0.1", "v0.54.0", "0.54.x", "54", "0..54", "0.-54.0", " 0.54.0"])
    func malformedVersionsDenyRename(version: String) {
        #expect(CoreSemanticVersion(parsing: version) == nil)
        #expect(!CoreCapabilities(coreVersionText: version).supportsTaskRename)
    }

    @Test func missingVersionDeniesRename() {
        #expect(!CoreCapabilities(coreVersionText: nil).supportsTaskRename)
        #expect(!CoreCapabilities(coreVersion: nil).supportsTaskRename)
    }

    @Test func comparisonIsNumericNotLexical() throws {
        let nine = try #require(CoreSemanticVersion(parsing: "0.9.0"))
        let fiftyFour = try #require(CoreSemanticVersion(parsing: "0.54.0"))
        let ten = try #require(CoreSemanticVersion(parsing: "0.10.0"))
        #expect(nine < ten)
        #expect(ten < fiftyFour)
        #expect(CoreSemanticVersion(major: 1, minor: 0, patch: 0) > fiftyFour)
    }

    @Test func probeFailureDeniesRename() {
        struct Unavailable: Error {}
        let capabilities = CoreCapabilities.probe { throw Unavailable() }
        #expect(capabilities.coreVersion == nil)
        #expect(!capabilities.supportsTaskRename)
    }

    /// The bundled core tracks the latest release resolved at build time, so
    /// the gate is checked against the version Core reports, never pinned.
    @Test func bundledCoreGateMatchesReportedVersion() throws {
        struct Report: Decodable { let coreVersion: String }
        let core = try SharedCore.bundled()
        let report = try core.dispatch("core.version", inputJSON: Data("{}".utf8), as: Report.self)
        let parsed = try #require(CoreSemanticVersion(parsing: report.coreVersion))
        let probed = CoreCapabilities.probe { core }
        #expect(probed.coreVersion == parsed)
        #expect(probed.supportsTaskRename == (parsed >= CoreCapabilities.taskRenameMinimum))
    }
}
