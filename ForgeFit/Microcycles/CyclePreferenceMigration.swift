import Foundation

enum CyclePreferenceMigration {
    static let activeMicrocycleKey = "activeMicrocycleFolderID.v2"
    static let activeMesocycleKey = "activeMesocycleFolderID.v2"
    static let migrationKey = "cycleTerminologyMigration.v2.done"

    static func migrate(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        if defaults.string(forKey: activeMicrocycleKey) == nil,
           let oldMicrocycle = defaults.string(forKey: "activeMesoFolderID") {
            defaults.set(oldMicrocycle, forKey: activeMicrocycleKey)
        }
        if defaults.string(forKey: activeMesocycleKey) == nil,
           let oldMesocycle = defaults.string(forKey: "activeMacroFolderID") {
            defaults.set(oldMesocycle, forKey: activeMesocycleKey)
        }
        defaults.removeObject(forKey: "activeMesoFolderID")
        defaults.removeObject(forKey: "activeMacroFolderID")
        defaults.set(true, forKey: migrationKey)
    }
}
