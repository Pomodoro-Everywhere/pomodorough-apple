import Foundation
import Testing
@testable import Pomodorough

@Suite("App version footer")
struct AppVersionInfoTests {
    @Test func formattedVersionContainsVersionAndBuild() {
        let rendered = AppVersionInfo.formatted(version: "1.2.3", build: "45")

        #expect(rendered.contains("1.2.3"))
        #expect(rendered.contains("45"))
        #expect(rendered.hasPrefix("Version "))
    }

    @Test func formattedVersionFallsBackWithoutHardcoding() {
        #expect(AppVersionInfo.formatted(version: nil, build: nil).contains("?"))
        #expect(AppVersionInfo.formatted(version: "", build: "").contains("?"))
    }

    @Test func currentVersionReadsRunningBundle() {
        let info = Bundle.main.infoDictionary
        let expected = AppVersionInfo.formatted(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )

        #expect(AppVersionInfo.current == expected)
        #expect(AppVersionInfo.current.hasPrefix("Version "))
    }
}
