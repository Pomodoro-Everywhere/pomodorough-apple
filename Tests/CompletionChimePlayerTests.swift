import Foundation
import Testing
@testable import Pomodorough

// R43-AP06: fault-injection regressions for completion chime cleanup.
// Failed start, decode failure, explicit stop, and completion all release
// the session and stop the player exactly once with bounded categories.
@Suite("Completion chime cleanup (R43-AP06)")
@MainActor
struct CompletionChimePlayerTests {
    @MainActor
    final class FakeSession: CompletionChimeSession, @unchecked Sendable {
        var activateCount = 0
        var deactivateCount = 0
        var shouldThrowOnActivate: Error?

        func activate() throws {
            activateCount += 1
            if let error = shouldThrowOnActivate { throw error }
        }

        func deactivate() {
            deactivateCount += 1
        }
    }

    @MainActor
    final class FakeSound: CompletionChimeSound, @unchecked Sendable {
        var onFinish: (@MainActor () -> Void)?
        var playCount = 0
        var stopCount = 0
        var playResult = true

        func play() -> Bool {
            playCount += 1
            return playResult
        }

        func stop() {
            stopCount += 1
        }

        func simulateFinish() {
            onFinish?()
        }
    }

    private func makeController(
        resource: URL?,
        session: FakeSession,
        sound: FakeSound?,
        playerError: Error? = nil,
        reports: LockedTestValue<[CompletionChimeFailure]>
    ) -> CompletionChimeController {
        CompletionChimeController(
            resourceURL: { resource },
            makeSession: { session },
            makePlayer: { _ in
                if let playerError { throw playerError }
                return sound ?? FakeSound()
            },
            report: { failure in
                var current = reports.value
                current.append(failure)
                reports.value = current
            }
        )
    }

    @Test func missingResourceReleasesWithoutActivating() {
        let session = FakeSession()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: nil,
            session: session,
            sound: nil,
            reports: reports
        )
        controller.play()
        #expect(session.activateCount == 0)
        #expect(session.deactivateCount == 0)
        #expect(reports.value == [.resourceMissing])
    }

    @Test func sessionActivationFailureStopsPlayerAndReports() {
        let session = FakeSession()
        session.shouldThrowOnActivate = URLError(.cannotConnectToHost)
        let sound = FakeSound()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: URL(fileURLWithPath: "/tmp/chime.wav"),
            session: session,
            sound: sound,
            reports: reports
        )
        controller.play()
        #expect(session.activateCount == 1)
        #expect(session.deactivateCount == 0)
        #expect(sound.stopCount == 1)
        #expect(reports.value == [.sessionActivationFailed])
    }

    @Test func playerCreationFailureReleasesWithoutActivating() {
        let session = FakeSession()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: URL(fileURLWithPath: "/tmp/chime.wav"),
            session: session,
            sound: nil,
            playerError: URLError(.cannotOpenFile),
            reports: reports
        )
        controller.play()
        #expect(session.activateCount == 0)
        #expect(session.deactivateCount == 0)
        #expect(reports.value == [.playerCreationFailed])
    }

    @Test func playReturnsFalseCleansUpAndReports() {
        let session = FakeSession()
        let sound = FakeSound()
        sound.playResult = false
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: URL(fileURLWithPath: "/tmp/chime.wav"),
            session: session,
            sound: sound,
            reports: reports
        )
        controller.play()
        #expect(sound.playCount == 1)
        #expect(sound.stopCount == 1)
        #expect(session.activateCount == 1)
        #expect(session.deactivateCount == 1)
        #expect(reports.value == [.playbackRejected])
    }

    @Test func explicitStopReleasesExactlyOnce() {
        let session = FakeSession()
        let sound = FakeSound()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: URL(fileURLWithPath: "/tmp/chime.wav"),
            session: session,
            sound: sound,
            reports: reports
        )
        controller.play()
        #expect(session.activateCount == 1)
        controller.stop()
        controller.stop()
        sound.simulateFinish()
        #expect(sound.stopCount == 1)
        #expect(session.deactivateCount == 1)
        #expect(reports.value.isEmpty)
    }

    @Test func completionFinishReleasesExactlyOnce() {
        let session = FakeSession()
        let sound = FakeSound()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = makeController(
            resource: URL(fileURLWithPath: "/tmp/chime.wav"),
            session: session,
            sound: sound,
            reports: reports
        )
        controller.play()
        sound.simulateFinish()
        controller.stop()
        #expect(sound.stopCount == 1)
        #expect(session.deactivateCount == 1)
        #expect(reports.value.isEmpty)
    }

    @Test func failureCategoriesAreBounded() {
        #expect(CompletionChimeFailure.allCases.count == 4)
        #expect(Set(CompletionChimeFailure.allCases.map(\.rawValue)) == [
            "resourceMissing",
            "sessionActivationFailed",
            "playerCreationFailed",
            "playbackRejected",
        ])
    }
}
