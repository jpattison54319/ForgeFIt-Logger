import SwiftUI

/// The full privacy policy, shipped in-app so it's readable offline and
/// before any hosted URL exists. Content mirrors `docs/privacy-policy.md` —
/// keep the two in sync when the policy changes; the hosted copy of that file
/// is what App Store Connect's privacy-policy URL field should point to.
struct PrivacyPolicyView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Last updated: August 8, 2026")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    Text("ForgeFit is built local-first: your training data belongs to you and lives on your device, with optional iCloud sync for your training plan and an optional iCloud Drive backup of your training log.")
                        .font(.system(size: 14)).foregroundStyle(theme.textPrimary)
                }

                section("What we collect",
                        "We operate no servers and collect no personal information. ForgeFit stores your workouts, routines, exercise notes, and settings in a local database on your iPhone. We run no analytics and have no backend. Nothing you log is sent anywhere we can read it.")

                section("iCloud sync & backup",
                        "If you are signed into iCloud, ForgeFit syncs your training plan — routines, folders, each microcycle folder's default day target, your exercise library, notes, saved interval and yoga presets, saved insight charts (their definitions only — the numbers they show are recomputed on each device), and your XP progress — across your Apple devices using Apple's CloudKit, stored in your private CloudKit database, encrypted by Apple and accessible only to you.\n\nYour workout history is different: it stays in a local database on each device. To protect it against a lost or replaced phone, ForgeFit writes an optional backup file of your training log to your iCloud Drive, visible in the Files app under ForgeFit. This backup contains what you logged — sets, reps, weights, durations, effort ratings, notes, cardio splits, outdoor route maps, microcycle tracking windows, and explicit rest-day markers.\n\nIt never includes experiments or their custom entries, heart rate, calories or active energy, step counts, sleep, readiness scores, body weight, daily check-ins, or any other Apple Health data. In line with App Store guidelines, ForgeFit does not store personal health information in iCloud.")

                section("Microcycle tracking",
                        "A leaf routine folder can be tracked as a repeating microcycle with a day target. The folder's default day target is part of your synced training plan. Active tracking runs, frozen window snapshots, Home and folder-header display choices, and rest-day markers stay in the local training log; they are included in ForgeFit's sanitized iCloud Drive backup and in user-directed data exports. Progress is derived from completed workouts linked to routines in that microcycle. A rest-day marker adds calendar context but never completes a routine. Workouts completed on Apple Watch can contribute after they reconcile to that iPhone.")

                section("Experiments",
                        "Experiments let you compare training, cardio, yoga, and available Apple Health trends across a time period, alongside custom information you choose to record. Experiment names, descriptions, schedules, custom trackers, and entries stay only in the local database on the iPhone where you create them. They do not sync through CloudKit and are not included in ForgeFit's iCloud Drive backup. Workouts completed on Apple Watch can appear in an experiment after they reconcile to that iPhone.\n\nExperiment results describe differences and associations in your recorded data. They do not establish that a supplement, routine, or other change caused an outcome and are not medical advice. Deleting the app or replacing the iPhone without making a separate user-directed export deletes the experiment records.")

                section("Apple Health",
                        "With your permission, ForgeFit reads health data from Apple Health to power its features:\n\n• Workout metrics (heart rate, active energy, distance, power) to auto-fill cardio sessions and show live stats during workouts.\n\n• Recovery data (heart-rate variability, resting heart rate, sleep, respiratory rate, blood oxygen, VO₂max, heart-rate recovery, steps, exercise time, body weight) to compute your daily readiness score.\n\nWith your permission, ForgeFit also writes finished workouts back to Apple Health.\n\nHealth data is processed entirely on your device. It is never transmitted to us or any third party, is excluded from iCloud sync and from iCloud Drive backups, and is protected by iOS's Health data security. When you restore a backup on a new device, ForgeFit re-reads these metrics from Apple Health on that device (Apple syncs your Health data between your devices when Health in iCloud is enabled — that is Apple's system, under your control). You can revoke access at any time in the Health app under Sharing → Apps.")

                section("Apple Watch",
                        "If you use the ForgeFit watch app, workout data syncs directly between your watch and iPhone using Apple's encrypted device-to-device channel (WatchConnectivity). It does not pass through any server.")

                section("Bluetooth heart-rate monitors",
                        "If you pair a Bluetooth heart-rate monitor, its readings are used live during your workout and stored with the session on your device, like any other workout metric. The pairing is remembered only on that device.")

                section("Earlier Community data",
                        "An earlier test build included an optional Community feature backed by Apple's public CloudKit database. This version does not publish new Community data. If you used that feature, Settings → Delete Community data permanently removes your public profile and handle, shared workouts, follows, and likes.")


                section("Data export",
                        "Settings → Export data creates JSON or CSV files of your workouts, routines, microcycle tracking windows, and rest-day markers on demand, including the health metrics ForgeFit has stored with workouts. An experiment's results screen can separately export the observations used in that experiment, including custom entries and available daily Health summaries. These exports happen only when you request them. You choose the format and where the files go — they are handed directly to you through the iOS share sheet and are never transmitted to us or anyone else. Files shared outside ForgeFit are then controlled by the destination you choose.")

                section("Plan sharing",
                        "When you share a routine, microcycle, or mesocycle, ForgeFit creates a preview image and a ForgeFit Plan file only after you choose Share. The plan file can include routine and cycle names, routine notes, exercise definitions, ordering, and planned targets so another ForgeFit user can save an independent copy. It never includes your account identity, setup notes, workout history, cycle progress, experiments, Apple Health data, readiness, or recovery information. You choose the destination through the iOS share sheet; after sharing, the file is controlled by that destination and its recipient.")

                section("Data deletion",
                        "Deleting the app deletes all local ForgeFit data on that device, including microcycle tracking runs, rest-day markers, experiments, and their custom entries. Ending microcycle tracking does not delete workouts or rest-day markers; deleting one experiment removes only that experiment and its entries. Neither action deletes Apple Health data. Your training plan in iCloud can be removed by deleting routines in the app (deletions sync) or via Settings → Reset all app data. Your training-log backup is an ordinary file you control: delete it in the Files app (iCloud Drive → ForgeFit → Backups), or use Settings → Reset all app data, which also removes the backup. Any earlier public Community data must be removed separately with Settings → Delete Community data. Workouts written to Apple Health remain there under your control and can be deleted in the Health app.")

                section("Changes",
                        "This privacy policy will be updated if any future version changes how data is stored or synced. Any changes will be documented here first.")

                section("Contact",
                        "Questions? Contact the developer through the app's App Store listing.")
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
        }
        .background(theme.background)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Text(body).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
