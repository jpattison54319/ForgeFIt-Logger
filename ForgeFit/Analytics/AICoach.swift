import Foundation
import ForgeData
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device coaching via Apple Intelligence (Foundation Models). Degrades
/// gracefully: when the model isn't available (unsupported device, disabled, or
/// still downloading) it returns nil and the UI falls back to the rule-based
/// recommendation.
enum AICoach {
    static let offTopicResponse = "I can help with training, recovery, routines, exercise technique, cardio, strength progress, nutrition around workouts, and how your ForgeFit data is trending. Ask me something in that lane and I’ll dig in."

    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to enable coaching."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading."
        case .unavailable: return "On-device coaching is unavailable right now."
        }
        #else
        return "On-device coaching is unavailable on this platform."
        #endif
    }

    /// Generate a short coaching paragraph from the recovery metrics.
    static func coach(prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let instructions = """
            You are the user's personal ForgeFit coach. From their training-readiness metrics, give \
            2-3 short, warm, encouraging sentences of practical advice for today — like a coach who \
            knows them and has their back. Speak naturally and say what the numbers mean for them. \
            No preamble, no bullet points, no markdown.
            """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func answer(question: String, context: AICoachContext) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let instructions = """
            You are ForgeFit Coach — the user's personal strength & conditioning coach, living inside their
            fitness app. You know their training history, recovery, and readiness because it's handed to you
            as context below.

            Voice: warm, encouraging, and conversational — a knowledgeable coach who's genuinely in their
            corner. Talk WITH them, not at them. Celebrate their progress and PRs, be motivating and honest
            when readiness is low, and always sound human — never robotic, clinical, or preachy.

            Grounding: base every answer on the provided ForgeFit data — reference their actual numbers,
            recent workouts, and recovery signals so it feels personal. Never invent data you weren't given.
            When a signal is missing or confidence is low, say so plainly and still give your best call.

            Scope: stay in the training lane — workouts, technique, readiness, recovery, cardio, routines,
            progress, and nutrition around training. If asked something off-topic, warmly decline in a
            sentence and steer back to their training.

            Safety: you're a coach, not a doctor — no medical diagnosis. For pain, injury, illness, chest
            pain, fainting, or severe symptoms, tell them to stop or ease off and see a qualified professional.

            Keep replies focused and genuinely useful — usually a few conversational sentences. Reach for
            short bullets only when they make a plan clearer.
            """
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            USER TRAINING CONTEXT:
            \(context.prompt)

            USER QUESTION:
            \(question)
            """
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func isRelevant(_ question: String, context: AICoachContext) -> Bool {
        let normalized = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let keywords = [
            "workout", "routine", "exercise", "set", "sets", "rep", "reps", "weight", "lbs", "kg",
            "strength", "hypertrophy", "muscle", "volume", "progress", "pr", "1rm", "lift", "lifting",
            "bench", "squat", "deadlift", "press", "row", "curl", "pull", "push", "legs", "chest",
            "back", "shoulder", "arms", "biceps", "triceps", "glutes", "hamstring", "quad", "calf",
            "cardio", "run", "ride", "cycle", "bike", "walk", "zone", "pace", "heart rate", "hr",
            "recovery", "readiness", "sleep", "hrv", "resting", "soreness", "fatigue", "deload",
            "warmup", "warm-up", "mobility", "form", "technique", "pain", "injury", "nutrition",
            "protein", "calorie", "carb", "cut", "bulk", "diet", "xp", "level"
        ]
        if keywords.contains(where: { normalized.contains($0) }) { return true }
        return context.relevanceTerms.contains { term in
            let folded = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return folded.count > 3 && normalized.contains(folded)
        }
    }

    static func fallbackAnswer(for question: String, context: AICoachContext) -> String {
        let lower = question.lowercased()
        if lower.contains("ready") || lower.contains("recovery") || lower.contains("train") {
            return "\(context.readinessLine) \(context.actionLine) \(context.topReasonLine)"
        }
        if lower.contains("progress") || lower.contains("stronger") || lower.contains("record") || lower.contains("pr") {
            return context.recordsLine
        }
        if lower.contains("volume") || lower.contains("muscle") || lower.contains("sets") {
            return context.muscleVolumeLine
        }
        return "I can answer this better when Apple Intelligence is available. Based on your app data right now: \(context.actionLine) \(context.topReasonLine)"
    }
}

struct AICoachContext {
    let prompt: String
    let readinessLine: String
    let actionLine: String
    let topReasonLine: String
    let muscleVolumeLine: String
    let recordsLine: String
    let relevanceTerms: [String]

    static func build(
        workouts: [WorkoutModel],
        routines: [RoutineModel],
        exercises: [ExerciseLibraryModel],
        recovery: RecoveryEngine.Report
    ) -> AICoachContext {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        let completed = analytics.completed.sorted { $0.startedAt > $1.startedAt }
        let week = analytics.thisWeek()
        let records = analytics.records()
        let muscleRows = analytics.weeklyMuscleVolume()
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Use displayScore — the same number the user sees on Home / Recovery
        // (evidence-based systemic score when available, legacy composite
        // otherwise). Feeding recovery.score here made the coach cite a
        // different readiness than the ring on screen.
        let readinessLine = "Readiness: \(Int((recovery.displayScore * 100).rounded()))/100, \(recovery.action.title)."
        let actionLine = "Today: \(recovery.preWorkoutAdjustment)"
        let topReasons = recovery.reasonChips.prefix(4).map(\.text).joined(separator: ", ")
        let topReasonLine = topReasons.isEmpty ? "No major readiness flags are available yet." : "Main signals: \(topReasons)."

        // Evidence-based sub-scores the user actually sees, so the coach can
        // reason about *why* readiness is where it is and what's still building.
        let systemic = recovery.recovery.systemic
        let systemicLine: String = {
            if let value = systemic.state.value {
                return "Systemic recovery: \(Int((value * 100).rounded()))% — \(systemic.guidance)"
            }
            if case .building(let need) = systemic.state { return "Systemic recovery: still building — \(need)." }
            return "Systemic recovery: not available yet."
        }()

        let cardio = recovery.recovery.cardio
        let cardioLine: String = {
            if let value = cardio.state.value {
                let domain = cardio.dominantDomain.map { " Last effort \($0.rawValue.lowercased())." } ?? ""
                return "Cardio recovery: \(Int((value * 100).rounded()))%.\(domain) \(cardio.guidance)"
            }
            if case .building(let need) = cardio.state { return "Cardio recovery: still building — \(need)." }
            return "Cardio recovery: not available yet."
        }()

        // Which muscles are still fatigued (avoid) vs fresh (fair game).
        let ranked = recovery.recovery.muscles
            .filter { $0.state.value != nil }
            .sorted { ($0.state.value ?? 1) < ($1.state.value ?? 1) }
        let stillRecovering = ranked
            .filter { ($0.state.value ?? 1) < 0.75 }
            .prefix(4)
            .map { m -> String in
                let eta = m.readyInHours.map { " (~\($0)h to ready)" } ?? ""
                return "\(m.muscle.capitalized) \(m.statusLabel.lowercased())\(eta)"
            }
        let muscleRecoveryLine = stillRecovering.isEmpty
            ? "Muscle recovery: all recently trained muscles are fresh."
            : "Muscles still recovering: \(stillRecovering.joined(separator: ", "))."

        let recentLines = completed.prefix(8).map { workout in
            let summary = analytics.summary(for: workout)
            let title = workout.title ?? workout.cardioSessions.first?.modality.capitalized ?? "Workout"
            let exercises = workout.exercises
                .sorted { $0.position < $1.position }
                .compactMap { exerciseByID[$0.exerciseID]?.name }
                .prefix(5)
                .joined(separator: ", ")
            let cardio = workout.cardioSessions.first.map { session in
                let distance = session.distanceMeters.map { ", \(Fmt.distance($0))" } ?? ""
                return ", cardio \(session.modality)\(distance)"
            } ?? ""
            return "- \(workout.startedAt.formatted(date: .abbreviated, time: .omitted)): \(title), \(Fmt.durationShort(summary.durationSeconds)), \(summary.sets) sets, \(Fmt.volume(summary.volume))\(cardio)\(exercises.isEmpty ? "" : ", exercises: \(exercises)")"
        }

        let routineLines = routines
            .filter { $0.deletedAt == nil }
            .sorted { $0.position < $1.position }
            .prefix(8)
            .map { "- \($0.name): \($0.exercises.count) exercises" }

        let volumeLines = muscleRows.prefix(8).map {
            "- \($0.muscle.capitalized): \($0.sets.formatted(.number.precision(.fractionLength(0...1)))) sets this week"
        }
        let muscleVolumeLine = volumeLines.isEmpty
            ? "Weekly muscle volume is not built yet."
            : "Weekly muscle volume: \(volumeLines.joined(separator: "; "))."

        let recordLines = records.prefix(8).map {
            "- \($0.name): est. 1RM \(Fmt.loadUnit($0.best1RM)), last performed \($0.lastPerformed.formatted(.relative(presentation: .named)))"
        }
        let recordsLine = recordLines.isEmpty
            ? "No estimated 1RM records yet."
            : "Top recent records: \(recordLines.joined(separator: "; "))."

        let healthLines = recovery.signals.prefix(8).map {
            "- \($0.name): \($0.value), \($0.detail)"
        }
        let missing = recovery.missingInputs.isEmpty ? "none" : recovery.missingInputs.joined(separator: ", ")

        let prompt = """
        \(readinessLine)
        \(actionLine)
        \(topReasonLine)
        Confidence: \(Int((recovery.confidence * 100).rounded()))% (lower confidence = sparser data, hedge advice accordingly).
        Missing inputs: \(missing).

        Recovery detail:
        \(systemicLine)
        \(cardioLine)
        \(muscleRecoveryLine)

        This week: \(week.workoutCount) workouts, \(Fmt.durationShort(week.durationSeconds)), \(week.sets) working sets, \(week.reps) reps, \(Fmt.volume(week.volume)).

        Recent workouts:
        \(recentLines.isEmpty ? "- none logged yet" : recentLines.joined(separator: "\n"))

        Current routines:
        \(routineLines.isEmpty ? "- none created yet" : routineLines.joined(separator: "\n"))

        \(muscleVolumeLine)
        \(recordsLine)

        Health/readiness signals:
        \(healthLines.isEmpty ? "- no Health signals connected yet" : healthLines.joined(separator: "\n"))
        """

        let relevanceTerms = Array(
            Set(
                routines.map(\.name)
                    + exercises.prefix(250).map(\.name)
                    + exercises.flatMap(\.primaryMuscles)
                    + exercises.flatMap(\.secondaryMuscles)
            )
        )

        return AICoachContext(
            prompt: prompt,
            readinessLine: readinessLine,
            actionLine: actionLine,
            topReasonLine: topReasonLine,
            muscleVolumeLine: muscleVolumeLine,
            recordsLine: recordsLine,
            relevanceTerms: relevanceTerms
        )
    }
}

private struct CoachChatMessage: Identifiable, Equatable {
    enum Role { case user, coach }

    let id = UUID()
    let role: Role
    let text: String
}

struct AICoachChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let context: AICoachContext

    @State private var messages: [CoachChatMessage]
    @State private var question = ""
    @State private var isAnswering = false

    init(context: AICoachContext) {
        self.context = context
        _messages = State(initialValue: [
            CoachChatMessage(
                role: .coach,
                text: "Ask me about your training, recovery, routines, progress, or what to do next. I’ll use your ForgeFit data and keep it practical."
            )
        ])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: Space.md) {
                            contextSummary
                            ForEach(messages) { message in
                                CoachBubble(message: message)
                                    .id(message.id)
                            }
                            if isAnswering {
                                HStack(spacing: Space.sm) {
                                    ProgressView().tint(theme.accent)
                                    Text("Thinking...")
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .padding(.vertical, Space.sm)
                            }
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.top, Space.md)
                        .padding(.bottom, Space.lg)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }

                coachInput
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(.regularMaterial)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                }
            }
        }
    }

    private var contextSummary: some View {
        Card(fill: theme.accentSoft) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(theme.accent)
                    Text("Using your ForgeFit data")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(AICoach.isSupported ? "Apple Intelligence" : "Rules fallback")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                Text("\(context.readinessLine) \(context.topReasonLine)")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !AICoach.isSupported {
                    Text(AICoach.unavailableReason)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var coachInput: some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            TextField("Ask about training, recovery, progress...", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 11)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? theme.accent : theme.surfaceHighlight)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send coach question")
        }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnswering
    }

    private func send() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        question = ""
        messages.append(CoachChatMessage(role: .user, text: trimmed))

        guard AICoach.isRelevant(trimmed, context: context) else {
            messages.append(CoachChatMessage(role: .coach, text: AICoach.offTopicResponse))
            return
        }

        isAnswering = true
        Task {
            let response = await AICoach.answer(question: trimmed, context: context)
                ?? AICoach.fallbackAnswer(for: trimmed, context: context)
            messages.append(CoachChatMessage(role: .coach, text: response))
            isAnswering = false
        }
    }
}

private struct CoachBubble: View {
    @Environment(\.theme) private var theme
    let message: CoachChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 44) }
            Text(message.text)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 10)
                .background(message.role == .user ? theme.accent.opacity(0.38) : theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role == .coach { Spacer(minLength: 44) }
        }
    }
}

/// A card that asks Apple Intelligence for a coaching note, with a loading state
/// and graceful fallback.
struct AICoachCard: View {
    let prompt: String
    let fallback: String

    @Environment(\.theme) private var theme
    @State private var text: String?
    @State private var loading = true

    var body: some View {
        Card(fill: theme.accentSoft) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(theme.accent)
                    Text("Coach").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    if AICoach.isSupported {
                        Text("Apple Intelligence").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    }
                }
                if loading {
                    HStack(spacing: Space.sm) {
                        ProgressView().tint(theme.accent)
                        Text("Thinking…").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                } else {
                    Text(text ?? fallback)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if text == nil {
                        Text(AICoach.isSupported ? "" : AICoach.unavailableReason)
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .task {
            guard AICoach.isSupported else { loading = false; return }
            text = await AICoach.coach(prompt: prompt)
            loading = false
        }
    }
}
