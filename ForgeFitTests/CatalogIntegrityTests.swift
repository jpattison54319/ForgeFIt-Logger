import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

/// Closes a documented test gap: nothing previously decoded the REAL bundled
/// `routine_templates.json` / `routine_programs.json` and asserted their
/// cross-references actually resolve. Every other catalog test builds its
/// own tiny in-memory templates instead of touching the shipped files.
@MainActor
struct CatalogIntegrityTests {
    @Test func noDuplicateTemplateIDs() {
        let templates = RoutineTemplateCatalog.load()
        #expect(!templates.isEmpty)
        let ids = templates.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func noDuplicateProgramIDs() {
        let programs = RoutineTemplateCatalog.loadPrograms()
        #expect(!programs.isEmpty)
        let ids = programs.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyProgramRoutineIDResolvesToATemplate() {
        let templates = RoutineTemplateCatalog.load()
        let templateIDs = Set(templates.map(\.id))
        let programs = RoutineTemplateCatalog.loadPrograms()

        for program in programs {
            #expect(!program.routineIDs.isEmpty, "\(program.id) has no routineIDs")
            for routineID in program.routineIDs {
                #expect(templateIDs.contains(routineID), "\(program.id) references unresolved routine template '\(routineID)'")
            }
        }
    }

    @Test func everyProgramScheduleEntryResolvesToARoutineID() {
        let programs = RoutineTemplateCatalog.loadPrograms()
        for program in programs {
            guard let schedule = program.schedule else { continue }
            let dayIDs = Set(program.routineIDs)
            for step in schedule {
                #expect(dayIDs.contains(step), "\(program.id) schedule references '\(step)', not one of its own routineIDs")
            }
        }
    }

    @Test func everyProgramHasAValidFocus() {
        let programs = RoutineTemplateCatalog.loadPrograms()
        for program in programs {
            #expect(ProgramFocus(rawValue: program.focus) != nil, "\(program.id) has unrecognized focus '\(program.focus)'")
        }
    }
}
