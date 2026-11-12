import Foundation
import Testing
@testable import Pomodorough

/// Hosted unit tests run inside a host app: the real iOS app, or the macOS
/// test host. Every store an app model builds by default must stay out of
/// the real profile: the standard defaults domain and
/// `Application Support/Pomodorough`. These tests only compute the real
/// paths; they never open the files there.
@Suite("Default storage of a test process")
@MainActor
struct DefaultStorageLocationTests {
    private static var realStorageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomodorough", isDirectory: true)
            .standardizedFileURL
    }

    /// Builds the model the way the host app does, with fakes only for the
    /// Keychain, network and Google, and reads where its stores point.
    @Test func defaultStoresOfAModelStayOutOfTheRealProfile() throws {
        let rooms = IrohRoomStore(secretStore: MemoryIrohRoomSecretStore())
        let model = AppModel(
            api: APIClient(
                session: TestFixtures.session(for: "default-storage-\(UUID().uuidString)"),
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            roomStore: rooms,
            endpointKeyStore: PreviewEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )

        let defaults = try #require(Mirror(reflecting: model).descendant("defaults") as? UserDefaults)
        #expect(defaults !== UserDefaults.standard, "the model must not use the standard domain")
        let files = Self.storedURLs(in: [
            Mirror(reflecting: model).descendant("persistence") as Any,
            Mirror(reflecting: model).descendant("accountDeletionJournal") as Any,
            rooms,
        ])
        #expect(files.count >= 3, "the durable workspace, deletion journal and room files")
        for file in files {
            #expect(!file.standardizedFileURL.path.hasPrefix(Self.realStorageFolder.path),
                    "\(file.lastPathComponent) is in the real profile")
        }
    }

    @Test func testProcessGetsItsOwnSuiteAndFolder() throws {
        let location = DefaultStorageLocation.current
        let suite = try #require(location.suiteName, "a test process never uses the standard domain")
        #expect(suite == DefaultStorageLocation.testSuiteName)
        #expect(suite != Bundle.main.bundleIdentifier)
        #expect(location.defaults !== UserDefaults.standard)

        let folder = location.directory.standardizedFileURL.path
        #expect(folder.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(!folder.hasPrefix(Self.realStorageFolder.path))
        #expect(DefaultStorageLocation.fileURL("timer-state-v2.json").deletingLastPathComponent().path
            == location.directory.path)
    }

    /// Each test process clears the test suite and folder before any store
    /// reads them. This uses its own suite and root, so it never clears the
    /// location the running process uses.
    @Test func eachTestProcessStartsFromAClearedSuiteAndFolder() throws {
        let suite = "\(DefaultStorageLocation.testSuiteName).ClearCheck"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-storage-\(UUID().uuidString)", isDirectory: true)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let earlier = DefaultStorageLocation.testProcessLocation(suiteName: suite, root: root)
        earlier.defaults.set("earlier run", forKey: "left-behind")
        let leftFile = earlier.directory.appendingPathComponent("timer-state-v2.json")
        try Data("{}".utf8).write(to: leftFile)

        let next = DefaultStorageLocation.testProcessLocation(suiteName: suite, root: root)
        #expect(next.defaults.string(forKey: "left-behind") == nil)
        #expect(!FileManager.default.fileExists(atPath: leftFile.path))
        #expect(FileManager.default.fileExists(atPath: next.directory.path))
        #expect(next.directory.path.hasPrefix(root.path))

        next.defaults.set("ui-test state", forKey: "reset-me")
        DefaultStorageLocation.removeDefaults(of: next)
        #expect(next.defaults.string(forKey: "reset-me") == nil, "removeDefaults clears the location's own suite")
    }

    /// Guard 3 of the macOS host isolation: only the test host's own bundle
    /// identifier (project.yml `PomodoroughMacTestHost`) may run tests.
    @Test func onlyTheMacTestHostIdentifierPassesTheHostCheck() {
        #expect(DefaultStorageLocation.isMacTestHost(bundleIdentifier: "me.egigoka.pomodorough.mac.testhost"))
        let others: [String?] = [
            nil, "", "me.egigoka.pomodorough.mac", "me.egigoka.pomodorough",
            "me.egigoka.pomodorough.mac.testhost.extra", "ME.EGIGOKA.POMODOROUGH.MAC.TESTHOST",
        ]
        for other in others {
            #expect(!DefaultStorageLocation.isMacTestHost(bundleIdentifier: other), "\(String(describing: other))")
        }
    }

