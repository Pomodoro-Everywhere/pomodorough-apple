import Foundation
import SwiftUI

/// Numeric semantic version of the bundled Rust core (`MAJOR.MINOR.PATCH`).
/// Pre-release and build suffixes are ignored; anything else is malformed.
struct CoreSemanticVersion: Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(parsing text: String) {
        let core = text.split(maxSplits: 1, whereSeparator: { $0 == "-" || $0 == "+" })
        guard let numeric = core.first else { return nil }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Feature gates derived from the bundled core release. Core answers
/// `core.version` once per process; a core that cannot report a parseable
/// version supports nothing optional.
struct CoreCapabilities: Equatable, Sendable {
    static let taskRenameMinimum = CoreSemanticVersion(major: 0, minor: 54, patch: 0)

    let coreVersion: CoreSemanticVersion?

    init(coreVersion: CoreSemanticVersion?) {
        self.coreVersion = coreVersion
    }

    init(coreVersionText: String?) {
        self.init(coreVersion: coreVersionText.flatMap(CoreSemanticVersion.init(parsing:)))
    }

    /// `workspace.intent.v1` admits `renameTask` from core 0.54.0.
    var supportsTaskRename: Bool {
        guard let coreVersion else { return false }
        return coreVersion >= Self.taskRenameMinimum
    }

    static let bundled: CoreCapabilities = probe { try SharedCore.bundled() }

    static func probe(_ sharedCoreProvider: () throws -> SharedCore) -> CoreCapabilities {
        do {
            let core = try sharedCoreProvider()
            let version = try core.dispatch("core.version", inputJSON: Data("{}".utf8), as: Report.self)
            return CoreCapabilities(coreVersionText: version.coreVersion)
        } catch {
            return CoreCapabilities(coreVersion: nil)
        }
    }

    private struct Report: Decodable, Sendable {
        let coreVersion: String
    }
}

extension EnvironmentValues {
    @Entry var coreCapabilities: CoreCapabilities = .bundled
}
