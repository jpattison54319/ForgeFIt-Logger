import Foundation

/// The morning check-in vocabulary, shared by Home's check-in strip and the
/// Recovery screen's full card. The ids are persisted in
/// `DailyCheckinModel.tagsRaw` and interpreted by `RecoveryEngine` — labels
/// and icons can change freely, ids must not.
enum CheckinTags {
    static let all: [(id: String, label: String, icon: String)] = [
        ("feeling-great", "Feeling great", "sun.max.fill"),
        ("slept-badly", "Slept badly", "moon.zzz.fill"),
        ("sore", "Sore", "figure.strengthtraining.traditional"),
        ("stressed", "Stressed", "brain.head.profile"),
        ("alcohol", "Alcohol", "wineglass"),
        ("sick", "Sick", "thermometer.variable"),
    ]
}
