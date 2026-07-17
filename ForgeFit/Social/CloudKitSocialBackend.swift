import CloudKit
import ForgeData
import Foundation

/// CloudKit public-database implementation of `SocialBackend`.
///
/// UNVERIFIABLE IN THE SIMULATOR — the iOS simulator has no iCloud account, so
/// this path is exercised on device; the simulator runs `MockSocialBackend`
/// (launch `--mock-social`). Before production, the record types below must be
/// created/deployed in the CloudKit Dashboard (Development → Production), with
/// the queried fields (`ownerID`, `publishedAt`, `handle`, `discoverable`,
/// `followerID`, `workoutID`, and the leaderboard stat fields) marked Queryable
/// / Sortable.
///
/// Health boundary: the only workout data transmitted is the pre-sanitized
/// `SharedWorkoutDTO` (as an opaque `payload` blob). This type never imports or
/// reads a `@Model` and never sees a health field.
public actor CloudKitSocialBackend: SocialBackend {
    private let container: CKContainer
    private var database: CKDatabase { container.publicCloudDatabase }
    private var cachedUserID: SocialUserID?

    private enum RecordType {
        static let profile = "UserProfile"
        static let handleClaim = "HandleClaim"
        static let workout = "SharedWorkout"
        static let follow = "Follow"
        static let like = "Like"
    }

    public init(containerIdentifier: String = "iCloud.org.xpetsllc.ForgeFit") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    // MARK: Identity

    public func currentUserID() async throws -> SocialUserID {
        if let cachedUserID { return cachedUserID }
        let id = SocialUserID(try await container.userRecordID().recordName)
        cachedUserID = id
        return id
    }

    // MARK: Profile

    public func upsertMyProfile(_ profile: SocialProfile) async throws {
        let record = try await fetchOrNew(RecordType.profile, name: profile.userID.rawValue)
        apply(profile, to: record)
        _ = try await database.save(record)
    }

    public func profile(for id: SocialUserID) async throws -> SocialProfile? {
        guard let record = try await fetch(RecordType.profile, name: id.rawValue) else { return nil }
        return profile(from: record)
    }

    public func profile(forHandle handle: String) async throws -> SocialProfile? {
        guard let claim = try await fetch(RecordType.handleClaim, name: SocialHandle.normalize(handle)),
              let ownerID = claim["ownerID"] as? String else { return nil }
        return try await profile(for: SocialUserID(ownerID))
    }

    public func claimHandle(_ handle: String) async throws -> Bool {
        let normalized = SocialHandle.normalize(handle)
        guard SocialHandle.isValid(normalized) else { throw SocialError.invalidHandle }
        let me = try await currentUserID()
        // Fetch-then-create: a small TOCTOU window exists on the public DB
        // (no cross-record transactions), acceptable for handle claiming.
        if let existing = try await fetch(RecordType.handleClaim, name: normalized) {
            return (existing["ownerID"] as? String) == me.rawValue
        }
        let record = CKRecord(recordType: RecordType.handleClaim, recordID: CKRecord.ID(recordName: normalized))
        record["ownerID"] = me.rawValue
        do {
            _ = try await database.save(record)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false // lost the race
        }
    }

    // MARK: Shared workouts

    public func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date) async throws {
        let me = try await currentUserID()
        let record = try await fetchOrNew(RecordType.workout, name: dto.id.uuidString)
        record["ownerID"] = me.rawValue
        record["publishedAt"] = publishedAt
        record["startedAt"] = dto.startedAt
        record["title"] = dto.title
        record["volumeKg"] = summary.volumeKg
        record["workingSets"] = Int64(summary.workingSets)
        record["reps"] = Int64(summary.reps)
        record["durationSeconds"] = Int64(summary.durationSeconds)
        record["exerciseCount"] = Int64(summary.exerciseCount)
        record["distanceMeters"] = summary.distanceMeters
        record["kind"] = summary.kind
        record["payload"] = try SocialWorkoutMapper.encode(dto)
        _ = try await database.save(record)
    }

    public func unpublishWorkout(id: UUID) async throws {
        do { try await database.deleteRecord(withID: CKRecord.ID(recordName: id.uuidString)) }
        catch let error as CKError where error.code == .unknownItem { /* already gone */ }
    }

    public func recentWorkouts(for id: SocialUserID, limit: Int) async throws -> [SocialWorkoutRef] {
        let query = CKQuery(recordType: RecordType.workout, predicate: NSPredicate(format: "ownerID == %@", id.rawValue))
        query.sortDescriptors = [NSSortDescriptor(key: "publishedAt", ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: limit)
        return results.compactMap { try? $0.1.get() }.compactMap { workoutRef(from: $0) }
    }

    public func workoutDetail(id: UUID) async throws -> SharedWorkoutDTO? {
        guard let record = try await fetch(RecordType.workout, name: id.uuidString),
              let payload = record["payload"] as? Data else { return nil }
        return try SocialWorkoutMapper.decode(payload)
    }

    // MARK: Follow graph

    public func follow(_ id: SocialUserID) async throws {
        let me = try await currentUserID()
        guard id != me else { return }
        let record = CKRecord(recordType: RecordType.follow, recordID: CKRecord.ID(recordName: followKey(me, id)))
        record["followerID"] = me.rawValue
        record["followeeID"] = id.rawValue
        _ = try await database.save(record)
    }

    public func unfollow(_ id: SocialUserID) async throws {
        let me = try await currentUserID()
        do { try await database.deleteRecord(withID: CKRecord.ID(recordName: followKey(me, id))) }
        catch let error as CKError where error.code == .unknownItem { }
    }

    public func following() async throws -> [SocialUserID] {
        let me = try await currentUserID()
        let query = CKQuery(recordType: RecordType.follow, predicate: NSPredicate(format: "followerID == %@", me.rawValue))
        let (results, _) = try await database.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
        return results.compactMap { try? $0.1.get() }.compactMap { ($0["followeeID"] as? String).map(SocialUserID.init) }
    }

    public func isFollowing(_ id: SocialUserID) async throws -> Bool {
        let me = try await currentUserID()
        return try await fetch(RecordType.follow, name: followKey(me, id)) != nil
    }

    // MARK: Likes

    public func setLike(_ liked: Bool, workoutID: UUID) async throws {
        let me = try await currentUserID()
        let name = likeKey(workoutID, me)
        if liked {
            let record = CKRecord(recordType: RecordType.like, recordID: CKRecord.ID(recordName: name))
            record["workoutID"] = workoutID.uuidString
            record["likerID"] = me.rawValue
            _ = try await database.save(record)
        } else {
            do { try await database.deleteRecord(withID: CKRecord.ID(recordName: name)) }
            catch let error as CKError where error.code == .unknownItem { }
        }
    }

    public func likeCount(workoutID: UUID) async throws -> Int {
        let query = CKQuery(recordType: RecordType.like, predicate: NSPredicate(format: "workoutID == %@", workoutID.uuidString))
        let (results, _) = try await database.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
        return results.count
    }

    public func hasLiked(workoutID: UUID) async throws -> Bool {
        let me = try await currentUserID()
        return try await fetch(RecordType.like, name: likeKey(workoutID, me)) != nil
    }

    // MARK: Leaderboards

    public func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) async throws -> [SocialLeaderboardEntry] {
        let field = fieldKey(for: metric)
        let profiles: [SocialProfile]
        switch scope {
        case .global:
            let query = CKQuery(recordType: RecordType.profile, predicate: NSPredicate(format: "discoverable == 1"))
            query.sortDescriptors = [NSSortDescriptor(key: field, ascending: false)]
            let (results, _) = try await database.records(matching: query, resultsLimit: limit)
            profiles = results.compactMap { try? $0.1.get() }.compactMap { profile(from: $0) }
        case .friends:
            var ids = try await following()
            ids.append(try await currentUserID())
            var fetched: [SocialProfile] = []
            for id in ids { if let p = try await profile(for: id) { fetched.append(p) } }
            profiles = fetched.sorted { value($0, metric) > value($1, metric) }
        }
        return profiles.prefix(limit).enumerated().map {
            SocialLeaderboardEntry(profile: $0.element, value: value($0.element, metric), rank: $0.offset + 1)
        }
    }

    // MARK: - CKRecord mapping

    private func apply(_ profile: SocialProfile, to record: CKRecord) {
        record["handle"] = profile.handle
        record["displayName"] = profile.displayName
        record["totalXP"] = Int64(profile.totalXP)
        record["workoutCount"] = Int64(profile.workoutCount)
        record["lifetimeHours"] = profile.lifetimeHours
        record["visibility"] = profile.visibility.rawValue
        record["discoverable"] = Int64(profile.discoverable ? 1 : 0)
        record["updatedAt"] = profile.updatedAt
        record["lifetimeVolumeKg"] = profile.stats.lifetimeVolumeKg
        record["bestE1RMKg"] = profile.stats.bestE1RMKg
        record["cardioDistanceMeters"] = profile.stats.cardioDistanceMeters
        record["cardioMinutes"] = profile.stats.cardioMinutes
        record["yogaMinutes"] = profile.stats.yogaMinutes
    }

    private func profile(from record: CKRecord) -> SocialProfile? {
        guard let handle = record["handle"] as? String,
              let displayName = record["displayName"] as? String else { return nil }
        return SocialProfile(
            userID: SocialUserID(record.recordID.recordName),
            handle: handle,
            displayName: displayName,
            totalXP: Int(record["totalXP"] as? Int64 ?? 0),
            workoutCount: Int(record["workoutCount"] as? Int64 ?? 0),
            lifetimeHours: record["lifetimeHours"] as? Double ?? 0,
            stats: SocialStats(
                lifetimeVolumeKg: record["lifetimeVolumeKg"] as? Double ?? 0,
                bestE1RMKg: record["bestE1RMKg"] as? Double ?? 0,
                cardioDistanceMeters: record["cardioDistanceMeters"] as? Double ?? 0,
                cardioMinutes: record["cardioMinutes"] as? Double ?? 0,
                yogaMinutes: record["yogaMinutes"] as? Double ?? 0
            ),
            visibility: (record["visibility"] as? String).flatMap(SocialVisibility.init) ?? .everyone,
            discoverable: (record["discoverable"] as? Int64 ?? 1) == 1,
            updatedAt: record["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func workoutRef(from record: CKRecord) -> SocialWorkoutRef? {
        guard let ownerID = record["ownerID"] as? String,
              let startedAt = record["startedAt"] as? Date,
              let publishedAt = record["publishedAt"] as? Date,
              let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        let summary = SharedWorkoutSummary(
            volumeKg: record["volumeKg"] as? Double ?? 0,
            workingSets: Int(record["workingSets"] as? Int64 ?? 0),
            reps: Int(record["reps"] as? Int64 ?? 0),
            durationSeconds: Int(record["durationSeconds"] as? Int64 ?? 0),
            exerciseCount: Int(record["exerciseCount"] as? Int64 ?? 0),
            distanceMeters: record["distanceMeters"] as? Double ?? 0,
            kind: record["kind"] as? String ?? "strength"
        )
        return SocialWorkoutRef(id: id, owner: SocialUserID(ownerID), title: record["title"] as? String, startedAt: startedAt, publishedAt: publishedAt, summary: summary)
    }

    // MARK: - Helpers

    private func fetch(_ type: String, name: String) async throws -> CKRecord? {
        do { return try await database.record(for: CKRecord.ID(recordName: name)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func fetchOrNew(_ type: String, name: String) async throws -> CKRecord {
        try await fetch(type, name: name) ?? CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
    }

    private func followKey(_ follower: SocialUserID, _ followee: SocialUserID) -> String {
        "\(follower.rawValue)__\(followee.rawValue)"
    }
    private func likeKey(_ workoutID: UUID, _ liker: SocialUserID) -> String {
        "\(workoutID.uuidString)__\(liker.rawValue)"
    }

    private func fieldKey(for metric: SocialLeaderboardMetric) -> String {
        switch metric {
        case .totalVolume: "lifetimeVolumeKg"
        case .bestE1RM: "bestE1RMKg"
        case .cardioDistance: "cardioDistanceMeters"
        case .cardioMinutes: "cardioMinutes"
        case .yogaMinutes: "yogaMinutes"
        case .xp: "totalXP"
        }
    }

    private func value(_ profile: SocialProfile, _ metric: SocialLeaderboardMetric) -> Double {
        switch metric {
        case .totalVolume: profile.stats.lifetimeVolumeKg
        case .bestE1RM: profile.stats.bestE1RMKg
        case .cardioDistance: profile.stats.cardioDistanceMeters
        case .cardioMinutes: profile.stats.cardioMinutes
        case .yogaMinutes: profile.stats.yogaMinutes
        case .xp: Double(profile.totalXP)
        }
    }
}
