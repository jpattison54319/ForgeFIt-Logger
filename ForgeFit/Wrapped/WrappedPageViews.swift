import SwiftUI

/// Renders one Wrapped page: full-bleed gradient canvas, one hero idea, bold
/// display typography. Shared by the in-app story and the share-card renderer
/// so a shared page looks exactly like the screen it came from.
struct WrappedPageView: View {
    @Environment(\.theme) private var theme
    let page: WrappedPage
    let periodLabel: String

    var body: some View {
        ZStack {
            WrappedPageBackground(kind: page.kind)
            content
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .cover(let cover):
            VStack(spacing: Space.lg) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(theme.accent)
                Text(cover.title)
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.textPrimary)
                Text(cover.subtitle)
                    .font(.bodyStrong)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)

        case .identity(let identity):
            hero(
                eyebrow: "You trained like a",
                title: identity.label,
                caption: identity.line,
                icon: "figure.strengthtraining.traditional"
            )

        case .bigStats(let stats):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("The big picture")
                heroNumber("\(stats.workouts)", unit: "workouts")
                statRow("Training time", Fmt.durationShort(stats.trainingMinutes * 60))
                statRow("Active days", "\(stats.activeDays)")
                if stats.totalVolumeKg > 0 {
                    statRow("Total volume", Fmt.volume(stats.totalVolumeKg))
                }
            }

        case .trainingMix(let mix):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Your training mix")
                mixBar(mix)
                statRow("Strength", "\(mix.strengthCount) sessions · \(Fmt.durationShort(mix.strengthMinutes * 60))")
                statRow("Cardio", "\(mix.cardioCount) sessions · \(Fmt.durationShort(mix.cardioMinutes * 60))")
                // Yoga row only exists on v2 payloads with yoga in them —
                // frozen v1 reports render exactly as generated.
                if let yogaCount = mix.yogaCount, yogaCount > 0 {
                    statRow("Yoga", "\(yogaCount) sessions · \(Fmt.durationShort((mix.yogaMinutes ?? 0) * 60))")
                }
            }

        case .calendar(let heatmap):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Consistency, mapped")
                heroNumber("\(heatmap.activeDays.count)", unit: "active days")
                WrappedMonthGrid(heatmap: heatmap)
            }

        case .strongestWeek(let week):
            hero(
                eyebrow: "Your strongest week",
                title: week.weekLabel,
                caption: "\(week.workouts) workouts · \(Fmt.volume(week.volumeKg)) moved",
                icon: "bolt.fill"
            )

        case .signatureExercise(let exercise):
            hero(
                eyebrow: "Your signature move",
                title: exercise.name,
                caption: "\(Fmt.sets(exercise.sets)) sets across \(exercise.sessions) sessions",
                icon: "star.fill"
            )

        case .muscleMap(let map):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Where the work went")
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(map.most, id: \.muscle) { item in
                        statRow(item.muscle.capitalized, "\(Fmt.sets(item.sets)) sets")
                    }
                }
                if let quiet = map.least.first {
                    Text("Quietest: \(quiet.muscle.capitalized) — \(Fmt.sets(quiet.sets)) sets")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
            }

        case .strengthProgress(let progress):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Strength moved")
                if progress.recordsSet > 0 {
                    heroNumber("\(progress.recordsSet)", unit: "record\(progress.recordsSet == 1 ? "" : "s") set")
                }
                if let lift = progress.bestLiftName, let gain = progress.bestLiftE1RMGainKg {
                    statRow(lift, "+\(Fmt.loadUnit(gain)) est. 1RM")
                }
            }

        case .cardioEngine(let cardio):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("The engine room")
                heroNumber(Fmt.durationShort(cardio.minutes * 60), unit: "of cardio")
                if cardio.distanceMeters > 0 {
                    statRow("Distance", Fmt.distance(cardio.distanceMeters))
                }
                if let longest = cardio.longestSessionMinutes, let kind = cardio.longestSessionKind {
                    statRow("Longest session", "\(kind) · \(Fmt.durationShort(longest * 60))")
                }
                if cardio.zoneSeconds.reduce(0, +) > 0 {
                    ZoneSecondsBar(zoneSeconds: cardio.zoneSeconds, source: .mixed)
                }
            }

        case .heartRate(let hr):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Heart rate story")
                heroNumber("\(hr.highestWorkoutHR)", unit: "bpm peak", tint: theme.danger)
                statRow("Hit during", hr.highestWorkoutTitle)
                if let average = hr.averageWorkoutHR {
                    statRow("Average workout HR", "\(average) bpm")
                }
            }

        case .bossBattle(let boss):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Boss battle")
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(boss.workoutTitle)
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text(boss.dayLabel)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
                statRow("Duration", Fmt.durationShort(boss.durationMinutes * 60))
                if boss.volumeKg > 0 { statRow("Volume", Fmt.volume(boss.volumeKg)) }
                if let rpe = boss.avgRPE {
                    statRow("Average effort", "RPE \(rpe.formatted(.number.precision(.fractionLength(1))))")
                }
            }

        case .improved(let insight):
            hero(eyebrow: "What improved", title: insight.headline, caption: insight.detail, icon: "arrow.up.right")

        case .heldBack(let insight):
            hero(eyebrow: "What held you back", title: insight.headline, caption: insight.detail, icon: "arrow.uturn.down", tint: theme.warmup)

        case .comparison(let delta):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("vs \(delta.previousLabel)")
                deltaRow("Workouts", delta.workoutsDelta > 0 ? "+\(delta.workoutsDelta)" : "\(delta.workoutsDelta)", positive: delta.workoutsDelta >= 0)
                deltaRow("Volume", "\(delta.volumeDeltaKg >= 0 ? "+" : "")\(Fmt.volume(delta.volumeDeltaKg))", positive: delta.volumeDeltaKg >= 0)
                deltaRow("Training time", "\(delta.minutesDelta >= 0 ? "+" : "")\(Fmt.durationShort(abs(delta.minutesDelta) * 60))", positive: delta.minutesDelta >= 0)
            }

        case .nextFocus(let focus):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Next month, focus on")
                focusRow(number: "1", text: focus.primary, emphasized: true)
                if let secondary = focus.secondary {
                    focusRow(number: "2", text: secondary, emphasized: false)
                }
                if let maintain = focus.maintain {
                    focusRow(number: "✓", text: maintain, emphasized: false)
                }
            }

        case .recap(let recap):
            VStack(spacing: Space.lg) {
                Text(recap.title)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                if let identity = recap.identityLabel {
                    Text(identity)
                        .font(.cardTitle)
                        .foregroundStyle(theme.accent)
                }
                VStack(spacing: Space.md) {
                    statRow("Workouts", "\(recap.workouts)")
                    statRow("Training time", Fmt.durationShort(recap.trainingMinutes * 60))
                    statRow("Active days", "\(recap.activeDays)")
                    if recap.volumeKg > 0 { statRow("Volume", Fmt.volume(recap.volumeKg)) }
                }
                if let highlight = recap.highlight {
                    Text(highlight)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.warmup)
                }
            }

        case .mostActiveMonth(let month):
            hero(
                eyebrow: "Your most active month",
                title: month.monthName,
                caption: "\(month.workouts) workouts",
                icon: "flame.fill",
                tint: theme.warmup
            )

        case .longestStreak(let streak):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Longest streak")
                heroNumber("\(streak.days)", unit: "days straight")
                if let ended = streak.endedLabel {
                    Text(ended)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
            }

        case .topWorkouts(let top):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Top workouts")
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Array(top.entries.enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: Space.md) {
                            Text("\(index + 1)")
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Text("\(entry.dayLabel) · \(Fmt.volume(entry.volumeKg))")
                                    .font(.label)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
            }

        case .badges(let badges):
            VStack(alignment: .leading, spacing: Space.xl) {
                eyebrowText("Badges earned")
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(badges.earned, id: \.self) { badge in
                        HStack(spacing: Space.md) {
                            Image(systemName: "medal.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(theme.warmup)
                            Text(badge).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared layout pieces

    private func hero(eyebrow: String, title: String, caption: String, icon: String, tint: Color? = nil) -> some View {
        VStack(spacing: Space.lg) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(tint ?? theme.accent)
            eyebrowText(eyebrow)
            Text(title)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textPrimary)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.bodyStrong)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func eyebrowText(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.tag)
            .kerning(1.4)
            .foregroundStyle(theme.accent)
    }

    private func heroNumber(_ value: String, unit: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(unit)
                .font(.cardTitle)
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.bodyStrong).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value).font(.rowValue).foregroundStyle(theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func deltaRow(_ label: String, _ value: String, positive: Bool) -> some View {
        HStack {
            Text(label).font(.bodyStrong).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(positive ? theme.success : theme.warmup)
        }
        .accessibilityElement(children: .combine)
    }

    private func focusRow(number: String, text: String, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(number)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(emphasized ? theme.accent : theme.textTertiary)
                .frame(width: 30)
            Text(text)
                .font(emphasized ? .cardTitle : .bodyStrong)
                .foregroundStyle(emphasized ? theme.textPrimary : theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func mixBar(_ mix: WrappedPage.TrainingMix) -> some View {
        let yoga = mix.yogaCount ?? 0
        let total = max(1, mix.strengthCount + mix.cardioCount + yoga)
        return GeometryReader { geo in
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.accent)
                    .frame(width: geo.size.width * CGFloat(mix.strengthCount) / CGFloat(total))
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.secondaryAccent)
                if yoga > 0 {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.warmup)
                        .frame(width: geo.size.width * CGFloat(yoga) / CGFloat(total))
                }
            }
        }
        .frame(height: 14)
        .accessibilityLabel(
            yoga > 0
                ? "\(mix.strengthCount) strength, \(mix.cardioCount) cardio, \(yoga) yoga sessions"
                : "\(mix.strengthCount) strength, \(mix.cardioCount) cardio sessions"
        )
    }
}

