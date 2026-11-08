import ForgeCore
import Observation
import SwiftUI

/// One work countdown survives logger minimization and lazy row recycling.
/// Only the timer display ticks. Completion uses a monotonic deadline so
/// clock changes and time spent paused never add to the performed hold.
@MainActor
@Observable
final class StrengthHoldTimer {
    static let shared = StrengthHoldTimer()

    struct Hold {
        let workoutID: UUID
        let exerciseID: UUID
        let setID: UUID
        let seconds: Int
        var elapsed: Duration = .zero
        var runningSince: ContinuousClock.Instant?
        var endsAt: Date?

        var isPaused: Bool { runningSince == nil }

        func elapsed(at now: ContinuousClock.Instant) -> Duration {
            let running = runningSince.map { max(.zero, $0.duration(to: now)) } ?? .zero
            return min(.seconds(seconds), elapsed + running)
        }

        func remaining(at now: ContinuousClock.Instant) -> Int {
            seconds - Int(elapsed(at: now).components.seconds)
        }
    }

    private(set) var hold: Hold?
    @ObservationIgnored private let clockNow: () -> ContinuousClock.Instant
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var onFinish: ((Int, Date) -> Void)?

    init(clockNow: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.clockNow = clockNow
    }

    func start(
        workoutID: UUID, exerciseID: UUID, setID: UUID, seconds: Int,
        onFinish: @escaping (Int, Date) -> Void
    ) {
        guard hold == nil, let seconds = StrengthHold.validSeconds(seconds) else { return }
        self.onFinish = onFinish
        hold = Hold(workoutID: workoutID, exerciseID: exerciseID, setID: setID, seconds: seconds)
        resume(setID: setID)
    }

    func pause(setID: UUID) {
        guard var hold, hold.setID == setID, !hold.isPaused else { return }
        hold.elapsed = hold.elapsed(at: clockNow())
        if hold.elapsed >= .seconds(hold.seconds) {
            finish(setID: setID)
            return
        }
        deadlineTask?.cancel()
        deadlineTask = nil
        hold.runningSince = nil
        hold.endsAt = nil
        self.hold = hold
    }

    func resume(setID: UUID) {
        guard var hold, hold.setID == setID, hold.isPaused else { return }
        let now = clockNow()
        let remaining = Duration.seconds(hold.seconds) - hold.elapsed
        let deadline = now.advanced(by: remaining)
        hold.runningSince = now
        hold.endsAt = Date.now.addingTimeInterval(
            Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        )
        self.hold = hold
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.finish(setID: setID)
        }
    }

    func finish(setID: UUID) {
        guard let hold, hold.setID == setID else { return }
        let elapsed = hold.elapsed(at: clockNow())
        let endedAt = elapsed >= .seconds(hold.seconds) ? (hold.endsAt ?? .now) : .now
        let finish = onFinish
        cancel()
        guard elapsed > .zero else { return }
        finish?(max(1, Int(elapsed.components.seconds)), endedAt)
    }

    func cancel(workoutID: UUID? = nil, exerciseID: UUID? = nil, setID: UUID? = nil) {
        guard let hold,
              workoutID == nil || hold.workoutID == workoutID,
              exerciseID == nil || hold.exerciseID == exerciseID,
              setID == nil || hold.setID == setID else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        onFinish = nil
        self.hold = nil
    }
}
