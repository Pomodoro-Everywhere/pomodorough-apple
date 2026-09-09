import Foundation
import Testing

/// AP48/AP46: watch alert strings stay localized and commandError clears on
/// success. Runs in the macOS/iOS bundle without a watchOS test host.
struct WatchAlertContractTests {
    static let alertKeys = [
        "iPhone connection is not ready. Try again shortly.",
        "Connect to your iPhone to start a timer. Start was not queued.",
        "Could not confirm Start. Check your iPhone before trying again. Start was not queued.",
        "This timer changed on your iPhone. Refreshing status.",
    ]

    @Test
    func alertStringsUseLocalizedAPI() throws {
        let source = try watchSource()
        for key in Self.alertKeys {
            #expect(source.contains("String(localized: \"\(key)\")"), "missing localized: \(key)")
        }
        #expect(!source.contains("commandError = \""), "raw commandError literal")
    }

    @Test
    func commandErrorClearedOnSuccessAndIngest() throws {
        let source = try watchSource()
        let clears = source.components(separatedBy: "commandError = nil").count - 1
        #expect(clears >= 3, "clear on live send, queued delivery, and ingest")
    }

    @Test
    func alertKeysInShippingCatalogAndPseudoFixture() throws {
        let root = repoRoot()
        let catalog = try loadJSON(root.appending(path: "Resources/Localizable.xcstrings"))
        let pseudo = try loadJSON(root.appending(path: "UITests/Fixtures/Localizable.ar-XB.json"))
        let shipping = try #require(catalog["strings"] as? [String: Any])
        let fixture = try #require(pseudo["strings"] as? [String: Any])
        for key in Self.alertKeys {
            let entry = try #require(shipping[key] as? [String: Any], "shipping: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])
            #expect(!stringUnits(english).joined().isEmpty, "empty en: \(key)")
            let pseudoEntry = try #require(fixture[key] as? [String: Any], "pseudo: \(key)")
            let values = stringUnits(pseudoEntry)
            #expect(!values.isEmpty, "missing pseudo: \(key)")
            for value in values {
                #expect(value.hasPrefix("\u{200F}⟦") && value.hasSuffix("⟧"), "decoration: \(key)")
            }
        }
    }

    private func repoRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func watchSource() throws -> String {
        try String(contentsOf: repoRoot().appending(path: "Watch/WatchSyncService.swift"), encoding: .utf8)
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try #require(decoded as? [String: Any])
    }

    private func stringUnits(_ node: Any) -> [String] {
        guard let dict = node as? [String: Any] else { return [] }
        var values: [String] = []
        if let unit = dict["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            values.append(value)
        }
        for key in ["variations", "substitutions"] {
            guard let child = dict[key] as? [String: Any] else { continue }
            for value in child.values {
                if let nested = value as? [String: Any] {
                    for leaf in nested.values { values += stringUnits(leaf) }
                }
            }
        }
        return values
    }
}
