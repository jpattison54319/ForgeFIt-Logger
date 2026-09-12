import Foundation
import Testing
@testable import ForgeCore

struct WatchDeliveryTests {
    @Test func startsExpireAndOnlyStartCommandsAreAccepted() throws {
        let now = Date()
        for command in [WatchCommand.startEmpty, .startRoutine(routineID: UUID()), .startNextTrackedWorkout] {
            let request = WatchStartRequest(issuedAt: now, command: command)
            #expect(request.isValid(at: now.addingTimeInterval(7.9)))
            #expect(!request.isValid(at: now.addingTimeInterval(8)))
            #expect(!request.isValid(at: now.addingTimeInterval(-3)))
            let data = try #require(WatchWire.encode(request))
            let decoded = try #require(WatchWire.decode(WatchStartRequest.self, from: data))
            #expect(decoded.id == request.id)
            #expect(decoded.isValid(at: now))
        }
        #expect(!WatchStartRequest(command: .requestContext).isValid(at: now))
        #expect(WatchCommand.workoutFinished(workoutID: UUID()).isPhoneTerminalNotice)
        #expect(!WatchCommand.startEmpty.isPhoneTerminalNotice)
    }

    @MainActor @Test func firstHeartRateIsImmediateEvenAfterAnEnergyPacket() {
        var packets: [WatchLiveMetrics] = []
        let coalescer = WatchMetricsCoalescer { packets.append($0) }
        defer { coalescer.reset() }
        coalescer.submit(WatchLiveMetrics(activeEnergyKcal: 1))
        coalescer.submit(WatchLiveMetrics(heartRate: 110))
        #expect(packets.count == 2)
        #expect(packets.last?.heartRate == 110)
    }

    @MainActor @Test func suppressedReadingsFlushWithoutAnotherSensorCallback() async throws {
        var packets: [WatchLiveMetrics] = []
        let coalescer = WatchMetricsCoalescer(heartRateInterval: 0.05, otherMetricsInterval: 0.2) { packets.append($0) }
        defer { coalescer.reset() }
        coalescer.submit(WatchLiveMetrics(heartRate: 110))
        for bpm in 111...150 { coalescer.submit(WatchLiveMetrics(heartRate: bpm)) }
        #expect(packets.count == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(packets.count == 2)
        #expect(packets.last?.heartRate == 150)
    }

    @MainActor @Test func unchangedHeartRateWithANewSampleUsesTheFastLane() async throws {
        var packets: [WatchLiveMetrics] = []
        let coalescer = WatchMetricsCoalescer(heartRateInterval: 0.05, otherMetricsInterval: 1) { packets.append($0) }
        defer { coalescer.reset() }
        let now = Date()
        coalescer.submit(WatchLiveMetrics(heartRate: 110, asOf: now.addingTimeInterval(-1)))
        coalescer.submit(WatchLiveMetrics(heartRate: 110, asOf: now))
        try await Task.sleep(for: .milliseconds(150))
        #expect(packets.count == 2)
        #expect(packets.last?.asOf == now)
    }

    @MainActor @Test func forceFlushAndSessionResetCancelThePendingPacket() async throws {
        var packets: [WatchLiveMetrics] = []
        let coalescer = WatchMetricsCoalescer(heartRateInterval: 0.05) { packets.append($0) }
        defer { coalescer.reset() }
        coalescer.submit(WatchLiveMetrics(heartRate: 100))
        coalescer.submit(WatchLiveMetrics(heartRate: 101))
        coalescer.submit(WatchLiveMetrics(heartRate: 102), force: true)
        coalescer.submit(WatchLiveMetrics(heartRate: 103))
        coalescer.reset()
        try await Task.sleep(for: .milliseconds(150))
        #expect(packets.map(\.heartRate) == [100, 102])
        coalescer.submit(WatchLiveMetrics(heartRate: 104))
        #expect(packets.last?.heartRate == 104)
    }

    @MainActor @Test func aSampleThatExpiresWhilePendingIsNotPublishedAsLive() async throws {
        var packets: [WatchLiveMetrics] = []
        var now = Date()
        let coalescer = WatchMetricsCoalescer(heartRateInterval: 0.05, now: { now }) { packets.append($0) }
        defer { coalescer.reset() }
        coalescer.submit(WatchLiveMetrics(heartRate: 100, asOf: now.addingTimeInterval(-1)))
        coalescer.submit(WatchLiveMetrics(heartRate: 101, asOf: now))
        now = now.addingTimeInterval(16)
        try await Task.sleep(for: .milliseconds(150))
        #expect(packets.count == 2)
        #expect(packets.last?.heartRate == nil)
    }

    @Test func orderingRejectsDuplicatesOlderPacketsExpiredAndPartialHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), workout = UUID(), stream = UUID()
        var ordering = WatchMetricsOrdering()
        let latest = WatchLiveMetrics(workoutID: workout, heartRate: 125, asOf: now,
                                      streamID: stream, sequence: 2, sentAt: now)
        #expect({ ordering.accept(latest, at: now) }())
        #expect({ !ordering.accept(latest, at: now) }())
        var old = latest
        old.sequence = 1
        old.heartRate = 100
        #expect({ !ordering.accept(old, at: now) }())
        old.sequence = 3
        old.asOf = now.addingTimeInterval(-1)
        #expect({ !ordering.accept(old, at: now) }())
        var partial = latest
        partial.streamID = nil
        #expect(!WatchMetricsOrdering().mayAccept(partial, at: now))
        #expect(!WatchMetricsOrdering().mayAccept(latest, at: now.addingTimeInterval(16)))
        #expect(!WatchMetricsOrdering().mayAccept(latest, at: now.addingTimeInterval(-3)))
        let encoded = try #require(WatchWire.encode(latest))
        #expect(WatchWire.decode(WatchLiveMetrics.self, from: encoded) == latest)
    }

    @Test func legacyAndRestartedStreamsCannotReplaceNewerReadings() {
        let now = Date(), workout = UUID()
        var ordering = WatchMetricsOrdering()
        let legacy = WatchLiveMetrics(workoutID: workout, heartRate: 100, asOf: now.addingTimeInterval(-2))
        #expect({ ordering.accept(legacy, at: now) }())
        #expect({ !ordering.accept(legacy, at: now) }())
        let modern = WatchLiveMetrics(workoutID: workout, heartRate: 101, asOf: now.addingTimeInterval(-1),
                                      streamID: UUID(), sequence: 80, sentAt: now.addingTimeInterval(-1))
        #expect({ ordering.accept(modern, at: now) }())
        #expect({ !ordering.accept(WatchLiveMetrics(workoutID: workout, heartRate: 102, asOf: now), at: now) }())
        let restarted = WatchLiveMetrics(workoutID: workout, heartRate: 103, asOf: now,
                                         streamID: UUID(), sequence: 1, sentAt: now)
        #expect({ ordering.accept(restarted, at: now) }())
        #expect({ !ordering.accept(modern, at: now) }())
    }
}
