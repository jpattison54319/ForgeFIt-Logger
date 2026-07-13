import ForgeData

extension WorkoutModel {
    /// Single definition of "arrived through an import". The history-file
    /// importers (Hevy/Strong/CSV/ForgeFit JSON) stamp the provenance fields,
    /// but the Apple Health and GPX importers only stamp `sourceDevice` — so
    /// anything gated on training actually logged in ForgeFit (XP, trophies)
    /// must check this one property, not the provenance fields alone.
    var isImportedHistory: Bool {
        if externalSource != nil || importFingerprint != nil || importBatchID != nil {
            return true
        }
        guard let sourceDevice else { return false }
        return sourceDevice.hasPrefix("healthkit")
            || sourceDevice.hasPrefix("import-")
            || sourceDevice == "gpx-import"
    }
}
