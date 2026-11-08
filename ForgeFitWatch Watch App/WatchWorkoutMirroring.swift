import ForgeCore
import HealthKit

/// An additional live lane for a running HealthKit session when
/// WatchConnectivity cannot deliver immediate messages.
@MainActor
final class WatchWorkoutMirroring {
    private var session: HKWorkoutSession?
    private var isConnected = false
    private var connectionTask: Task<Void, Never>?
    private var metricsSendTask: Task<Void, Never>?
    private var inFlightSyncID: UUID?
    var onConnect: (() -> Void)?
    var onPacket: ((WatchMirroringPacket) -> Void)?

    func connect(_ session: HKWorkoutSession) {
        guard self.session !== session else { return }
        clear()
        self.session = session
        connectionTask = Task { [weak self] in
            for delay in [0, 2, 6] {
                do {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try await session.startMirroringToCompanionDevice()
                    guard !Task.isCancelled, let self, self.session === session else { return }
                    self.connectionTask = nil
                    self.isConnected = true
                    self.onConnect?()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            self?.connectionTask = nil
        }
    }

    func clear() {
        connectionTask?.cancel()
        connectionTask = nil
        metricsSendTask?.cancel()
        metricsSendTask = nil
        inFlightSyncID = nil
        session = nil
        isConnected = false
    }

    func disconnected(_ session: HKWorkoutSession) {
        guard self.session === session else { return }
        clear()
    }

    func receive(_ data: [Data], from session: HKWorkoutSession) {
        guard self.session === session else { return }
        for item in data {
            if let packet = WatchMirroringPacket.decode(item) { onPacket?(packet) }
        }
    }

    func requestSync(_ request: WatchSyncRequest) async -> Bool {
        guard isConnected, inFlightSyncID == nil, let session,
              let data = WatchMirroringPacket.syncRequest(request).encoded() else { return false }
        inFlightSyncID = request.id
        defer { if inFlightSyncID == request.id { inFlightSyncID = nil } }
        do {
            try await session.sendToRemoteWorkoutSession(data: data)
            return self.session === session
        } catch {
            return false
        }
    }

    func sendMetrics(_ metrics: WatchLiveMetrics) {
        guard isConnected, let session, metricsSendTask == nil,
              let data = WatchMirroringPacket.metrics(metrics).encoded() else { return }
        metricsSendTask = Task { [weak self] in
            try? await session.sendToRemoteWorkoutSession(data: data)
            if !Task.isCancelled { self?.metricsSendTask = nil }
        }
    }
}
