import ForgeCore
import HealthKit

/// Retains HealthKit's mirrored session while Watch owns the primary
/// recorder. Workout identity and saves still belong to WatchLink.
@MainActor
final class WatchWorkoutMirror: NSObject, HKWorkoutSessionDelegate {
    static let shared = WatchWorkoutMirror()

    private var session: HKWorkoutSession?
    private var snapshotSendTask: Task<Void, Never>?
    private var pendingSnapshot: Data?

    func attach(_ session: HKWorkoutSession) {
        guard session !== self.session else { return }
        clearSession()
        self.session = session
        session.delegate = self
    }

    func sendSnapshot(_ data: Data, metadata: WatchSyncMetadata) {
        guard let session,
              let packet = WatchMirroringPacket.snapshot(data, metadata).encoded() else { return }
        pendingSnapshot = packet
        guard snapshotSendTask == nil else { return }
        snapshotSendTask = Task {
            while !Task.isCancelled, let next = pendingSnapshot {
                pendingSnapshot = nil
                try? await session.sendToRemoteWorkoutSession(data: next)
            }
            if !Task.isCancelled { snapshotSendTask = nil }
        }
    }

    private func clearSession() {
        snapshotSendTask?.cancel()
        snapshotSendTask = nil
        pendingSnapshot = nil
        session?.delegate = nil
        session = nil
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        guard toState == .ended || toState == .stopped else { return }
        discard(workoutSession)
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        discard(workoutSession)
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        discard(workoutSession)
    }

    private nonisolated func discard(_ workoutSession: HKWorkoutSession) {
        Task { @MainActor in
            if session === workoutSession { clearSession() }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            for item in data {
                guard session === workoutSession else { return }
                switch WatchMirroringPacket.decode(item) {
                case .syncRequest(let request):
                    let reply = WatchLink.shared.makeSyncReply(to: request)
                    if let packet = WatchMirroringPacket.syncReply(reply).encoded() {
                        try? await workoutSession.sendToRemoteWorkoutSession(data: packet)
                    }
                case .metrics(let metrics):
                    WatchLink.shared.handle(.liveMetrics(metrics))
                default:
                    break
                }
            }
        }
    }
}
