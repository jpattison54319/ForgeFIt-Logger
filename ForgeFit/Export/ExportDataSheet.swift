import SwiftData
import SwiftUI

/// Format picker for the "export my data" flow: the user chooses JSON or CSV
/// once and every file exports that way, then the standard share sheet takes
/// over (Save to Files, AirDrop, Mail…).
struct ExportDataSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var format: DataExportService.Format = .json
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var sharePayload: ExportFilesPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text("Export data").font(.rowValue).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
            }

            formatOption(
                .json,
                title: "JSON",
                detail: "One complete file: every workout, set, cardio session, GPS route, routine, and the health metrics ForgeFit has stored."
            )
            formatOption(
                .csv,
                title: "CSV",
                detail: "Two spreadsheets: every workout set and every routine. Opens anywhere. GPS routes and per-split data are JSON-only."
            )

            if let exportError {
                Text(exportError)
                    .font(.system(size: 13)).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isExporting {
                HStack(spacing: Space.sm) {
                    ProgressView()
                    Text("Preparing your files…")
                        .font(.bodyStrong).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                PrimaryButton(title: "Export", systemImage: "square.and.arrow.up") {
                    exportNow()
                }
            }
        }
        .padding(Space.lg)
        .background(theme.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.urls)
        }
    }

    private func formatOption(_ option: DataExportService.Format, title: String, detail: String) -> some View {
        Button {
            format = option
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: format == option ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(format == option ? theme.accent : theme.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(format == option ? theme.accent.opacity(0.6) : theme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(format == option ? .isSelected : [])
        .accessibilityIdentifier("export-format-\(option.rawValue)")
    }

    private func exportNow() {
        isExporting = true
        exportError = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let urls = try await DataExportService.export(
                    format: format,
                    container: modelContext.container
                )
                sharePayload = ExportFilesPayload(urls: urls)
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExportFilesPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}
