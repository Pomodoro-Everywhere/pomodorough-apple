import SwiftUI

/// Shows `AppModel.errorMessage` on the surface the person is looking at.
/// The root alert dismisses an open sheet to present itself, which drops
/// what the person typed there. A sheet therefore hosts the alert while it
/// is open, and the root alert stands down until the sheet closes.
struct ErrorMessageAlert: ViewModifier {
    let model: AppModel
    let host: ErrorAlertHost

    func body(content: Content) -> some View {
        content
            .alert("Pomodorough", isPresented: isPresented) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? String(localized: "Unknown error"))
            }
            .onAppear { if host != .root { model.errorAlertHost = host } }
            .onDisappear {
                model.errorAlertHost = Self.activeHost(afterClosing: host, activeHost: model.errorAlertHost)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { Self.isShown(on: host, message: model.errorMessage, activeHost: model.errorAlertHost) },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    /// A closing sheet hands the alert back to the root only while it still
    /// holds it. A sheet that opened in its place keeps the alert.
    static func activeHost(afterClosing host: ErrorAlertHost, activeHost: ErrorAlertHost) -> ErrorAlertHost {
        host != .root && activeHost == host ? .root : activeHost
    }

    static func isShown(on host: ErrorAlertHost, message: String?, activeHost: ErrorAlertHost) -> Bool {
        message != nil && activeHost == host
    }
}
