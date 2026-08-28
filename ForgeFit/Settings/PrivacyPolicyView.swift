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
                    Text("Last updated: August 27, 2026")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    Text("ForgeFit is built local-first: your training data belongs to you. If you are signed into iCloud, ForgeFit automatically syncs your training plan through your private CloudKit database and automatically backs up a sanitized copy of your workout history to your iCloud Drive.")
                        .font(.system(size: 14)).foregroundStyle(theme.textPrimary)
                }

                section("What we collect",
                        "We operate no servers and collect no personal information. ForgeFit stores your workouts, routines, exercise notes, and settings in a local database on your iPhone. We run no analytics and have no backend. Nothing you log is sent anywhere we can read it.")

                section("iCloud sync & workout backup",
                        "If you are signed into iCloud, ForgeFit syncs your training plan — routines, folders, each microcycle folder's default day target, your exercise library, notes, saved interval and yoga presets, saved insight charts (their definitions only — the numbers they show are recomputed on each device), coaching plans and preferences, progression suggestions, and your XP progress — across your Apple devices using Apple's CloudKit. The records are stored under your iCloud account in your private CloudKit database. ForgeFit's developer operates no server and cannot read them.\n\nYour workout history remains in a local database on each iPhone rather than syncing as live CloudKit records. ForgeFit automatically creates a separate, sanitized backup in Files → iCloud Drive → ForgeFit → Backups. Backup is on automatically when iCloud Drive is available: ForgeFit queues a copy after workout-history changes and performs a daily catch-up while you use the app. It defers backup work while a live workout is open or the app is in the background. ForgeFit keeps a latest and previous copy so an interrupted write does not replace the only usable backup. Settings → iCloud Backup shows the latest success or failure and lets you retry immediately.\n\nThe workout backup includes user-recorded training details such as workout names and notes, exercises, sets, weights, reps, RPE, cardio and yoga details, precise outdoor route coordinates, imports, microcycle windows, rest markers, and selected app preferences such as display name, units, theme, quick actions, and reminder choices. It excludes experiments and custom experiment entries, workouts imported from Apple Health, HealthKit-filled distance, Health-derived automatic interval detection, heart rate, calories or active energy, step counts, sleep, readiness, body weight, daily check-ins, and other Apple Health data. On another iPhone signed into the same iCloud account, you choose Settings → Import workout history to restore a backup; ForgeFit then re-reads available Health metrics from Apple Health on that device.")

                section("Microcycle tracking",
                        "A leaf routine folder can be tracked as a repeating microcycle with a day target. The folder's default day target is part of your synced training plan. Active tracking runs, frozen window snapshots, Home and folder-header display choices, and rest-day markers stay in the local training log; the sanitized automatic workout backup includes them, and user-directed exports can include them too. Progress is derived from completed workouts linked to routines in that microcycle. A rest-day marker adds calendar context but never completes a routine. Workouts completed on Apple Watch can contribute after they reconcile to that iPhone.")

                section("Experiments",
                        "Experiments let you compare training, cardio, yoga, and available Apple Health trends across a time period, alongside custom information you choose to record. Experiment names, descriptions, schedules, custom trackers, and entries stay only in the local database on the iPhone where you create them. They do not sync through CloudKit or any automatic backup. Workouts completed on Apple Watch can appear in an experiment after they reconcile to that iPhone.\n\nExperiment results describe differences and associations in your recorded data. They do not establish that a supplement, routine, or other change caused an outcome and are not medical advice. Deleting the app or replacing the iPhone without making a separate user-directed export deletes the experiment records.")

                section("Exercise photos & descriptions",
                        "Photos and written descriptions you add to an exercise are stored as ordinary files on that iPhone only. They are not synced through CloudKit, are not written to the iCloud Drive workout backup, and are never included in a data export, a shared plan, or a shared workout. ForgeFit reads photos through Apple's photo picker, which hands the app only the images you pick — ForgeFit never gains access to your photo library.\n\nBecause they never leave the device, exercise photos and descriptions are not restored by ForgeFit's own backup; an encrypted iOS device backup is what carries them to a replacement iPhone. Settings → Reset all app data and deleting the app both remove them.")

                section("Apple Health",
                        "With your permission, ForgeFit reads health data from Apple Health to power its features:\n\n• Workout metrics (heart rate, active energy, distance, power) to auto-fill cardio sessions and show live stats during workouts.\n\n• Recovery data (heart-rate variability, resting heart rate, sleep, respiratory rate, blood oxygen, VO₂max, heart-rate recovery, steps, exercise time, body weight) to compute your daily readiness score.\n\nWith your permission, ForgeFit also writes finished workouts back to Apple Health.\n\nHealth data is processed entirely on your device. It is never transmitted to us or any third party, is excluded from automatic iCloud sync and backup, and is protected by iOS's Health data security. A user-directed data export can include Health metrics stored with workouts or used in an experiment; you choose that export's destination. When you restore a ForgeFit workout backup, ForgeFit re-reads available Health metrics from Apple Health on that device. You can revoke access at any time in the Health app under Sharing → Apps.")

                section("Apple Watch",
                        "If you use the ForgeFit watch app, workout data syncs directly between your watch and iPhone using Apple's encrypted device-to-device channel (WatchConnectivity). It does not pass through any server.")

                section("Siri, Shortcuts & Spotlight",
                        "ForgeFit exposes a limited catalog of startable workout choices through Apple's App Intents and Spotlight APIs so system features such as Siri, Shortcuts, Spotlight, the Action Button, and Control Center can find and open them. A catalog item contains its name, category, icon name, and a stable identifier. It never contains workout history, Health data, notes, or exercise targets.\n\nWhen you request a workout through Siri, the system can send ForgeFit structured workout-name text or a selected workout identifier; ForgeFit does not receive Siri audio or a complete voice transcript. ForgeFit uses that structured value to start the matching saved routine, cardio session, yoga flow, conditioning preset, empty workout, or next tracked routine from data already on your device.\n\nDuring an active workout, ForgeFit resolves the current set directly from its local database. Siri or Shortcuts can pass the selected set identifier and values you provide—such as reps, load and unit, RPE or RIR, rest action, and whole-session exertion—and ForgeFit returns confirmation or status text that can include the workout name, exercise name, set label, and those values. ForgeFit does not add active-workout values, workout history, Health data, or notes to Spotlight, its App Group diagnostic, intent donations, or logs. Set changes and finished workouts are saved through the same local workout pipeline as changes made inside the app.\n\nFor troubleshooting, ForgeFit stores only the latest structured workout-name lookup, up to five matching routine names, the selected identifier, result, and time in its local App Group. Active-workout commands are not stored there. A later start lookup replaces the previous one. You can inspect or clear it in Settings → Siri & Shortcuts, and Settings → Reset all app data also removes it.")

                section("Bluetooth heart-rate monitors",
                        "If you pair a Bluetooth heart-rate monitor, its readings are used live during your workout and stored with the session on your device, like any other workout metric. The pairing is remembered only on that device.")

                section("Earlier Community data",
                        "An earlier test build included an optional Community feature backed by Apple's public CloudKit database. This version does not publish new Community data. If you used that feature, Settings → Delete Community data permanently removes your public profile and handle, shared workouts, follows, and likes.")


                section("Data export",
                        "Settings → Export data creates JSON or CSV files of your workouts, routines, microcycle tracking windows, and rest-day markers on demand, including the health metrics ForgeFit has stored with workouts. An experiment's results screen can separately export the observations used in that experiment, including custom entries and available daily Health summaries. These exports happen only when you request them. You choose the format and where the files go — they are handed directly to you through the iOS share sheet and are never transmitted to us or anyone else. Files shared outside ForgeFit are then controlled by the destination you choose.")

                section("Plan sharing",
                        "When you share a routine, microcycle, or mesocycle, ForgeFit creates a preview image and a ForgeFit Plan file only after you choose Share. The plan file can include routine and cycle names, routine notes, exercise definitions, ordering, and planned targets so another ForgeFit user can save an independent copy. It never includes your account identity, setup notes, workout history, cycle progress, experiments, Apple Health data, readiness, or recovery information. You choose the destination through the iOS share sheet; after sharing, the file is controlled by that destination and its recipient.")

                section("Data deletion",
                        "Deleting the app deletes all local ForgeFit data on that device, including microcycle tracking runs, rest-day markers, experiments, and their custom entries. Ending microcycle tracking does not delete workouts or rest-day markers; deleting one experiment removes only that experiment and its entries. Neither action deletes Apple Health data. Your training plan in iCloud can be removed by deleting routines in the app (deletions sync) or via Settings → Reset all app data. The workout backup is an ordinary pair of files you control: delete it with Settings → iCloud Backup → Delete workout backup, in Files → iCloud Drive → ForgeFit → Backups, or via Settings → Reset all app data. Reset attempts to remove the backup and tells you if it could not. Because workout backup is automatic, deleting only the backup does not turn backup off; a new copy is created after future workout-history changes or a later daily catch-up. Deleting the app from one device does not by itself delete the private CloudKit plan or iCloud Drive backup. Any earlier public Community data must be removed separately with Settings → Delete Community data. Workouts written to Apple Health remain there under your control and can be deleted in the Health app.")

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
