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
enum CompletionChimeFailure: String, Error, Sendable, CaseIterable {
    case resourceMissing
    case sessionActivationFailed
    case playerCreationFailed
    case playbackRejected
}

extension CompletionChimeFailure: LocalizedError {
    var errorDescription: String? { rawValue }
}

@MainActor
protocol CompletionChimeSession: AnyObject {
    func activate() throws
    func deactivate()
}

@MainActor
protocol CompletionChimeSound: AnyObject {
    var onFinish: (@MainActor () -> Void)? { get set }
    @discardableResult func play() -> Bool
    func stop()
}

@MainActor
final class CompletionChimeController {
    private static let logger = Logger(
        subsystem: "me.egigoka.pomodorough",
        category: "CompletionChime"
    )

    private let resourceURL: () -> URL?
    private let makeSession: () -> CompletionChimeSession
    private let makePlayer: (URL) throws -> CompletionChimeSound
    private let report: (CompletionChimeFailure) -> Void
    private var session: CompletionChimeSession?
    private var sound: CompletionChimeSound?
    private var sessionActive = false

    init(
        resourceURL: @escaping () -> URL?,
        makeSession: @escaping () -> CompletionChimeSession,
        makePlayer: @escaping (URL) throws -> CompletionChimeSound,
        report: @escaping (CompletionChimeFailure) -> Void
    ) {
        self.resourceURL = resourceURL
        self.makeSession = makeSession
        self.makePlayer = makePlayer
        self.report = report
    }

    func play() {
        releaseResources()
        guard let url = resourceURL() else {
            Self.logger.error("CompletionChime.wav missing from bundle")
            report(.resourceMissing)
            releaseResources()
            return
        }
        let sound: CompletionChimeSound
        do {
            sound = try makePlayer(url)
        } catch {
            Self.logger.error("completion chime decode failed: \(error.localizedDescription, privacy: .public)")
            report(.playerCreationFailed)
            releaseResources()
            return
        }
        let session = makeSession()
        self.sound = sound
        self.session = session
        do {
            try session.activate()
        } catch {
            Self.logger.error("completion chime session failed: \(error.localizedDescription, privacy: .public)")
            report(.sessionActivationFailed)
            releaseResources()
            return
        }
        sessionActive = true
        sound.onFinish = { [weak self] in self?.handleFinish() }
        guard sound.play() else {
            Self.logger.error("completion chime playback rejected")
            report(.playbackRejected)
            releaseResources()
            return
        }
    }

    func stop() {
        releaseResources()
    }

    func handleFinish() {
        releaseResources()
    }

    private func releaseResources() {
        if let sound {
            sound.onFinish = nil
            sound.stop()
            self.sound = nil
        }
        if sessionActive {
            session?.deactivate()
            sessionActive = false
        }
        session = nil
    }

    static func production(
        resourceURL: @escaping () -> URL? = {
            Bundle.main.url(forResource: "CompletionChime", withExtension: "wav")
        },
        report: ((CompletionChimeFailure) -> Void)? = nil
    ) -> CompletionChimeController {
        let report = report ?? { failure in
            Self.logger.error("completion chime failed: \(failure.rawValue, privacy: .public)")
            SentryCapture.captureOnce(key: "completion-chime-\(failure.rawValue)", error: failure)
        }
#if os(iOS)
        return CompletionChimeController(
            resourceURL: resourceURL,
            makeSession: { AVChimeSession() },
            makePlayer: { url in try AVChimeSound(contentsOf: url) },
            report: report
        )
#else
        return CompletionChimeController(
            resourceURL: resourceURL,
            makeSession: { NoopChimeSession() },
            makePlayer: { _ in NoopChimeSound() },
            report: report
        )
#endif
    }
}

@MainActor
final class NoopChimeSession: CompletionChimeSession {
    func activate() throws {}
    func deactivate() {}
}

@MainActor
final class NoopChimeSound: CompletionChimeSound {
    var onFinish: (@MainActor () -> Void)?
    func play() -> Bool { true }
    func stop() {}
}

#if os(iOS)
@MainActor
final class AVChimeSession: CompletionChimeSession {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.duckOthers])
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

@MainActor
final class AVChimeSound: NSObject, CompletionChimeSound, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?
    private let player: AVAudioPlayer

    init(contentsOf url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func play() -> Bool {
        player.play()
    }

    func stop() {
        player.stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
#endif

@MainActor
final class CompletionChimePlayer: NSObject {
    static let shared = CompletionChimePlayer()

    private static let logger = Logger(
        subsystem: "me.egigoka.pomodorough",
        category: "CompletionChime"
    )

    private let controller: CompletionChimeController

    private override init() {
        controller = .production()
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
        controller.play()
#else
        // macOS already loops the chime through its notification coordinator.
        return
#endif
    }

    func stop() {
#if os(iOS)
        controller.stop()
#else
        return
#endif
    }
}
