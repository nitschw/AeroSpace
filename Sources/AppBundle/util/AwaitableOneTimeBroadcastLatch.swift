import Common
import Foundation

actor AwaitableOneTimeBroadcastLatch {
    private var done = false
    private var awaiters: [UniqueToken: Nullable<CheckedContinuation<(), any Error>>] = [:]

    /// Bounded wait: gives up (without error) after the timeout — the
    /// caller proceeds and whatever the latch guards completes in its own
    /// time. For registration paths a stuck latch must never stall the
    /// waiter's whole world.
    func await(timeoutSeconds: Double) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.await(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func await() async throws {
        try checkCancellation()
        if done { return }

        let id = UniqueToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(), any Error>) in
                switch awaiters.removeValue(forKey: id) {
                    case let awaiter?:
                        check(awaiter.isNull)
                        cont.resume(throwing: CancellationError())
                    case nil where done: cont.resume()
                    case nil: awaiters[id] = .just(cont)
                }
            }
        } onCancel: {
            Task.startUnstructured { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UniqueToken) {
        switch awaiters.removeValue(forKey: id) {
            case let awaiter?: awaiter.valueOrNil.orDie().resume(throwing: CancellationError())
            case nil where !done:
                // Indicate to 'await' that the client should be cancelled right away when it suspends
                awaiters[id] = .null
            case nil: break
        }
    }

    func signalToAll() {
        done = true
        for (_, awaiter) in awaiters {
            awaiter.valueOrNil?.resume()
        }
        awaiters = [:]
    }
}
