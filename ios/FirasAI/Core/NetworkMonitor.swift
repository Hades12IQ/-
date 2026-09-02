import Foundation
import Network
import Observation

/// Reachability, published on the main actor.
///
/// The path monitor runs on its own queue; every update hops to the main actor before
/// it is published. `isOnline` starts optimistic (`true`) and is corrected by the first
/// real path update, so nothing on the first frame waits for the network stack.
@MainActor
@Observable
final class NetworkMonitor {

    private(set) var isOnline: Bool = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "org.firasai.network-monitor", qos: .utility)
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var receivedFirstUpdate = false

    /// A new stream per consumer. The current value is delivered immediately, then every change.
    var updates: AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
            continuation.yield(self.isOnline)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in
                self?.apply(online)
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Private

    private func apply(_ online: Bool) {
        let isFirst = !receivedFirstUpdate
        receivedFirstUpdate = true
        guard isFirst || online != isOnline else { return }
        isOnline = online
        for continuation in continuations.values {
            continuation.yield(online)
        }
    }
}
