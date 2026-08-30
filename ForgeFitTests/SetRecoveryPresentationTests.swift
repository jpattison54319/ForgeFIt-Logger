import Foundation
import Testing
@testable import ForgeFit

struct SetRecoveryPresentationTests {
    private let bench = UUID(uuidString: "00000000-0000-7000-8000-00000000EA01")!
    private let row = UUID(uuidString: "00000000-0000-7000-8000-00000000EB02")!
    private let s1 = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!
    private let s2 = UUID(uuidString: "00000000-0000-7000-8000-000000000002")!
    private let s3 = UUID(uuidString: "00000000-0000-7000-8000-000000000003")!
    private let s4 = UUID(uuidString: "00000000-0000-7000-8000-000000000004")!

    private func ref(
        _ exercise: UUID,
        _ name: String,
        _ label: String,
        order: Int = 0
    ) -> SetRecoveryPresentation.SetRef {
        SetRecoveryPresentation.SetRef(
            exerciseRowID: exercise,
            exerciseName: name,
            exerciseOrder: order,
            label: label
        )
    }

    private func point(_ ids: [UUID], drop: Int? = 20, rise: Int? = nil) -> SetRecoveryPoint {
        SetRecoveryPoint(
            setIDs: ids,
            peakHR: 165,
            recoveryBPM: drop,
            withinUnitRise: rise,
            restObservedSeconds: drop == nil ? nil : 90
        )
    }

    @Test func supersetRoundsShareOneHeadingAndAreNumberedAsRounds() {
        let refs = [
            s1: ref(bench, "Bench Press", "1"),
            s2: ref(row, "Barbell Row", "1", order: 1),
            s3: ref(bench, "Bench Press", "2"),
            s4: ref(row, "Barbell Row", "2", order: 1),
        ]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1, s2], rise: 14), point([s3, s4], rise: 11)],
            refs: refs
        )

        #expect(sections.count == 1)
        #expect(sections[0].title == "Bench Press + Barbell Row")
        #expect(sections[0].rows.map(\.label) == ["R1", "R2"])
    }

    @Test func straightSetsKeepTheirLogBadgeUnderTheExerciseName() {
        let refs = [s1: ref(bench, "Bench Press", "1"), s2: ref(bench, "Bench Press", "2W")]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1]), point([s2])],
            refs: refs
        )

        #expect(sections.count == 1)
        #expect(sections[0].title == "Bench Press")
        #expect(sections[0].rows.map(\.label) == ["1", "2W"])
    }

    @Test func dropChainKeepsTheBaseSetBadgeWithAChevron() {
        let refs = [s1: ref(bench, "Bench Press", "3"), s2: ref(bench, "Bench Press", "4")]

        let sections = SetRecoveryPresentation.sections(points: [point([s1, s2], rise: 9)], refs: refs)

        #expect(sections[0].title == "Bench Press")
        #expect(sections[0].rows.map(\.label) == ["3▾"])
    }

    @Test func changingExercisesStartsANewSection() {
        let refs = [
            s1: ref(bench, "Bench Press", "1"),
            s2: ref(bench, "Bench Press", "1"),
            s3: ref(row, "Barbell Row", "1", order: 1),
        ]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1, s2], rise: 8), point([s3])],
            refs: refs
        )

        #expect(sections.map(\.title) == ["Bench Press", "Barbell Row"])
        #expect(sections[1].rows.map(\.label) == ["1"])
    }

    @Test func roundNumberingRestartsPerSection() {
        let other = UUID(uuidString: "00000000-0000-7000-8000-00000000EC03")!
        let s5 = UUID(uuidString: "00000000-0000-7000-8000-000000000005")!
        let s6 = UUID(uuidString: "00000000-0000-7000-8000-000000000006")!
        let refs = [
            s1: ref(bench, "Bench Press", "1"),
            s2: ref(row, "Barbell Row", "1", order: 1),
            s3: ref(bench, "Bench Press", "2"),
            s4: ref(row, "Barbell Row", "2", order: 1),
            s5: ref(other, "Curl", "1", order: 2),
            s6: ref(row, "Barbell Row", "3", order: 1),
        ]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1, s2]), point([s3, s4]), point([s5, s6])],
            refs: refs
        )

        #expect(sections.count == 2)
        #expect(sections[0].rows.map(\.label) == ["R1", "R2"])
        #expect(sections[1].rows.map(\.label) == ["R1"])
    }

    @Test func pointsWithAnUnknownSetAreDropped() {
        let unknown = UUID(uuidString: "00000000-0000-7000-8000-0000000000FF")!
        let refs = [s1: ref(bench, "Bench Press", "1")]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1, unknown]), point([s1])],
            refs: refs
        )

        #expect(sections.count == 1)
        #expect(sections[0].rows.count == 1)
        #expect(sections[0].rows[0].label == "1")
    }

    @Test func headingIgnoresWhichLegWasFinishedFirst() {
        // The warm-up round opened with the second exercise. Ordering the
        // heading by completion would flip it, split one superset into two
        // sections, and restart round numbering at R1 twice.
        let refs = [
            s1: ref(row, "Barbell Row", "W", order: 1),
            s2: ref(bench, "Bench Press", "W", order: 0),
            s3: ref(bench, "Bench Press", "1", order: 0),
            s4: ref(row, "Barbell Row", "1", order: 1),
        ]

        let sections = SetRecoveryPresentation.sections(
            points: [point([s1, s2]), point([s3, s4])],
            refs: refs
        )

        #expect(sections.count == 1)
        #expect(sections[0].title == "Bench Press + Barbell Row")
        #expect(sections[0].rows.map(\.label) == ["R1", "R2"])
    }

    @Test func noPointsProducesNoSections() {
        #expect(SetRecoveryPresentation.sections(points: [], refs: [:]).isEmpty)
    }
}