#if os(macOS)
    @Test func macTestsRunInTheTestHost() {
        #expect(Bundle.main.bundleIdentifier == DefaultStorageLocation.macTestHostBundleIdentifier)
        #expect(Bundle.main.bundleIdentifier != "me.egigoka.pomodorough.mac")
        #expect(DefaultStorageLocation.builtAsMacTestHost, "project.yml sets POMODOROUGH_MAC_TEST_HOST on the host")
    }
#else
    @Test func iOSHostIsNotTheMacTestHost() {
        #expect(!DefaultStorageLocation.builtAsMacTestHost)
    }
#endif

    // Test arguments are built outside the main actor.
    nonisolated private static let host = "me.egigoka.pomodorough.mac.testhost"
    nonisolated private static let macApp = "me.egigoka.pomodorough.mac"

    /// On macOS the host's bundle identifier and its build flag are each a
    /// second signal next to `isTestProcess`: a standalone host launch stops
    /// whatever XCTest reports, and a test outside the host stops (Guard 3).
    @Test(arguments: [
        (true, host, true, DefaultStorageLocation.Choice.testProcess),
        (true, host, false, .testProcess),
        (true, macApp, false, .refusedOtherHost),
        (true, macApp, true, .refusedOtherHost),
        (true, nil, false, .refusedOtherHost),
        (false, host, true, .refusedStandaloneHost),
        (false, host, false, .refusedStandaloneHost),
        (false, macApp, true, .refusedStandaloneHost),
        (false, nil, true, .refusedStandaloneHost),
        (false, macApp, false, .production),
        (false, nil, false, .production),
    ] as [(Bool, String?, Bool, DefaultStorageLocation.Choice)])
    func macChoiceUsesTheHostAsASecondSignal(
        isTestProcess: Bool, bundle: String?, builtAsHost: Bool, expected: DefaultStorageLocation.Choice
    ) {
        let choice = DefaultStorageLocation.choice(
            isTestProcess: isTestProcess, bundleIdentifier: bundle, builtAsMacTestHost: builtAsHost, runsOnMac: true
        )
        #expect(choice == expected)
    }

    /// iOS has no test host: the hosted tests run in the real app bundle and
    /// only `isTestProcess` decides.
    @Test(arguments: [nil, "me.egigoka.pomodorough", host] as [String?])
    func iOSChoiceFollowsOnlyTheTestProcess(bundle: String?) {
        for builtAsHost in [false, true] {
            #expect(DefaultStorageLocation.choice(
                isTestProcess: true, bundleIdentifier: bundle, builtAsMacTestHost: builtAsHost, runsOnMac: false
            ) == .testProcess)
            #expect(DefaultStorageLocation.choice(
                isTestProcess: false, bundleIdentifier: bundle, builtAsMacTestHost: builtAsHost, runsOnMac: false
            ) == .production)
        }
    }

    /// Pins the two stops and the Release guard in the source: Guard 3 (a
    /// macOS test outside the host), the standalone host launch, and the
    /// compile error for a Release build of the host. The decision table
    /// above cannot see a stop that `resolve()` turns back into a location.
    @Test func hostStopsAndReleaseGuardStayInTheSource() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/DefaultStorageLocation.swift"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for stop in ["case .refusedOtherHost:", "case .refusedStandaloneHost:"] {
            let index = try #require(lines.firstIndex(of: stop), "\(stop) is missing from resolve()")
            #expect(lines[index + 1].hasPrefix("preconditionFailure("), "\(stop) must stop the process")
        }
        #expect(source.contains("isTestProcess: KeychainTestProcessGuard.isTestProcess,"))
        #expect(source.contains("bundleIdentifier: Bundle.main.bundleIdentifier,"))
        #expect(source.contains("builtAsMacTestHost: builtAsMacTestHost,"))
        let guardStart = try #require(lines.firstIndex(of: "#if POMODOROUGH_MAC_TEST_HOST && !DEBUG"))
        #expect(lines[guardStart + 1].hasPrefix("#error("), "a Release build of the test host must not compile")

        let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        #expect(project.components(separatedBy: "POMODOROUGH_MAC_TEST_HOST").count == 2, "only one target sets the flag")
        let hostSection = try #require(project.range(of: "  PomodoroughMacTestHost:\n"))
        let flag = try #require(project.range(of: "SWIFT_ACTIVE_COMPILATION_CONDITIONS: \"$(inherited) POMODOROUGH_MAC_TEST_HOST\""))
        // "Pomodorough-watchOS" appears twice in project.yml: once as a scheme
        // and once as a target, so search only after the host target.
        let nextTarget = try #require(project.range(
            of: "  Pomodorough-watchOS:\n", range: hostSection.upperBound..<project.endIndex
        ))
        #expect(hostSection.upperBound < flag.lowerBound && flag.upperBound < nextTarget.lowerBound,
                "the flag belongs to the PomodoroughMacTestHost target only")
    }

