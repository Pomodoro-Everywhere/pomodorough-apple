import Foundation

/// Applies only to real platform effects. Injected test backends still run normally.
enum TestAudioSuppression {
    static var silenceKey: String { "POMODOROUGH_SILENCE_AUDIO" }

    static var isEnabled: Bool {
        isEnabled(
            environment: ProcessInfo.processInfo.environment,
            hasXCTest: NSClassFromString("XCTestCase") != nil
        )
    }

    static func isEnabled(environment: [String: String], hasXCTest: Bool) -> Bool {
        hasXCTest || environment["XCTestConfigurationFilePath"] != nil
            || environment[silenceKey] == "1"
    }

    static func silenced(_ base: [String: String]) -> [String: String] {
        var merged = base
        merged[silenceKey] = "1"
        return merged
    }
}
