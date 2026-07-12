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
                    Text("Last updated: July 10, 2026")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    Text("ForgeFit is built local-first: your training data belongs to you and lives on your device, with optional iCloud sync for your training plan and an optional iCloud Drive backup of your training log.")
                        .font(.system(size: 14)).foregroundStyle(theme.textPrimary)
                }

                section("What we collect",
                        "We operate no servers and collect no personal information. ForgeFit stores your workouts, routines, exercise notes, and settings in a local database on your iPhone. We run no analytics and have no backend.")

                section("iCloud sync & backup",
                        "If you are signed into iCloud, ForgeFit syncs your training plan — routines, folders, your exercise library, notes, saved interval and yoga presets, and your XP progress — across your Apple devices using Apple's CloudKit, stored in your private CloudKit database, encrypted by Apple and accessible only to you.\n\nYour workout history is different: it stays in a local database on each device. To protect it against a lost or replaced phone, ForgeFit writes an optional backup file of your training log to your iCloud Drive, visible in the Files app under ForgeFit. This backup contains only what you logged — sets, reps, weights, durations, effort ratings, notes, cardio splits, and outdoor route maps.\n\nIt never includes heart rate, calories or active energy, step counts, sleep, readiness scores, body weight, daily check-ins, or any other Apple Health data. In line with App Store guidelines, ForgeFit does not store personal health information in iCloud.")

                section("Apple Health",
                        "With your permission, ForgeFit reads health data from Apple Health to power its features:\n\n• Workout metrics (heart rate, active energy, distance, power) to auto-fill cardio sessions and show live stats during workouts.\n\n• Recovery data (heart-rate variability, resting heart rate, sleep, respiratory rate, blood oxygen, VO₂max, heart-rate recovery, steps, exercise time, body weight) to compute your daily readiness score.\n\nWith your permission, ForgeFit also writes finished workouts back to Apple Health.\n\nHealth data is processed entirely on your device. It is never transmitted to us or any third party, is excluded from iCloud sync and from iCloud Drive backups, and is protected by iOS's Health data security. When you restore a backup on a new device, ForgeFit re-reads these metrics from Apple Health on that device (Apple syncs your Health data between your devices when Health in iCloud is enabled — that is Apple's system, under your control). You can revoke access at any time in the Health app under Sharing → Apps.")

                section("Apple Watch",
                        "If you use the ForgeFit watch app, workout data syncs directly between your watch and iPhone using Apple's encrypted device-to-device channel (WatchConnectivity). It does not pass through any server.")

                section("Bluetooth heart-rate monitors",
                        "If you pair a Bluetooth heart-rate monitor, its readings are used live during your workout and stored with the session on your device, like any other workout metric. The pairing is remembered only on that device.")

                section("Data export",
                        "Settings → Export data creates JSON or CSV files of your workouts and routines on demand, including the health metrics ForgeFit has stored with them. You choose the format and where the files go — they are handed directly to you through the iOS share sheet and are never transmitted to us or anyone else.")

                section("Data deletion",
                        "Deleting the app deletes all local ForgeFit data on that device. Your training plan in iCloud can be removed by deleting routines in the app (deletions sync) or via Settings → Erase All Data. Your training-log backup is an ordinary file you control: delete it in the Files app (iCloud Drive → ForgeFit → Backups), or use Settings → Erase All Data, which also removes the backup. Workouts written to Apple Health remain there under your control and can be deleted in the Health app.")

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
