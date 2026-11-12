import Foundation
import Security
#if DEBUG
import Synchronization
#endif

/// Single source of the `security:` default for every Keychain-backed store
/// (KeychainStore, KeychainLogoutRevocationStore, IrohEndpointKeychainStore,
/// IrohRoomSecretKeychainStore). Release builds always get the system
/// Keychain. A DEBUG test process gets a process-wide in-memory keychain, so
/// a test that omits an injected store cannot read or write the developer's
/// real items (R54-APB02). The decision is made here, in the app target,
/// because hosted unit tests run `PomodoroughApp.init()` and build an
/// `AppModel` before XCTest loads the test bundle.
enum KeychainSecurityDefault {
    static func resolve() -> any KeychainSecurityOperating {
#if DEBUG
        if KeychainTestProcessGuard.isTestProcess {
            return IsolatedTestKeychainSecurity.processShared
        }
#endif
        return SystemKeychainSecurity()
    }
}

enum SystemKeychainOperation: String, CaseIterable, Sendable {
    case copyMatching
    case copyAccounts
    case update
    case add
    case delete
}

/// Blocks SecItem calls from a test process. Only an explicitly built
/// `SystemKeychainSecurity` can reach this guard in a test, because
/// `KeychainSecurityDefault` never returns one there. A blocked call does not
/// touch the Keychain: it returns `refusedStatus` and reports the violation
/// to the reporter the test bundle installs. With no reporter installed the
/// violation stops the process, so a missed isolation can never pass quietly.
///
/// Production safety: everything except `refusal` returning `nil` is
/// compiled only in DEBUG. Release builds (the install scripts, archives and
/// store builds) contain no detection code and call SecItem directly.
enum KeychainTestProcessGuard {
    static let refusedStatus: OSStatus = errSecNotAvailable

    static func refusal(_ operation: SystemKeychainOperation, query: [String: Any]) -> OSStatus? {
#if DEBUG
        guard isTestProcess else { return nil }
        report(KeychainTestProcessViolation(operation: operation, query: query))
        return refusedStatus
#else
        return nil
#endif
    }

#if DEBUG
    typealias ViolationReporter = @Sendable (KeychainTestProcessViolation) -> Void

    private static let reporter = Mutex<ViolationReporter?>(nil)

    /// Same signals as TestAudioSuppression and SentryCapture. Hosted unit
    /// tests set the variable from launch, so it already holds during the
    /// host app's own startup. UI-tested apps run in another process and see
    /// neither signal; they keep the simulator app's own Keychain.
    static var isTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func installViolationReporter(_ newReporter: @escaping ViolationReporter) {
        reporter.withLock { $0 = newReporter }
    }

    static var hasViolationReporter: Bool {
        reporter.withLock { $0 != nil }
    }

    private static func report(_ violation: KeychainTestProcessViolation) {
        guard let installed = reporter.withLock({ $0 }) else {
            preconditionFailure(violation.description)
        }
        installed(violation)
    }
#endif
}

#if DEBUG
struct KeychainTestProcessViolation: Sendable, CustomStringConvertible {
    let operation: SystemKeychainOperation
    let service: String?
    let account: String?

    init(operation: SystemKeychainOperation, query: [String: Any]) {
        self.operation = operation
        service = query[kSecAttrService as String] as? String
        account = query[kSecAttrAccount as String] as? String
    }

    var description: String {
        "System Keychain \(operation.rawValue) blocked in a test process "
            + "(service \(service ?? "none"), account \(account ?? "none")). "
            + "Inject a test store or RecordingKeychainSecurity instead (R54-APB02)."
    }
}
#endif
