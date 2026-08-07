import ForgeData
import SwiftData
import SwiftUI

/// Shared destination for every entry point into Experiments. Export is kept
/// here so Home and Insights cannot accidentally offer different privacy
/// behavior: both require the same explicit warning before any files are made.
struct ExperimentsDestinationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    var initialResultsExperimentID: UUID? = nil

    @State private var pendingExport: ExperimentModel?
    @State private var exportBundle: ExperimentExportBundle?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var exportURLsToCleanUp: [URL] = []
    @State private var exportTask: Task<Void, Never>?
    @State private var isVisible = false

    var body: some View {
        ExperimentsHubView(
            workouts: workouts,
            exercises: exercises,
            initialResultsExperimentID: initialResultsExperimentID,
            onExport: { pendingExport = $0 }
        )
        .confirmationDialog(
            "Export this experiment?",
            isPresented: Binding(
                get: { pendingExport != nil },
                set: { if !$0 { pendingExport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Export Data") {
                guard let experimentID = pendingExport?.id else { return }
                pendingExport = nil
                export(experimentID: experimentID)
            }
            Button("Cancel", role: .cancel) {
                pendingExport = nil
            }
        } message: {
            Text(
                "The export can include custom entries, workouts, and Health-derived "
                    + "values. Anything you share leaves ForgeFit’s local-only storage."
            )
        }
        .sheet(item: $exportBundle, onDismiss: cleanUpExportFiles) { bundle in
            ShareSheet(items: bundle.urls)
        }
        .alert(
            "Export couldn’t be created",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                    ProgressView("Preparing private export…")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .padding(Space.lg)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("experiment-export-progress")
            }
        }
        .onAppear {
            isVisible = true
            // A previous process can be killed while the share sheet owns the
            // files. Remove any abandoned private export directories before a
            // new export is allowed.
            ExperimentExportService.cleanupAll()
        }
        .onDisappear {
            isVisible = false
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            cleanUpExportFiles()
        }
    }

    private func export(experimentID: UUID) {
        guard !isExporting else { return }
        isExporting = true
        exportTask?.cancel()
        exportTask = Task { @MainActor in
            defer { isExporting = false }
            do {
                let urls = try await ExperimentExportService.export(
                    experimentID: experimentID,
                    container: modelContext.container
                )
                guard !Task.isCancelled, isVisible else {
                    ExperimentExportService.cleanup(urls: urls)
                    return
                }
                cleanUpExportFiles()
                exportURLsToCleanUp = urls
                exportBundle = ExperimentExportBundle(urls: urls)
            } catch {
                guard !Task.isCancelled, isVisible else { return }
                exportError = error.localizedDescription
            }
            exportTask = nil
        }
    }

    private func cleanUpExportFiles() {
        guard !exportURLsToCleanUp.isEmpty else { return }
        ExperimentExportService.cleanup(urls: exportURLsToCleanUp)
        exportURLsToCleanUp = []
    }
}

private struct ExperimentExportBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}
