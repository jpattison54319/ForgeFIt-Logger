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

    static func answer(
        question: String,
        context: AICoachContext,
        coachCornerAvailable: Bool = FeatureFlags.coachCorner
    ) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            // Where plan changes actually happen depends on whether the full
            // Coach's Corner surface is enabled — never send the user to a
            // screen they can't reach.
            let planGuidance = coachCornerAvailable
                ? """
                If they want to change the plan, adjust today's dose, or build a program, point them warmly \
                to Coach's Corner — the review screen for today's session, or "Build my plan" / "Coach this \
                plan" for a program. You explain the numbers; you never silently rewrite them.
                """
                : """
                To start today's session with the adjusted dose, they tap Start on the coach's-version card — \
                right here in chat, or on their Home session card. You explain the numbers; you never silently \
                rewrite them. Building a full multi-week program isn't available yet, so if they ask for one, \
                tell them warmly it's on the way and help them make the most of today's session meanwhile.
                """

            let instructions = """
            You are ForgeFit Coach — the user's personal strength & conditioning coach, living inside their
            fitness app. You know their training history, recovery, and readiness because it's handed to you
            as context below.

            Voice: talk like a real coach texting a client back — warm, direct, and unmistakably human. Use
            contractions and plain words, vary your rhythm, and lead with the answer instead of a preamble
            (no "Great question!", no "As your coach…"). React like a person: hyped about a PR, calm and
            honest when readiness is low. Call back to their actual sessions and numbers by name so it lands
            personal. You may use their first name once if it feels natural — never force it. Never sound like
            a form letter, a disclaimer, or a textbook; skip corporate hedging like "it's important to note"
            and don't use emoji unless they do first.

            Grounding: base every answer on the provided ForgeFit data — their real numbers, recent workouts,
            suggested session, and recovery signals. Never invent data you weren't given. When a signal is
            missing or confidence is low, say so plainly and still give your best call.

            Scope: stay in the training lane — workouts, technique, readiness, recovery, cardio, routines,
            progress, and nutrition around training. If asked something off-topic, warmly decline in a
            sentence and steer back to their training.

            Boundaries: you EXPLAIN the deterministic readiness score, progression targets, and coach dose
            adjustments the app has already computed — you never invent, create, or modify a training program
            or its numbers yourself. \(planGuidance)

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

    /// Rules-based answer used when Apple Intelligence isn't available. Routes to
    /// the most relevant slice of the user's data by intent; anything else still
    /// gets a grounded readiness-based reply rather than a refusal.
    static func fallbackAnswer(for question: String, context: AICoachContext) -> String {
        let lower = question.lowercased()
        let readinessIntent = ["ready", "recover", "recovery", "train", "workout", "work out",
                               "cardio", "run", "ride", "cycle", "bike", "walk", "lift", "session",
                               "today", "tonight", "tomorrow", "rest", "hard", "easy", "should i",
                               "do i", "can i", "zone", "pace", "hrv", "sleep", "fatigue", "deload"]
        if readinessIntent.contains(where: { lower.contains($0) }) {
            return "\(context.readinessLine) \(context.actionLine) \(context.topReasonLine)"
        }
        if lower.contains("progress") || lower.contains("stronger") || lower.contains("record") || lower.contains("pr") {
            return context.recordsLine
        }
        if lower.contains("volume") || lower.contains("muscle") || lower.contains("sets") {
            return context.muscleVolumeLine
        }
        return "Based on your app data right now: \(context.actionLine) \(context.topReasonLine)"
    }
}

struct AICoachContext {
    let prompt: String
    let readinessLine: String
    let actionLine: String
    let topReasonLine: String
    let muscleVolumeLine: String
    let recordsLine: String

    static func build(
        workouts: [WorkoutModel],
        routines: [RoutineModel],
        exercises: [ExerciseLibraryModel],
        recovery: RecoveryEngine.Report,
        suggestion: (routine: RoutineModel, reason: String)? = nil
    ) -> AICoachContext {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        let completed = analytics.completed.sorted { $0.startedAt > $1.startedAt }
        let week = analytics.thisWeek()
        let records = analytics.records()
        let muscleRows = analytics.weeklyMuscleVolume()
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Their name, only if they set a real one — a default "Athlete" would
        // just make the coach greet a placeholder.
        let rawName = UserDefaults.standard.string(forKey: "profileDisplayName")
        let athleteName = (rawName.map { !$0.isEmpty && $0 != "Athlete" } == true) ? rawName : nil

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

        // What the app is actually suggesting they do today, with its exercises
        // and the reason — so "what should I train?" gets a concrete answer
        // instead of a generic one.
        let suggestedSessionLine: String = {
            guard let suggestion else { return "Today's suggested session: none queued right now." }
            let names = suggestion.routine.exercises
                .sorted { $0.position < $1.position }
                .compactMap { exerciseByID[$0.exerciseID]?.name }
                .prefix(6)
                .joined(separator: ", ")
            let exercisesPart = names.isEmpty ? "" : " — \(names)"
            return "Today's suggested session: \(suggestion.routine.name)\(exercisesPart). Why: \(suggestion.reason)"
        }()

        let todayTrainingLine = "Trained today: \(analytics.trainedToday() ? "yes" : "not yet")."

        let prompt = """
        \(athleteName.map { "You're coaching \($0).\n" } ?? "")\(readinessLine)
        \(actionLine)
        \(topReasonLine)
        Confidence: \(Int((recovery.confidence * 100).rounded()))% (lower confidence = sparser data, hedge advice accordingly).
        Missing inputs: \(missing).

        Recovery detail:
        \(systemicLine)
        \(cardioLine)
        \(muscleRecoveryLine)

        \(suggestedSessionLine)

        This week: \(week.workoutCount) workouts, \(Fmt.durationShort(week.durationSeconds)), \(week.sets) working sets, \(week.reps) reps, \(Fmt.volume(week.volume)).
        \(todayTrainingLine)

        Recent workouts:
        \(recentLines.isEmpty ? "- none logged yet" : recentLines.joined(separator: "\n"))

        Current routines:
        \(routineLines.isEmpty ? "- none created yet" : routineLines.joined(separator: "\n"))

        \(muscleVolumeLine)
        \(recordsLine)

        Health/readiness signals:
        \(healthLines.isEmpty ? "- no Health signals connected yet" : healthLines.joined(separator: "\n"))
        """

        return AICoachContext(
            prompt: prompt,
            readinessLine: readinessLine,
            actionLine: actionLine,
            topReasonLine: topReasonLine,
            muscleVolumeLine: muscleVolumeLine,
            recordsLine: recordsLine
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
    /// The coach's structured dose adjustment for today (nil = train as
    /// written) plus the hook that starts the suggested session with it
    /// applied — turns the chat's advice into a one-tap action instead of
    /// leaving the coach read-only.
    let coachPlan: CoachAdjustments.Plan?
    let suggestedRoutineName: String?
    let onApplyPlan: ((CoachAdjustments.Plan) -> Void)?

    @State private var messages: [CoachChatMessage]
    @State private var question = ""
    @State private var isAnswering = false

    init(
        context: AICoachContext,
        coachPlan: CoachAdjustments.Plan? = nil,
        suggestedRoutineName: String? = nil,
        onApplyPlan: ((CoachAdjustments.Plan) -> Void)? = nil
    ) {
        self.context = context
        self.coachPlan = coachPlan
        self.suggestedRoutineName = suggestedRoutineName
        self.onApplyPlan = onApplyPlan
        _messages = State(initialValue: [
            CoachChatMessage(
                role: .coach,
                text: "Hey — I’ve got your training pulled up: readiness, recent sessions, what’s recovered and what isn’t. Ask me anything, or tap a question below to get going."
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
                            if let plan = coachPlan, let onApplyPlan {
                                coachActionCard(plan, apply: onApplyPlan)
                            }
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

                VStack(spacing: Space.sm) {
                    suggestedPrompts
                    coachInput
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(.regularMaterial)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Ask your Coach")
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

    /// One-tap advice→action: start today's suggested session with the
    /// coach's dose applied (same modification path as Home's "coach's
    /// version" button — the saved routine is never touched).
    private func coachActionCard(_ plan: CoachAdjustments.Plan, apply: @escaping (CoachAdjustments.Plan) -> Void) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: plan.action.systemImage)
                        .foregroundStyle(theme.accent)
                    Text("Today's call: \(plan.action.title)")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                }
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                PrimaryButton(
                    title: suggestedRoutineName.map { "Start \($0) — coach dose" } ?? "Start coach's session",
                    systemImage: "play.fill"
                ) {
                    dismiss()
                    apply(plan)
                }
            }
        }
    }

    /// A few one-tap starting points so a blank chat isn't an intimidating
    /// empty text field — each sends immediately, as if typed and submitted.
    /// The coach-dose question only appears when there's actually an adjusted
    /// dose to explain.
    private var suggestedPromptOptions: [String] {
        var options = ["Why this readiness score?"]
        if coachPlan != nil { options.append("What changed in my coach's version?") }
        options.append(contentsOf: ["What should I train today?", "How is my week going?", "Am I making progress?"])
        return options
    }

    private var suggestedPrompts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(suggestedPromptOptions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, 8)
                            .background(theme.surfaceElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnswering)
                }
            }
        }
        .accessibilityLabel("Suggested questions")
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

            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)   // HIG minimum touch target
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

    /// `preset` is a suggested-prompt chip's text sent as-is; nil reads the
    /// text field (the normal typed-and-submitted path).
    private func send(_ preset: String? = nil) {
        let trimmed = (preset ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        question = ""
        messages.append(CoachChatMessage(role: .user, text: trimmed))

        // No client-side relevance gate: the model's own scope instructions
        // decline genuinely off-topic questions and steer back to training, so a
        // keyword allowlist here only ever misfired on valid coaching questions.
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