/// Month grid: 7 columns, a filled dot per trained day.
struct WrappedMonthGrid: View {
    @Environment(\.theme) private var theme
    let heatmap: WrappedPage.CalendarHeatmap

    var body: some View {
        let days = daysInMonth
        let active = Set(heatmap.activeDays)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(1...days, id: \.self) { day in
                ZStack {
                    Circle()
                        .fill(active.contains(day) ? theme.accent : theme.surfaceElevated)
                    if active.contains(day) {
                        Text("\(day)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 32)
            }
        }
        .accessibilityLabel("\(heatmap.activeDays.count) active days this month")
    }

    private var daysInMonth: Int {
        var components = DateComponents()
        components.year = heatmap.year
        components.month = heatmap.month
        let calendar = Calendar.current
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }
}

/// Per-page-kind gradient canvas over the theme background — distinct pages,
/// one design system.
struct WrappedPageBackground: View {
    @Environment(\.theme) private var theme
    let kind: String

    var body: some View {
        ZStack {
            theme.background
            LinearGradient(
                colors: [tint.opacity(0.35), tint.opacity(0.06), theme.background.opacity(0)],
                startPoint: startPoint,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var tint: Color {
        switch kind {
        case "cover", "recap", "identity": theme.accent
        case "cardioEngine", "trainingMix": theme.secondaryAccent
        case "heartRate", "bossBattle": theme.danger
        case "heldBack", "badges", "mostActiveMonth": theme.warmup
        case "strengthProgress", "improved", "strongestWeek": theme.success
        default: theme.accent
        }
    }

    private var startPoint: UnitPoint {
        switch kind {
        case "cover", "recap": .top
        case "bossBattle", "heartRate": .topTrailing
        default: .topLeading
        }
    }
}
