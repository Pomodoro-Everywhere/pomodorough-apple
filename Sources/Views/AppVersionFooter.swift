import Foundation
import SwiftUI

enum AppVersionInfo {
    static func formatted(version: String?, build: String?) -> String {
        let resolvedVersion = version?.isEmpty == true ? "?" : (version ?? "?")
        let resolvedBuild = build?.isEmpty == true ? "?" : (build ?? "?")
        return String(localized: "Version \(resolvedVersion) (\(resolvedBuild))")
    }

    static var current: String {
        let info = Bundle.main.infoDictionary
        return formatted(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}

struct AppVersionFooter: View {
    var body: some View {
        Text(AppVersionInfo.current)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
