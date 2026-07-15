import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Full-screen editor for the floating quick-action bubble: reorder, remove,
/// and add from the defined pool — one surface, reached only by long-pressing
/// the bubble (collapsed bolt or expanded ✕). The presenting cover supplies
/// the NavigationStack and Done button; this view declares neither.
struct QuickActionsEditorView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]

    /// Held in FAN-VISUAL order — row 1 is the fan's TOP bubble, the last row
    /// sits nearest the button. The store keeps nearest-trigger-first (the
    /// GlassDivisionMenu contract), so load/save reverse at the boundary.
    @State private var actions: [AppQuickAction] = []
    @State private var loaded = false

    private var liveRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && $0.archivedAt == nil }
    }

    private var atMax: Bool { actions.count >= AppQuickActionStore.maxCount }

    var body: some View {
        List {
            Section {
                Text("These shortcuts fan out of the floating button on every tab. The list mirrors the fan: the top row is the top bubble, and the bottom row sits closest to the button.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .themedListRow()
            }

            Section {
                ForEach(actions) { action in
                    actionRow(action)
                        .themedListRow()
                        .deleteDisabled(actions.count <= 1)
                        .accessibilityIdentifier("quick-actions-editor-row-\(action.id)")
                }
                .onMove { source, destination in
                    actions.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    actions.remove(atOffsets: offsets)
                }
            } header: {
                SettingsSectionHeader(title: "Your quick actions")
            } footer: {
                Text(currentSectionFooter)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }

            poolSections

            previewSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        // Always-on edit mode: native drag handles + minus badges on the
        // current-actions rows, mirroring the routine editor's reorder mode.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Quick actions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadOnce)
        // Save-on-change; the bubble re-reads the store when this cover
        // dismisses (ContentView's reload token — the dotted key defeats
        // UserDefaults KVO). The post-load save also scrubs dangling refs
        // from disk — intended.
        .onChange(of: actions) { _, updated in
            guard loaded else { return }
            AppQuickActionStore.save(Array(updated.reversed()))
        }
    }

    private var currentSectionFooter: String {
        if actions.count <= 1 {
            return "Keep at least one action."
        }
        if atMax {
            return "\(AppQuickActionStore.maxCount) of \(AppQuickActionStore.maxCount) — remove one to add another. The cap keeps the fan reachable under your thumb."
        }
        return "\(actions.count) of \(AppQuickActionStore.maxCount) · drag to reorder."
    }

    private func loadOnce() {
        guard !loaded else { return }
        let live = AppQuickActionStore.filterDangling(
            AppQuickActionStore.load(),
            validRoutineIDs: Set(liveRoutines.map(\.id)),
            validYogaSlugs: Set(YogaFlowCatalog.load().map(\.slug))
        )
        // Everything configured may have been deleted since — never present
        // (or persist) an empty list.
        actions = Array((live.isEmpty ? AppQuickActionStore.defaultActions : live).reversed())
        loaded = true
    }

    private func add(_ action: AppQuickAction) {
        guard !atMax, !actions.contains(action) else { return }
        actions.append(action)
    }

    private func actionRow(_ action: AppQuickAction) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon(for: action))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint(for: action))
                .frame(width: 34, height: 34)
                .background(tint(for: action).opacity(0.14))
                .clipShape(Circle())
            Text(title(for: action))
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Add pool (inline — the editor is the whole customization surface)

    @ViewBuilder
    private var poolSections: some View {
        Section {
            poolRow(for: .emptyWorkout, subtitle: "Start logging from a blank workout")
            poolRow(for: .logBodyweight, subtitle: "Write a weigh-in to Apple Health")
        } header: {
            SettingsSectionHeader(title: "Actions")
        }

        Section {
            ForEach(CardioModality.allCases) { modality in
                poolRow(for: .cardio(modality), subtitle: "Quick cardio workout")
            }
        } header: {
            SettingsSectionHeader(title: "Cardio")
        }

        Section {
            ForEach(YogaFlowCatalog.load(), id: \.slug) { seed in
                let plan = YogaFlowCatalog.plan(for: seed)
                poolRow(
                    for: .yoga(seed.slug),
                    title: seed.name,
                    subtitle: "\(seed.style.title) · \(Fmt.durationShort(plan.totalSeconds)) · \(plan.steps.count) poses",
                    systemImage: seed.style.systemImage
                )
            }
        } header: {
            SettingsSectionHeader(title: "Guided Yoga")
        }

        Section {
            if liveRoutines.isEmpty {
                Text("No routines yet. Create them in the Workout tab and they'll appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .themedListRow()
            } else {
                ForEach(liveRoutines) { routine in
                    poolRow(
                        for: .routine(routine.id),
                        title: routine.name,
                        subtitle: "\(routine.exercises.count) exercises"
                    )
                }
            }
        } header: {
            SettingsSectionHeader(title: "Your Routines")
        }
    }

    private func poolRow(
        for action: AppQuickAction,
        title: String? = nil,
        subtitle: String,
        systemImage: String? = nil
    ) -> some View {
        let isAdded = actions.contains(action)
        return Button {
            add(action)
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: systemImage ?? action.systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? action.fallbackTitle)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(isAdded ? theme.success : theme.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(isAdded || atMax)
        .themedListRow()
        .accessibilityIdentifier("quick-actions-pool-\(action.id.replacingOccurrences(of: ":", with: "-"))")
    }

    /// Non-interactive mini-fan mirroring the live order: the list's first
    /// action renders at the bottom, budding directly off the trigger.
    private var previewSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    ForEach(actions) { action in
                        Image(systemName: icon(for: action))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint(for: action))
                            .frame(width: 30, height: 30)
                            .background(tint(for: action).opacity(0.14))
                            .clipShape(Circle())
                    }
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.vertical, Space.sm)
            .themedListRow()
            .accessibilityHidden(true)
        } footer: {
            Text("Bottom bubble sits closest to the button.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func title(for action: AppQuickAction) -> String {
        switch action.kind {
        case .routine(let id): liveRoutines.first { $0.id == id }?.name ?? action.fallbackTitle
        case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug)?.name ?? action.fallbackTitle
        default: action.fallbackTitle
        }
    }

    private func icon(for action: AppQuickAction) -> String {
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
}
