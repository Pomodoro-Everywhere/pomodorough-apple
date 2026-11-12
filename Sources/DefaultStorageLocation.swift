import Foundation

// The test host is a DEBUG-only product: in Release the test-process seam
// below is compiled out, so a Release host would use the real profile.
#if POMODOROUGH_MAC_TEST_HOST && !DEBUG
#error("PomodoroughMacTestHost builds only in Debug; a Release host would use the real profile.")
#endif

/// Single source of the app's default storage: the defaults domain and the
/// folder that holds `timer-state-v2.json`, `account-deletion-v1.json` and
/// `iroh-rooms-v1.json`. Every store default reads it, so one decision covers
/// them all.
///
/// Release builds always get the real profile: `UserDefaults.standard` and
/// `Application Support/Pomodorough`. A DEBUG test process (the signal of
/// `KeychainTestProcessGuard`) gets the test defaults suite and a temporary
/// folder instead, both cleared when the process starts. Hosted unit tests
/// run `PomodoroughApp.init()` in a host app, so without this the host app
/// would read and write the developer's real profile before XCTest loads the
/// test bundle.
/// The location is chosen on first use, which is before any store reads or
/// writes. If a test process cannot get its location it stops; it never
/// falls back to the real profile.
enum DefaultStorageLocation {
    struct Resolved: @unchecked Sendable {
        /// The defaults every store uses unless a caller injects its own.
        let defaults: UserDefaults
        /// The suite of `defaults`, or nil for the standard domain.
        let suiteName: String?
        /// The folder of the default file stores.
        let directory: URL
    }

    static let current: Resolved = resolve()

    static var defaults: UserDefaults { current.defaults }

    static func fileURL(_ name: String) -> URL {
        current.directory.appendingPathComponent(name)
    }

    /// The App Group defaults the widget reads. A test process keeps its
    /// writes in its own suite instead.
    static func sharedDefaults(appGroup: String) -> UserDefaults? {
        current.suiteName == nil ? UserDefaults(suiteName: appGroup) : current.defaults
    }

    /// Clears the defaults domain of `location` (DEBUG UI-test reset).
    static func removeDefaults(of location: Resolved = current) {
        guard let domain = location.suiteName ?? Bundle.main.bundleIdentifier else { return }
        location.defaults.removePersistentDomain(forName: domain)
    }

    private static func resolve() -> Resolved {
#if DEBUG
        let choice = choice(
            isTestProcess: KeychainTestProcessGuard.isTestProcess,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            builtAsMacTestHost: builtAsMacTestHost,
            runsOnMac: runsOnMac
        )
        switch choice {
        case .production:
            return productionLocation()
        case .testProcess:
            return testProcessLocation()
        case .refusedOtherHost:
            preconditionFailure("macOS tests must run in \(macTestHostBundleIdentifier); they will not use the real app's domain.")
        case .refusedStandaloneHost:
            preconditionFailure("The macOS test host runs only under XCTest; a standalone launch would use the real profile.")
        }
#else
        return productionLocation()
#endif
    }

    private static func productionLocation() -> Resolved {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("No Application Support folder; the app will not store data elsewhere.")
        }
        return Resolved(
            defaults: .standard,
            suiteName: nil,
            directory: support.appendingPathComponent("Pomodorough", isDirectory: true)
        )
    }

#if DEBUG
    /// The one defaults suite and temporary folder of every test process.
    /// Each process clears both before any store reads them, so nothing
    /// builds up and no run sees an earlier run's data. The test schemes do
    /// not run tests in parallel, so one test process uses them at a time.
    static let testSuiteName = "PomodoroughTestHost"

    /// The bundle identifier of the macOS test host (`PomodoroughMacTestHost`).
    static let macTestHostBundleIdentifier = "me.egigoka.pomodorough.mac.testhost"

    static func isMacTestHost(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == macTestHostBundleIdentifier
    }

    enum Choice: Equatable {
        case production
        case testProcess
        /// Guard 3: a macOS test process outside the test host. AppKit keeps
        /// window frames, the status item position, saved state, caches and
        /// cookies under the bundle identifier, outside this seam, so only
        /// the test host's own identifier keeps them out of the real app's
        /// domain. The stop comes before the first window or status item.
        case refusedOtherHost
        /// The test host outside XCTest, for example opened from Finder. It
        /// would use the real profile, the system Keychain and Sentry, so it
        /// stops. The bundle identifier and the build flag are each enough.
        case refusedStandaloneHost
    }

    /// Set only on the `PomodoroughMacTestHost` target (project.yml).
    static var builtAsMacTestHost: Bool {
#if POMODOROUGH_MAC_TEST_HOST
        true
#else
        false
#endif
    }

    static var runsOnMac: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    static func choice(
        isTestProcess: Bool,
        bundleIdentifier: String?,
        builtAsMacTestHost: Bool,
        runsOnMac: Bool
    ) -> Choice {
        let isHost = isMacTestHost(bundleIdentifier: bundleIdentifier)
        guard runsOnMac else { return isTestProcess ? .testProcess : .production }
        if isTestProcess { return isHost ? .testProcess : .refusedOtherHost }
        return isHost || builtAsMacTestHost ? .refusedStandaloneHost : .production
    }

    /// Clears and returns the test location. Tests pass their own suite and
    /// root; only the default arguments touch the shared test location.
    static func testProcessLocation(
        suiteName: String = testSuiteName,
        root: URL = FileManager.default.temporaryDirectory
    ) -> Resolved {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Test process has no defaults suite \(suiteName); it will not use the real profile.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let folder = root.appendingPathComponent(suiteName, isDirectory: true)
        let directory = folder.appendingPathComponent("Pomodorough", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Test process has no clean storage folder (\(error)); it will not use the real profile.")
        }
        return Resolved(defaults: defaults, suiteName: suiteName, directory: directory)
    }
#endif
}
