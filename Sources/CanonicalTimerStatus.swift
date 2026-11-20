/// The wire status of a canonical timer (`CanonicalTimer.Status`). It has
/// its own file so the hostless macOS command tests can map the typed value
/// without compiling the whole timer model.
enum CanonicalTimerStatus: String, Codable, Sendable {
    case running, paused, completed, cancelled, superseded
}
