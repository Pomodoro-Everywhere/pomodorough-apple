import Foundation

@MainActor
struct TimerCompletionScheduler {
    private let sleep: @MainActor (Duration) async throws -> Void

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }) {
        self.sleep = sleep
    }

    func schedule(
        after delay: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [sleep] in
            guard !Task.isCancelled else { return }
            do {
                try await sleep(.seconds(max(0.001, delay)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            completion()
        }
    }
}
