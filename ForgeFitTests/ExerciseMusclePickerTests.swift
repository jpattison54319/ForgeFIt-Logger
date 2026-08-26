import Foundation
import ForgeCore
import Testing
@testable import ForgeFit

@MainActor
struct ExerciseMusclePickerTests {
    @Test func pickerGroupsAndChildrenAreAlphabetical() {
        let entries = ExerciseCatalog.selectableMuscleHierarchy
        let groupNames = entries.map { MuscleTaxonomy.displayName($0.group) }
        #expect(groupNames == groupNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })

        for entry in entries {
            let childNames = entry.children.map(MuscleTaxonomy.displayName)
            #expect(childNames == childNames.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            })
        }
    }

    @Test func hipsIsNavigationOnlyAndSpineIsNotSelectable() {
        let hips = ExerciseCatalog.selectableMuscleHierarchy.first { $0.group == "hips" }
        #expect(hips?.allowsGroupSelection == false)
        #expect(hips?.children == ["abductors", "adductors", "glutes", "hip flexors"])
        #expect(ExerciseCatalog.muscleGroups.contains("hips") == false)
        #expect(ExerciseCatalog.muscleGroups.contains("spine") == false)
        #expect(ExerciseCatalog.muscleGroups.contains("hip flexors"))
        #expect(ExerciseCatalog.selectableMuscleGroups.contains("cardiovascular") == false)
        #expect(ExerciseCatalog.muscleHierarchy.contains { $0.group == "cardiovascular" })
        #expect(ExerciseCatalog.selectableMuscleHierarchy.contains { $0.group == "cardiovascular" } == false)
    }

    @Test func legacyRegionsRemainReadableWithoutReturningToThePicker() {
        #expect(ExerciseCatalog.recognizedMuscleTags.contains("hips"))
        #expect(ExerciseCatalog.recognizedMuscleTags.contains("spine"))
    }
}