#if os(iOS)
    @Test func watchSyncDefaultsToTheDefaultStorage() throws {
        let service = WatchSyncService()
        let defaults = try #require(Mirror(reflecting: service).descendant("sequenceDefaults") as? UserDefaults)
        #expect(defaults === DefaultStorageLocation.defaults)
    }
#endif

    /// Pins every default store site in the app target to the seam: a revert
    /// of an `@AppStorage` store, a `.standard` default or a direct
    /// Application Support path turns this red.
    @Test func appSourcesReachStorageOnlyThroughTheSeam() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var appStorageSites = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            guard name != "DefaultStorageLocation.swift" else { continue }
            scanned += 1
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let site = "\(name):\(index + 1)"
                for banned in Self.bannedStorageReads where line.contains(banned) {
                    Issue.record("\(site) reads storage directly: \(banned)")
                }
                if line.contains("UserDefaults(suiteName:") && !line.contains("PomodoroughPreview") {
                    Issue.record("\(site) opens a defaults suite outside the seam")
                }
                if line.contains("@AppStorage(") {
                    appStorageSites += 1
                    #expect(line.contains("store: DefaultStorageLocation.defaults"), "\(site) @AppStorage uses the standard domain")
                }
                if line.contains("POMODOROUGH_UI_TEST_RESET") {
                    #expect(name == "UITestStorageReset.swift", "\(site) reads the UI-test reset outside its guard")
                }
            }
        }
        #expect(scanned > 100)
        #expect(appStorageSites >= 2, "the menu bar display sites in PomodoroughApp and MenuBarTimer")
    }

    private static let bannedStorageReads = [
        "UserDefaults.standard", "UserDefaults()", "= .standard", "applicationSupportDirectory",
    ]

    /// File URLs held by the given stores, a few levels down.
    private static func storedURLs(in subjects: [Any]) -> [URL] {
        func collect(_ value: Any, depth: Int) -> [URL] {
            if let url = value as? URL { return url.isFileURL ? [url] : [] }
            guard depth > 0 else { return [] }
            return Mirror(reflecting: value).children.flatMap { collect($0.value, depth: depth - 1) }
        }
        return subjects.flatMap { collect($0, depth: 4) }
    }
}
