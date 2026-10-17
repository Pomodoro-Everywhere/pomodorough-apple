#!/usr/bin/env python3
"""R49-AP06 Watch activation logging: payload-free fixed keys, dedupe, budget.

Narrow harness only: compiles the actual on-disk WatchSyncService callback
with recording OSLog/WatchConnectivity substitutes plus the real
WatchSyncLogDedupe, then drives the production boundary. Also typechecks the
two unchanged on-disk files against the watchOS SDK. No Xcode project build,
no simulator, no production edits.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

APPLE = Path(__file__).resolve().parents[2]
SERVICE_REL = Path("Watch/WatchSyncService.swift")
PAYLOAD_REL = Path("Sources/WatchSyncPayload.swift")
EXPECTED_KEYS = frozenset(
    {
        "watch-activation-failed-not-activated",
        "watch-activation-failed-inactive",
        "watch-activation-failed-activated",
        "watch-activation-failed-unknown",
    }
)
STATE_KEY = {
    "notActivated": "watch-activation-failed-not-activated",
    "inactive": "watch-activation-failed-inactive",
    "activated": "watch-activation-failed-activated",
}
MAX_KEY_BYTES = 37

STUBS = r'''
import Foundation
import Combine
import Dispatch

enum LogPrivacy: String, Sendable { case `public` }
struct RecordedMessage: ExpressibleByStringInterpolation, Sendable {
    var value: String
    var privacy: [LogPrivacy]
    init(stringLiteral value: String) { self.value = value; privacy = [] }
    init(stringInterpolation: StringInterpolation) {
        value = stringInterpolation.value; privacy = stringInterpolation.privacy
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var value = ""
        var privacy: [LogPrivacy] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { value += literal }
        mutating func appendInterpolation(_ text: String, privacy level: LogPrivacy) {
            value += text; privacy.append(level)
        }
    }
}
struct LogEntry: Equatable, Sendable {
    let subsystem: String
    let category: String
    let level: String
    let value: String
    let privacy: [LogPrivacy]
}
final class RecordedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    func append(_ entry: LogEntry) { lock.withLock { entries.append(entry) } }
    func read() -> [LogEntry] { lock.withLock { entries } }
}
struct Logger: Sendable {
    static let recording = RecordedLog()
    let subsystem: String
    let category: String
    func error(_ message: RecordedMessage) {
        Self.recording.append(LogEntry(subsystem: subsystem, category: category,
            level: "error", value: message.value, privacy: message.privacy))
    }
}
enum WCSessionActivationState: Int, CaseIterable, Sendable {
    case notActivated, inactive, activated
    case futureOne = 99, futureTwo = 100
}
protocol WCSessionDelegate: AnyObject {}
struct TransportEntry: Equatable, Sendable {
    let operation: String
    let keys: [String]
    let requestSync: Bool?
}
final class WCSession: @unchecked Sendable {
    private static let shared = WCSession()
    private let lock = NSLock()
    private var reads = 0
    private var supported = true
    private var state: WCSessionActivationState = .notActivated
    private var reachable = false
    private var calls: [TransportEntry] = []
    private var activations = 0
    weak var delegate: (any WCSessionDelegate)?
    static var `default`: WCSession {
        shared.lock.withLock { shared.reads += 1 }; return shared
    }
    static var defaultReads: Int { shared.lock.withLock { shared.reads } }
    static func isSupported() -> Bool { shared.lock.withLock { shared.supported } }
    static func setSupported(_ value: Bool) { shared.lock.withLock { shared.supported = value } }
    var activationState: WCSessionActivationState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
    var isReachable: Bool {
        get { lock.withLock { reachable } }
        set { lock.withLock { reachable = newValue } }
    }
    func activate() { lock.withLock { activations += 1 } }
    var activationCount: Int { lock.withLock { activations } }
    func takeTrace() -> [TransportEntry] {
        lock.withLock { let result = calls; calls.removeAll(); return result }
    }
    private func record(_ operation: String, _ payload: [String: Any]) {
        let entry = TransportEntry(operation: operation, keys: payload.keys.sorted(),
            requestSync: payload[WatchSyncKeys.requestSync] as? Bool)
        lock.withLock { calls.append(entry) }
    }
    func sendMessage(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                     errorHandler: ((any Error) -> Void)?) {
        record("sendMessage", payload)
    }
    func updateApplicationContext(_ payload: [String: Any]) throws {
        record("updateApplicationContext", payload)
    }
    func transferUserInfo(_ payload: [String: Any]) -> Int {
        record("transferUserInfo", payload); return 1
    }
}
struct PoisonActivationError: CustomNSError, LocalizedError, CustomStringConvertible, Sendable {
    static var errorDomain: String { fatalError("activation error domain was read") }
    var errorCode: Int { fatalError("activation error code was read") }
    var errorUserInfo: [String: Any] { fatalError("activation error userInfo was read") }
    var errorDescription: String? { fatalError("activation error description was read") }
    var failureReason: String? { fatalError("activation error failure reason was read") }
    var recoverySuggestion: String? { fatalError("activation error recovery suggestion was read") }
    var description: String { fatalError("activation error string description was read") }
}
'''

DRIVER = r'''
import Foundation
import Dispatch

@main struct CheckActivation {
    static let states = WCSessionActivationState.allCases
    static let expectedKeys = Set([
        "watch-activation-failed-not-activated", "watch-activation-failed-inactive",
        "watch-activation-failed-activated", "watch-activation-failed-unknown",
    ])

    static func key(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated: "watch-activation-failed-not-activated"
        case .inactive: "watch-activation-failed-inactive"
        case .activated: "watch-activation-failed-activated"
        case .futureOne, .futureTwo: "watch-activation-failed-unknown"
        }
    }

    @MainActor static func drain(_ expectedReads: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while WCSession.defaultReads < expectedReads {
            precondition(ContinuousClock.now < deadline, "callback MainActor work did not finish")
            await Task.yield()
        }
        precondition(WCSession.defaultReads == expectedReads, "unexpected sync pull count")
    }

    static func expected(_ state: WCSessionActivationState, _ supported: Bool,
                         _ reachable: Bool, _ count: Int) -> [TransportEntry] {
        guard supported && state == .activated else { return [] }
        let operation = reachable ? "sendMessage" : "updateApplicationContext"
        return Array(repeating: TransportEntry(operation: operation,
            keys: ["requestSync"], requestSync: true), count: count)
    }

    @MainActor static func main() async {
        let session = WCSession.default
        let services = [WatchSyncService(), WatchSyncService()]
        precondition(session.activationCount == 2)
        precondition(session.delegate === services[1])
        for service in services {
            precondition(service.snapshot == nil)
            service.commandError = "existing command error PRIVATE-COMMAND"
        }
        precondition(Logger.recording.read().isEmpty)
        for state in states {
            session.activationState = state
            for supported in [false, true] {
                WCSession.setSupported(supported)
                for reachable in [false, true] {
                    session.isReachable = reachable
                    for _ in 0..<25 { services[0].requestSync() }
                    precondition(session.takeTrace() == expected(state, supported, reachable, 25))
                    precondition(Logger.recording.read().isEmpty)
                }
            }
        }
        print("PASS direct pulls: 20 combinations, 500 pulls, exact transport payloads, no logs")
        fflush(nil)
        for reportedState in states {
            for liveState in states {
                session.activationState = liveState
                for supported in [false, true] {
                    WCSession.setSupported(supported)
                    for reachable in [false, true] {
                        session.isReachable = reachable
                        let reads = WCSession.defaultReads
                        for index in 0..<3 {
                            services[index % 2].session(session,
                                activationDidCompleteWith: reportedState, error: nil)
                        }
                        await drain(reads + 3)
                        precondition(session.takeTrace() == expected(liveState, supported, reachable, 3))
                        precondition(services.allSatisfy { $0.isReachable == reachable })
                        precondition(Logger.recording.read().isEmpty, "no-error callback logged")
                    }
                }
            }
        }
        print("PASS no-error callbacks: 100 combinations, 300 callbacks, reported/live state separated, no logs")
        fflush(nil)
        WCSession.setSupported(true)
        session.activationState = .notActivated
        session.isReachable = false
        if CommandLine.arguments.contains("--state-mapping") {
            var seen = Set<String>()
            for state in states {
                let reads = WCSession.defaultReads
                services[seen.count % 2].session(session,
                    activationDidCompleteWith: state, error: PoisonActivationError())
                await drain(reads + 1)
                seen.insert(key(state))
                let entries = Logger.recording.read()
                precondition(entries.count == seen.count && Set(entries.map(\.value)) == seen,
                    "activation failures must emit exactly four distinct bounded keys: wrong mapping for \(state)")
            }
            print("PASS state mapping: each reported state gets exact key despite inactive live session; both future states share unknown")
        } else {
            let reads = WCSession.defaultReads
            DispatchQueue.concurrentPerform(iterations: 4000) { index in
                services[index % 2].session(session, activationDidCompleteWith: states[index % states.count],
                    error: PoisonActivationError())
            }
            await drain(reads + 4000)
            print("PASS concurrent failures: 4000 callbacks across two instances")
        }
        fflush(nil)
        precondition(session.takeTrace().isEmpty)
        let firstEntries = Logger.recording.read()
        precondition(Set(firstEntries.map(\.value)) == expectedKeys && firstEntries.count == 4,
                     "activation failures must emit exactly four distinct bounded keys")
        print("PASS process bound: exactly four logs across two instances")
        fflush(nil)
        var errors = 0
        for reportedState in states {
            for liveState in states {
                session.activationState = liveState
                for supported in [false, true] {
                    WCSession.setSupported(supported)
                    for reachable in [false, true] {
                        session.isReachable = reachable
                        let reads = WCSession.defaultReads
                        for index in 0..<11 {
                            let error: any Error = index.isMultiple(of: 2) ? PoisonActivationError() : NSError(
                                domain: "PRIVATE-ACCOUNT-DOMAIN-\(errors)", code: errors,
                                userInfo: [NSLocalizedDescriptionKey: String(repeating: "PRIVATE-ERROR", count: 1000),
                                           "snapshot": Data("PRIVATE-SNAPSHOT".utf8),
                                           "account": "PRIVATE-ACCOUNT-\(errors)"])
                            services[index % 2].session(session,
                                activationDidCompleteWith: reportedState, error: error)
                            errors += 1
                        }
                        await drain(reads + 11)
                        precondition(session.takeTrace() == expected(liveState, supported, reachable, 11))
                        precondition(services.allSatisfy { $0.isReachable == reachable })
                        precondition(Logger.recording.read() == firstEntries, "repeated failure added a log")
                    }
                }
            }
        }
        print("PASS repeated failures: 1100 callbacks, 100 combinations, exact transport payloads, no extra logs")
        fflush(nil)
        WCSession.setSupported(true)
        session.activationState = .inactive
        session.isReachable = true
        let finalReads = WCSession.defaultReads
        for state in states { services[0].session(session, activationDidCompleteWith: state, error: nil) }
        await drain(finalReads + states.count)
        precondition(session.takeTrace().isEmpty)
        precondition(Logger.recording.read() == firstEntries)
        for entry in firstEntries {
            precondition(entry.subsystem == "me.egigoka.pomodorough" && entry.category == "WatchSync")
            precondition(entry.level == "error" && entry.privacy == [.public])
            precondition(expectedKeys.contains(entry.value) && entry.value.utf8.count <= 37)
        }
        precondition(services.allSatisfy { $0.commandError == "existing command error PRIVATE-COMMAND" })
        precondition(services.allSatisfy { $0.snapshot == nil })
        print("PASS privacy: real production logger, exact fixed public keys only, hostile error getters never read")
        print("PASS behavior: existing command errors and snapshots unchanged, no-error callbacks silent after errors")
        for entry in firstEntries.sorted(by: { $0.value < $1.value }) { print("LOG \(entry.value)") }
    }
}
'''


def _activation_block(source: str) -> str:
    start = source.index("activationDidCompleteWith")
    end = source.index("func sessionReachabilityDidChange", start)
    return source[start:end]


def _compile_once(workdir: Path, service_text: str, payload_text: str) -> Path:
    transformed = service_text.replace("import OSLog\n", "")
    transformed = transformed.replace("import WatchConnectivity\n", "")
    (workdir / "stubs.swift").write_text(STUBS)
    (workdir / "service.swift").write_text(transformed)
    (workdir / "payload.swift").write_text(payload_text)
    (workdir / "driver.swift").write_text(DRIVER)
    binary = workdir / "ap06-probe"
    compiled = subprocess.run(
        [
            "xcrun", "swiftc", "-swift-version", "6",
            "-strict-concurrency=complete", "-parse-as-library",
            "-module-cache-path", str(workdir / "module-cache"),
            str(workdir / "stubs.swift"), str(workdir / "service.swift"),
            str(workdir / "payload.swift"), str(workdir / "driver.swift"),
            "-o", str(binary),
        ],
        cwd=APPLE, capture_output=True, text=True, timeout=300,
    )
    if compiled.returncode != 0:
        raise AssertionError(f"probe compile failed: {compiled.stderr}")
    return binary


def _run_binary(binary: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), *args], capture_output=True, text=True, timeout=120,
    )


def _typecheck_watch_sdk() -> subprocess.CompletedProcess[str]:
    sdk = subprocess.run(
        ["xcrun", "--sdk", "watchos", "--show-sdk-path"],
        cwd=APPLE, capture_output=True, text=True, timeout=60,
    )
    if sdk.returncode != 0:
        raise AssertionError(f"sdk path failed: {sdk.stderr}")
    return subprocess.run(
        [
            "xcrun", "--sdk", "watchos", "swiftc", "-typecheck",
            "-sdk", sdk.stdout.strip(),
            "-target", "arm64_32-apple-watchos11.0",
            "-swift-version", "6", "-strict-concurrency=complete",
            "-warnings-as-errors",
            str(SERVICE_REL), str(PAYLOAD_REL),
        ],
        cwd=APPLE, capture_output=True, text=True, timeout=300,
    )


@unittest.skipUnless(shutil.which("xcrun"), "requires xcrun swiftc")
class R49AP06WatchActivationLoggingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._workdir = Path(tempfile.mkdtemp(prefix="r49-ap06-"))
        cls.addClassCleanup(shutil.rmtree, cls._workdir, True)
        cls.service = (APPLE / SERVICE_REL).read_text()
        cls.payload = (APPLE / PAYLOAD_REL).read_text()
        cls.binary = _compile_once(cls._workdir, cls.service, cls.payload)
        mapping = _run_binary(cls.binary, ["--state-mapping"])
        concurrent = _run_binary(cls.binary, [])
        cls.mapping = mapping
        cls.concurrent = concurrent
        cls.typecheck = _typecheck_watch_sdk()

    def test_callback_gates_non_nil_error(self) -> None:
        block = _activation_block(self.service)
        self.assertIn("if error != nil {", block)
        self.assertIn("case .notActivated:", block)
        self.assertIn("case .inactive:", block)
        self.assertIn("case .activated:", block)
        self.assertIn("@unknown default:", block)

    def test_activation_uses_payload_free_logger_only(self) -> None:
        block = _activation_block(self.service)
        for key in EXPECTED_KEYS:
            self.assertIn(f'logOnce(key: "{key}")', block)
        gated = block[block.index("if error != nil {"):]
        self.assertNotIn("localizedDescription", gated)
        self.assertNotIn("error: error", gated)
        self.assertNotIn("userInfo", gated)

    def test_fixed_keys_bounded_distinct(self) -> None:
        self.assertEqual(len(EXPECTED_KEYS), 4)
        for key in EXPECTED_KEYS:
            self.assertLessEqual(len(key.encode()), MAX_KEY_BYTES)
        self.assertEqual(STATE_KEY["notActivated"], "watch-activation-failed-not-activated")
        self.assertEqual(STATE_KEY["inactive"], "watch-activation-failed-inactive")
        self.assertEqual(STATE_KEY["activated"], "watch-activation-failed-activated")

    def test_request_sync_guard_unchanged(self) -> None:
        guard_line = "guard WCSession.isSupported(), session.activationState == .activated else { return }"
        self.assertIn(guard_line, self.service)

    def test_direct_pulls_preserve_transport(self) -> None:
        self.assertEqual(self.mapping.returncode, 0, self.mapping.stderr)
        self.assertIn("PASS direct pulls", self.mapping.stdout)
        self.assertIn("PASS direct pulls", self.concurrent.stdout)

    def test_no_error_callbacks_silent(self) -> None:
        self.assertIn("PASS no-error callbacks", self.mapping.stdout)
        self.assertIn("PASS no-error callbacks", self.concurrent.stdout)

    def test_state_mapping_exact_keys(self) -> None:
        self.assertEqual(self.mapping.returncode, 0, self.mapping.stderr)
        self.assertIn("PASS state mapping", self.mapping.stdout)
        self.assertIn("PASS process bound", self.mapping.stdout)

    def test_future_states_share_unknown_key(self) -> None:
        logs = [line for line in self.mapping.stdout.splitlines() if line.startswith("LOG ")]
        self.assertEqual(len(logs), 4)
        self.assertIn("LOG watch-activation-failed-unknown", logs)
        self.assertEqual(sorted(logs), sorted(f"LOG {key}" for key in EXPECTED_KEYS))

    def test_process_bound_four_across_two_instances(self) -> None:
        for result in (self.mapping, self.concurrent):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS process bound: exactly four logs", result.stdout)

    def test_concurrent_4000_budget(self) -> None:
        self.assertEqual(self.concurrent.returncode, 0, self.concurrent.stderr)
        self.assertIn("PASS concurrent failures: 4000 callbacks", self.concurrent.stdout)

    def test_repeated_failures_add_no_logs(self) -> None:
        for result in (self.mapping, self.concurrent):
            self.assertIn("PASS repeated failures", result.stdout)
            self.assertNotIn("repeated failure added a log", result.stderr)

    def test_hostile_payloads_never_read(self) -> None:
        for result in (self.mapping, self.concurrent):
            self.assertIn("PASS privacy", result.stdout)
            self.assertNotIn("PRIVATE-", result.stdout)
            self.assertNotIn("was read", result.stderr)

    def test_transport_preserved_after_errors(self) -> None:
        for result in (self.mapping, self.concurrent):
            self.assertIn("PASS behavior", result.stdout)

    def test_watchos_sdk_typecheck(self) -> None:
        self.assertEqual(self.typecheck.returncode, 0, self.typecheck.stderr)


if __name__ == "__main__":
    unittest.main()
