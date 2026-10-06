import Foundation
import Sentry

// DSN is a build-time Info.plist value: Supporting/*-Info.plist declares
// SENTRY_DSN as $(SENTRY_DSN), expanded by xcodebuild from the environment.
// Supporting/SentryDSN.local is never bundled: local install scripts and the
// release workflow read that file (when present) and export SENTRY_DSN for
// xcodebuild, so clean checkouts with no file build with an empty DSN and
// Sentry stays disabled. This keeps the secret out of committed source and
// decouples the build from the file's presence.
enum SentrySetup {
    static func startIfConfigured() {
        let dsn = (Bundle.main.infoDictionary?["SENTRY_DSN"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // R43-AP09: wrapper suppression alone cannot stop automatic SDK
        // paths (crash, watchdog, hang, breadcrumb, session, replay) once
        // start runs, so simulator and test processes never start.
        guard shouldStart(dsn: dsn, isSimulator: SentryCapture.isSimulatorBuild, isTestProcess: SentryCapture.isTestProcess) else { return }
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
            return environment(isDebug: true, isTestFlight: false)
        #else
            return environment(isDebug: false, isTestFlight: isTestFlightBuild)
        #endif
    }

    // Internal so SentryCaptureTests pins the gate without starting the SDK.
    static func shouldStart(dsn: String, isSimulator: Bool, isTestProcess: Bool) -> Bool {
        guard !dsn.isEmpty else { return false }
        return !SentryCapture.shouldSuppressForEnvironment(isSimulator: isSimulator, isTestProcess: isTestProcess)
    }

    // Internal so SentryCaptureTests pins TestFlight classification.
    // TestFlight builds are Release, so without this check they merged
    // into production despite the earlier backlog claim.
    static func environment(isDebug: Bool, isTestFlight: Bool) -> String {
        if isDebug { return "development" }
        if isTestFlight { return "testflight" }
        return "production"
    }

    static var isTestFlightBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
}
