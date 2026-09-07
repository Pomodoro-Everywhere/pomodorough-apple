import Foundation
import Sentry

// Reads the DSN from the built Info.plist so the
// secret stays a build-time value and never lands in committed source.
enum SentrySetup {
    static func startIfConfigured() {
        var dsn = (Bundle.main.infoDictionary?["SENTRY_DSN"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if dsn.isEmpty,
           let url = Bundle.main.url(forResource: "SentryDSN", withExtension: "local"),
           let file = try? String(contentsOf: url, encoding: .utf8) {
            dsn = file.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = sentryEnvironment()
            #if os(iOS) || os(tvOS)
                applySessionReplay(options)
            #endif
            let info = Bundle.main.infoDictionary
            if let version = info?["CFBundleShortVersionString"] as? String,
               let build = info?["CFBundleVersion"] as? String
            {
                options.releaseName = "\(version)@\(build)"
            }
        }
    }

    // Privacy-sane replay defaults: masks stay on so timer text, task
    // titles, and account screens record as opaque boxes. Error replays
    // always attach; full-session replays stay sampled.
    #if os(iOS) || os(tvOS)
        private static func applySessionReplay(_ options: Options) {
            options.sessionReplay.sessionSampleRate = 0.1
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = true
            options.sessionReplay.maskAllImages = true
        }
    #endif

    private static func sentryEnvironment() -> String {
        #if DEBUG
            return "development"
        #else
            return "production"
        #endif
    }
}
