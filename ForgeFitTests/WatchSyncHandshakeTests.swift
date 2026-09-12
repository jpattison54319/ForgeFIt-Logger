import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WatchSyncHandshakeTests {
    @Test func aBackgroundConfiguredLinkAnswersWithTheCommittedGraph() throws {
        let (container, context) = try TestStore.make()
        let workout = WorkoutModel(userID: UUID(), title: "Recovery fixture", startedAt: .now)
        context.insert(workout)
        try context.save()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let request = WatchSyncRequest()
        let reply = link.makeSyncReply(to: request)
        #expect(reply.requestID == request.id)
        #expect(reply.issue == nil)
        let data = try #require(reply.contextData)
        let snapshot = try #require(WatchWire.decode(WatchAppContext.self, from: data))
        #expect(snapshot.workout?.workoutID == workout.id)
        #expect(reply.metadata?.workoutID == workout.id)
    }

    @Test func finishedStateIsReadThroughAFreshContextAndRevisionIncreases() throws {
        let (container, context) = try TestStore.make()
        let id = UUID()
        let workout = WorkoutModel(id: id, userID: UUID(), startedAt: .now)
        context.insert(workout)
        try context.save()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let first = link.makeSyncReply(to: WatchSyncRequest())
        let isolated = ModelContext(container)
        let row = try #require(isolated.fetch(FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })).first)
        row.endedAt = .now
        try isolated.save()
        let second = link.makeSyncReply(to: WatchSyncRequest())
        #expect(first.metadata?.workoutID == id)
        #expect(second.metadata?.workoutID == nil)
        let firstMetadata = try #require(first.metadata)
        let secondMetadata = try #require(second.metadata)
        #expect(secondMetadata.revision > firstMetadata.revision)
        #expect(second.metadata?.epoch == first.metadata?.epoch)
    }

    @Test func resetNoticeSurvivesUnavailableTransportAndARecreatedLink() throws {
        let suite = "WatchResetOutbox-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline = WatchLink(resetDefaults: defaults, resetNoticeSender: { _ in false })
        offline.resetWatchState()
        let pending = try #require(defaults.stringArray(forKey: "watch.pending-reset-epochs.v1"))
        #expect(pending.count == 1)
        var queued: [String] = []
        let recovered = WatchLink(resetDefaults: defaults, resetNoticeSender: { epoch in queued.append(epoch); return true })
        recovered.flushPendingResetNotices()
        recovered.flushPendingResetNotices()
        #expect(queued == pending)
        #expect(defaults.object(forKey: "watch.pending-reset-epochs.v1") == nil)
    }

    @Test func storageAndProtocolFailuresAreExplicitInsteadOfFakeIdleSnapshots() {
        let link = WatchLink()
        var request = WatchSyncRequest()
        #expect(link.makeSyncReply(to: request).issue == .storageUnavailable)
        request.protocolVersion = 999
        let reply = link.makeSyncReply(to: request)
        #expect(reply.issue == .incompatible)
        #expect(reply.contextData == nil)
    }
}
