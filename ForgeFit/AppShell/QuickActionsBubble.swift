import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// The floating quick-action trigger above the tab bar on every tab: tapping
/// it fans the user's configured shortcuts out of a cell-division morph;
/// long-pressing opens the editor. Which actions appear — and their order,
/// nearest the trigger first — is the `AppQuickActionStore` preference, edited
/// only by long-pressing the main button (collapsed bolt or expanded ✕).
struct QuickActionsBubble: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let routines: [RoutineModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    /// Bumped by the shell's scrim to collapse the fan from outside.
    var collapseSignal: Int
    /// Bumped by the shell when the editor dismisses (or the account resets)
    /// so the fan re-reads the store. Deliberately NOT @AppStorage: the key
    /// contains a dot ("quickActionBubble.v1"), and UserDefaults KVO — which
    /// @AppStorage relies on to see external writes — treats dots as key-path
    /// separators, so the editor's store writes would never propagate here.
    var reloadToken: Int
    var onExpandedChange: (Bool) -> Void
    var onOpenEditor: () -> Void
    var onLogBodyweight: () -> Void

    @State private var expandedMirror = false
    @State private var actionTick = 0

    private var actions: [AppQuickAction] {
        _ = reloadToken
        let configured = AppQuickActionStore.load()
        let live = AppQuickActionStore.filterDangling(
            configured,
            validRoutineIDs: Set(routines.filter { $0.deletedAt == nil && $0.archivedAt == nil }.map(\.id)),
            validYogaSlugs: Set(YogaFlowCatalog.load().map(\.slug))
        )
        // If everything the user configured has since been deleted, fall back
        // to the defaults — the trigger must never open an empty fan.
        return live.isEmpty ? AppQuickActionStore.defaultActions : live
    }

    var body: some View {
        GlassDivisionMenu(
            items: actions.map(item(for:)),
            direction: .up,
            // Vertical fan with captions: the label lives in the inter-bubble
            // gap, so the gap must hold a caption line plus breathing room.
            gap: 32,
            showsLabels: true,
            // Bubble center sits ~46pt from the right screen edge; centered
            // captions wider than ~92pt would clip. 88 keeps them on-screen.
            labelMaxWidth: 88,
            // Clear see-through glass on trigger and bubbles alike, matching
            // the tab bar — the glyphs alone carry the color.
            bubbleGlassTintOpacity: 0,
            // Root-level native glass leaves compositor particles behind as
            // the vertical fan crosses cards and the tab bar. The material
            // relay keeps the same frosted look while every child follows a
            // deterministic parent-to-child path.
            usesStableMaterialRelay: true,
            dismissCaption: "Hold to edit",
            triggerAccessibilityLabel: "Quick actions",
            triggerAccessibilityHint: "Shortcuts to start a workout or log your weight. Long press to customize.",
            triggerAccessibilityID: "quick-actions-trigger",
            dismissAccessibilityHint: "Long press to customize.",
            dismissAccessibilityID: "quick-actions-dismiss",
            onExpandedChange: { expanded in
                expandedMirror = expanded
                onExpandedChange(expanded)
            },
            collapseSignal: collapseSignal,
            onTriggerLongPress: onOpenEditor
        ) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.accent)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: expandedMirror)
        .sensoryFeedback(.selection, trigger: actionTick)
    }

    private func item(for action: AppQuickAction) -> GlassDivisionItem {
        GlassDivisionItem(
            id: action.id,
            systemImage: systemImage(for: action),
            label: caption(for: action),
            accessibilityLabel: accessibilityLabel(for: action),
            tint: tint(for: action),
            accessibilityID: accessibilityID(for: action)
        ) {
            perform(action)
        }
    }

    /// Short caption under the bubble; the width cap tail-truncates long
    /// routine/flow names. Full phrasing lives in the accessibility label.
    private func caption(for action: AppQuickAction) -> String {
        switch action.kind {
        case .emptyWorkout: "Empty"
        case .logBodyweight: "Weight"
        case .cardio(let modality): modality.title
        case .routine(let id): routines.first { $0.id == id }?.name ?? action.fallbackTitle
        case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug)?.name ?? action.fallbackTitle
        }
    }

    private func accessibilityLabel(for action: AppQuickAction) -> String {
        switch action.kind {
        case .emptyWorkout: "Start empty workout"
        case .logBodyweight: "Log bodyweight"
        case .cardio(let modality): "Start \(modality.title)"
        case .routine(let id): "Start \(routines.first { $0.id == id }?.name ?? "routine")"
        case .yoga(let slug): "Start \(YogaFlowCatalog.flow(forSlug: slug)?.name ?? "yoga")"
        }
    }

    private func systemImage(for action: AppQuickAction) -> String {
        switch action.kind {
        case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug)?.style.systemImage ?? action.systemImage
        default: action.systemImage
        }
    }

    private func tint(for action: AppQuickAction) -> Color {
        switch action.kind {
        case .emptyWorkout, .routine: theme.accent
        case .cardio: theme.secondaryAccent
        case .yoga: theme.success
        case .logBodyweight: theme.warmup
        }
    }

    private func accessibilityID(for action: AppQuickAction) -> String {
        switch action.kind {
        case .emptyWorkout: "quick-action-empty"
        case .logBodyweight: "quick-action-bodyweight"
        case .cardio(let modality): "quick-action-cardio-\(modality.rawValue)"
        case .routine(let id): "quick-action-routine-\(id.uuidString)"
        case .yoga(let slug): "quick-action-yoga-\(slug)"
        }
    }

    /// Workout starts mirror Home's quick-start row and the deep-link router:
    /// resolve inside `requestStart` (it can run after the replace-workout
    /// confirm), start via the factory, present the root logger.
    private func perform(_ action: AppQuickAction) {
        actionTick += 1
        switch action.kind {
        case .emptyWorkout:
            appState.requestStart {
                _ = WorkoutFactory.startEmpty(in: modelContext)
                appState.showingLogger = true
            }
        case .cardio(let modality):
            appState.requestStart {
                _ = WorkoutFactory.startCardio(modality, exercises: exercises, in: modelContext)
                appState.showingLogger = true
            }
        case .routine(let id):
            appState.requestStart {
                guard let routine = routines.first(where: { $0.id == id && $0.deletedAt == nil && $0.archivedAt == nil }) else { return }
                _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
                appState.showingLogger = true
            }
        case .yoga(let slug):
            appState.requestStart {
                guard let seed = YogaFlowCatalog.flow(forSlug: slug) else { return }
                _ = WorkoutFactory.startYoga(
                    flow: YogaFlowCatalog.plan(for: seed),
                    named: seed.name,
                    exercises: exercises,
                    in: modelContext
                )
                appState.showingLogger = true
            }
        case .logBodyweight:
            onLogBodyweight()
        }
    }
}
