import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WorkoutHistoryImportView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]

    @State private var pickingFile = false
    @State private var loading = false
    @State private var preview: WorkoutHistoryImportPreview?
    @State private var result: WorkoutHistoryImportCommitResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    introCard
                    if let result {
                        resultCard(result)
                    } else if let preview {
                        previewCard(preview)
                        exerciseMatchCard(preview)
                        warningsCard(preview)
                        PrimaryButton(title: "Import \(preview.importableCount) Workouts", systemImage: "square.and.arrow.down.fill") {
                            commit(preview)
                        }
                        .disabled(loading || preview.importableCount <= 0)
                    } else {
                        emptyPickerCard
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Import History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $pickingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText, .text],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
    }

    private var introCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bring your old workouts")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Hevy CSV, common CSV exports, or ForgeFit JSON")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                Text("ForgeFit previews the file, skips duplicate imports, matches exercises to your library, and converts weights into the app’s internal history format.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    result = nil
                    errorMessage = nil
                    pickingFile = true
                } label: {
                    Label(preview == nil ? "Choose File" : "Choose Different File", systemImage: "doc.badge.plus")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
                .disabled(loading)
            }
        }
    }

    private var emptyPickerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Supported in v1")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                VStack(alignment: .leading, spacing: Space.sm) {
                    supportRow("checkmark.circle.fill", "Hevy workouts.csv gets first-class parsing.")
                    supportRow("checkmark.circle.fill", "Strong, Fitbod, HeavySet, and simple custom CSVs use common header detection.")
                    supportRow("info.circle.fill", "Excel and Google Sheets should be exported as CSV before importing.")
                }
                if loading {
                    ProgressView("Reading file…")
                        .tint(theme.accent)
                        .foregroundStyle(theme.textSecondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.danger)
                }
            }
        }
    }

    private func supportRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(icon.hasPrefix("checkmark") ? theme.success : theme.textTertiary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Preview")
            Card {
                VStack(spacing: Space.md) {
                    summaryRow("Source", preview.parseResult.source.displayName)
                    Divider().overlay(theme.separator)
                    summaryRow("File", preview.parseResult.fileName)
                    Divider().overlay(theme.separator)
                    summaryRow("Workouts", "\(preview.parseResult.workouts.count)")
                    Divider().overlay(theme.separator)
                    summaryRow("Will import", "\(preview.importableCount)")
                    Divider().overlay(theme.separator)
                    summaryRow("Duplicates skipped", "\(preview.duplicateCount)")
                    if let range = preview.dateRange {
                        Divider().overlay(theme.separator)
                        summaryRow("Date range", "\(range.lowerBound.formatted(.dateTime.month(.abbreviated).day().year())) – \(range.upperBound.formatted(.dateTime.month(.abbreviated).day().year()))")
                    }
                }
            }
        }
    }

    private func exerciseMatchCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Exercise Matching")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    summaryRow("Matched", "\(preview.matches.filter { !$0.willCreateCustom }.count)")
                    Divider().overlay(theme.separator)
                    summaryRow("Create custom", "\(preview.customExerciseCount)")
                    if preview.customExerciseCount > 0 {
                        Divider().overlay(theme.separator)
                        ForEach(preview.matches.filter(\.willCreateCustom).prefix(8)) { match in
                            HStack {
                                Text(match.importedName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Tag(text: "New", color: theme.warmup, background: theme.warmup.opacity(0.15))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func warningsCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        if !preview.parseResult.warnings.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                SectionHeader("Warnings")
                Card {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(preview.parseResult.warnings.prefix(6)) { warning in
                            Text(warning.message)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if preview.parseResult.warnings.count > 6 {
                            Text("+\(preview.parseResult.warnings.count - 6) more")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func resultCard(_ result: WorkoutHistoryImportCommitResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import complete")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Imported history now contributes to stats and exercise records.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Divider().overlay(theme.separator)
                summaryRow("Imported workouts", "\(result.importedWorkouts)")
                summaryRow("Duplicates skipped", "\(result.skippedDuplicates)")
                summaryRow("Custom exercises", "\(result.createdExercises)")
                Button("Done") { dismiss() }
                    .font(.bodyStrong)
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: Space.md)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            load(url)
        }
    }

    private func load(_ url: URL) {
        loading = true
        errorMessage = nil
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            Task {
                do {
                    preview = try await WorkoutHistoryImportService.preview(
                        data: data,
                        fileName: fileName,
                        workouts: workouts,
                        exercises: exercises
                    )
                } catch {
                    preview = nil
                    errorMessage = error.localizedDescription
                }
                loading = false
            }
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    private func commit(_ preview: WorkoutHistoryImportPreview) {
        loading = true
        errorMessage = nil
        do {
            result = try WorkoutHistoryImportService.commit(
                preview: preview,
                workouts: workouts,
                exercises: exercises,
                in: modelContext
            )
            self.preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
