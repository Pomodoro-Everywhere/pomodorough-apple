import Foundation
import Testing
@testable import Pomodorough

/// Test bundle principal class (NSPrincipalClass in project.yml for
/// PomodoroughTests and PomodoroughMacTests). XCTest creates it once when it
/// loads the bundle, before any test runs. It turns a blocked System Keychain
/// call into a recorded issue, so the offending test fails without stopping
/// the whole run. The fixed Objective-C name lets both test targets, which
/// have different module names, share one Info.plist value.
@objc(PomodoroughKeychainIsolationPrincipal)
final class KeychainIsolationPrincipal: NSObject {
    override init() {
        super.init()
#if DEBUG
        KeychainTestProcessGuard.installViolationReporter { violation in
            Issue.record(Comment(rawValue: violation.description))
        }
#endif
    }
}
