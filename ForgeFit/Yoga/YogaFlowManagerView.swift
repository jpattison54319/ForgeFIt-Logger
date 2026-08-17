import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

private enum YogaFlowEditTarget: Identifiable {
    case new
    case builtIn(slug: String, name: String, plan: YogaFlowPlan)
    case saved(id: UUID, name: String, plan: YogaFlowPlan)

    var id: String {
        switch self {
        case .new: "new"
        case .builtIn(let slug, _, _): "built-in-\(slug)"
        case .saved(let id, _, _): "saved-\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .new: "New Yoga Flow"
        case .builtIn(_, let name, _): "Customize \(name)"
        case .saved(_, let name, _): "Edit \(name)"
        }
    }

    var planJSON: String? {
        switch self {
        case .new: nil
        case .builtIn(_, _, let plan), .saved(_, _, let plan): plan.encodedJSON()
        }
    }

    var showsTemplates: Bool {
        if case .new = self { return true }
        return false
    }

    var actionLabel: String {
        switch self {
        case .new: "Create yoga flow"
        case .builtIn(_, let name, _): "Customize \(name)"
        case .saved(_, let name, _): "Edit \(name)"
        }
    }
}

private struct PendingYogaFlow {
    let planJSON: String
}

struct YogaFlowManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    @Query(filter: #Predicate<YogaFlowModel> { $0.deletedAt == nil }, sort: \YogaFlowModel.position)
    private var savedFlows: [YogaFlowModel]

    @State private var editTarget: YogaFlowEditTarget?
    @State private var pendingFlow: PendingYogaFlow?
    @State private var flowName = ""
    @State private var flowCreationAttempt: YogaFlowCreationAttempt?

    var body: some View {
        NavigationStack {
            List {
                if !savedFlows.isEmpty {
                    Section("My Flows") {
                        ForEach(savedFlows) { flow in
                            if let plan = flow.plan {
                                flowButton(
                                    name: flow.name,
                                    detail: plan.structureSummary,
                                    target: .saved(id: flow.id, name: flow.name, plan: plan)
                                )
                            }
                        }
                        .onDelete(perform: deleteSavedFlows)
                    }
                }

                Section("Included Classes") {
                    ForEach(YogaFlowCatalog.load(), id: \.slug) { seed in
                        let plan = YogaFlowCatalog.plan(for: seed)
                        flowButton(
                            name: seed.name,
                            detail: plan.structureSummary,
                            target: .builtIn(slug: seed.slug, name: seed.name, plan: plan)
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Yoga Flows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New flow", systemImage: "plus") { editTarget = .new }
                        .accessibilityIdentifier("new-yoga-flow")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .sheet(item: $editTarget) { target in
            YogaFlowBuilderView(
                planJSON: target.planJSON,
                navigationTitle: target.title,
                showsTemplates: target.showsTemplates,
                commit: { json in
                    guard let json else { return false }
                    return save(json, for: target)
                }
            )
        }
        .alert("Save Yoga Flow", isPresented: Binding(
            get: { pendingFlow != nil },
            set: { isPresented in
                if !isPresented, flowCreationAttempt == nil {
                    pendingFlow = nil
                }
            }
        )) {
            TextField("Flow name", text: $flowName)
            Button("Cancel", role: .cancel) { cancelPendingFlow() }
            Button("Save", action: savePendingFlow)
                .disabled(flowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func flowButton(
        name: String,
        detail: String,
        target: YogaFlowEditTarget
    ) -> some View {
        Button { editTarget = target } label: {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(detail).font(.label).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.actionLabel)
    }

    private func save(_ json: String, for target: YogaFlowEditTarget) -> Bool {
        switch target {
        case .new:
            pendingFlow = PendingYogaFlow(planJSON: json)
            flowName = "My Flow"
            flowCreationAttempt = nil
            return true
        case .builtIn(_, let name, _):
            pendingFlow = PendingYogaFlow(planJSON: json)
            flowName = "\(name) Custom"
            flowCreationAttempt = nil
            return true
        case .saved(let id, _, _):
            guard let flow = savedFlows.first(where: { $0.id == id }),
                  let plan = YogaFlowPlan.decode(from: json) else { return false }
            return YogaFlowPersistence.update(
                flow,
                planJSON: json,
                styleRaw: plan.style.rawValue,
                in: modelContext,
                onCommit: { editTarget = nil }
            )
        }
    }

    private func savePendingFlow() {
        guard let pendingFlow,
              let plan = YogaFlowPlan.decode(from: pendingFlow.planJSON) else { return }
        let trimmedName = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt = flowCreationAttempt ?? YogaFlowCreationAttempt(
            name: trimmedName,
            styleRaw: plan.style.rawValue,
            planJSON: pendingFlow.planJSON,
            position: (savedFlows.map(\.position).max() ?? -1) + 1,
            in: modelContext
        )
        flowCreationAttempt = attempt
        attempt.update(
            name: trimmedName,
            styleRaw: plan.style.rawValue,
            planJSON: pendingFlow.planJSON
        )
        attempt.commit(into: modelContext) { _ in
            flowCreationAttempt = nil
            self.pendingFlow = nil
            flowName = ""
        }
    }

    private func cancelPendingFlow() {
        if flowCreationAttempt != nil {
            PersistentChangeSaveCenter.shared.dismiss()
        }
        flowCreationAttempt = nil
        pendingFlow = nil
        flowName = ""
    }

    private func deleteSavedFlows(at offsets: IndexSet) {
        let flows = offsets.compactMap { index in
            savedFlows.indices.contains(index) ? savedFlows[index] : nil
        }
        YogaFlowPersistence.softDelete(flows, in: modelContext)
    }
}
