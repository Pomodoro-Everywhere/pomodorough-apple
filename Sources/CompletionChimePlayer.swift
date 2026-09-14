import Foundation
import OSLog

#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Plays the bundled completion chime in-app when a timer phase completes
/// while Pomodorough is in the foreground. Uses the `.playback` audio session
/// category so it sounds like an alarm even with the silent switch on —
/// scheduled notification sounds are muted by the silent switch, so without
/// this the foreground completion is banner-only. Background completions are
/// covered by the scheduled notification/AlarmKit alarm instead (no audio
/// background mode, so in-app audio cannot fire there).
@MainActor
final class CompletionChimePlayer: NSObject {
    static let shared = CompletionChimePlayer()

    private static let logger = Logger(
        subsystem: "me.egigoka.pomodorough",
        category: "CompletionChime"
    )

#if os(iOS)
    private var player: AVAudioPlayer?
#endif

    private override init() {
        super.init()
    }

    static var isForeground: Bool {
#if os(iOS)
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }

    func playIfForeground() {
        guard Self.isForeground else { return }
        play()
    }

    func play() {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)
            guard let url = Bundle.main.url(forResource: "CompletionChime", withExtension: "wav") else {
                Self.logger.error("CompletionChime.wav missing from bundle")
                return
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.player = player
            player.play()
        } catch {
            Self.logger.error("completion chime failed: \(error.localizedDescription, privacy: .public)")
            SentryCapture.captureOnce(key: "completion-chime", error: error)
        }
#else
        // macOS already loops the chime through its notification coordinator.
        return
#endif
    }
}

#if os(iOS)
extension CompletionChimePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            CompletionChimePlayer.shared.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
#endif
