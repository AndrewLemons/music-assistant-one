import Foundation
import Observation

/// One ordered writer per player. A newer value replaces queued work, never an in-flight write.
@MainActor @Observable
public final class VolumeControl {
    public private(set) var pending: [String: Double] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var generation = UUID()

    public init() {}

    public func set(
        _ value: Double,
        playerID: String,
        send: @escaping @MainActor (Double) async throws -> Void,
        onError: @escaping @MainActor (any Error) -> Void
    ) {
        guard value.isFinite else { return }
        pending[playerID] = min(100, max(0, value)).rounded()
        guard workers[playerID] == nil else { return }
        let epoch = generation
        workers[playerID] = Task { [weak self] in
            // Coalesce slider, keyboard and accessibility adjustments alike.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            while let requested = pending[playerID], generation == epoch, !Task.isCancelled {
                do { try await send(requested) }
                catch {
                    guard generation == epoch, !Task.isCancelled else { return }
                    onError(error)
                }
                guard generation == epoch, !Task.isCancelled else { return }
                if pending[playerID] == requested {
                    pending[playerID] = nil
                }
            }
            if generation == epoch {
                workers[playerID] = nil
            }
        }
    }

    public func cancel() {
        generation = UUID()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        pending.removeAll()
    }
}
