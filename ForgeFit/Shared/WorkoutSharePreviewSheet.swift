import CoreLocation
import ForgeData
import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The share picker: a swipeable carousel of pre-rendered card styles with
/// Save Image / Share buttons acting on the visible page. Pages are rendered
/// to `UIImage` up front (selected style first) so the preview is
/// pixel-identical to what lands in Photos, and a style with no substance for
/// this workout simply isn't offered.
struct WorkoutSharePreviewSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    var hrSamples: [(date: Date, bpm: Int)] = []
    var recoveryPoints: [SetRecoveryPoint] = []

    /// Opens on the style picked last time, when this workout offers it.
    @AppStorage("shareCardStyle.last") private var lastStyleRaw = ShareCardStyle.trainingLog.rawValue

    @State private var selection: ShareCardStyle = .trainingLog
    @State private var pages: [ShareCardStyle: UIImage] = [:]
    @State private var sharePayload: ShareImagePayload?
    @State private var showSavedToast = false
    @State private var showSaveFailed = false

    private var styles: [ShareCardStyle] {
        let summary = TrainingAnalytics(workouts: [workout], exercises: exercises).summary(for: workout)
        return ShareCardStyle.available(workout: workout, summary: summary, hasHRSamples: !hrSamples.isEmpty)
    }

    var body: some View {
        VStack(spacing: Space.md) {
            HStack {
                Text("Share workout").font(.rowValue).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)

            TabView(selection: $selection) {
                ForEach(styles) { style in
                    page(style)
                        .tag(style)
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.lg)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Text(selection.displayName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: Space.md) {
                SecondaryButton(title: "Save Image", systemImage: "square.and.arrow.down") {
                    saveCurrentImage()
                }
                PrimaryButton(title: "Share", systemImage: "square.and.arrow.up") {
                    guard let image = pages[selection] else { return }
                    sharePayload = ShareImagePayload(image: image)
                }
            }
            .disabled(pages[selection] == nil)
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.lg)
        }
        .background(theme.background)
        .overlay(alignment: .bottom) { savedToast }
        .task { await renderPages() }
        .onAppear {
            let last = ShareCardStyle(rawValue: lastStyleRaw)
            selection = last.flatMap { styles.contains($0) ? $0 : nil } ?? styles.first ?? .full
        }
        .onChange(of: selection) { _, newValue in
            lastStyleRaw = newValue.rawValue
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.image])
        }
        .alert("Couldn't save", isPresented: $showSaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow ForgeFit to add to your photo library in Settings → Privacy → Photos.")
        }
    }

    @ViewBuilder
    private func page(_ style: ShareCardStyle) -> some View {
        if let image = pages[style] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.separator, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: Space.sm) {
                ProgressView()
                Text("Rendering…").font(.tag).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Rendering

    /// Renders every offered style, visible page first, yielding between
    /// renders so the carousel stays responsive. Route maps are snapshotted
    /// once up front (MapKit can't be rasterized by ImageRenderer).
    private func renderPages() async {
        var routeMaps: [UUID: UIImage] = [:]
        for session in workout.cardioSessions where session.deletedAt == nil {
            let coordinates = session.routePoints
                .sorted { $0.timestamp < $1.timestamp }
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            if coordinates.count >= 2,
               let map = await RouteMapSnapshot.image(coordinates: coordinates, size: WorkoutShareCard.routeMapSize, theme: theme) {
                routeMaps[session.id] = map
            }
        }
        let ordered = [selection] + styles.filter { $0 != selection }
        for style in ordered where pages[style] == nil {
            pages[style] = render(style, routeMaps: routeMaps)
            await Task.yield()
        }
    }

    @MainActor
    private func render(_ style: ShareCardStyle, routeMaps: [UUID: UIImage]) -> UIImage? {
        switch style {
        case .trainingLog:
            return ShareRenderer.image(
                WorkoutShareCardTrainingLog(workout: workout, exercises: exercises, theme: theme, routeMaps: routeMaps),
                theme: theme
            )
        case .metrics:
            return ShareRenderer.image(
                WorkoutShareCardMetrics(
                    workout: workout,
                    exercises: exercises,
                    theme: theme,
                    hrSamples: hrSamples,
                    recoveryPoints: recoveryPoints
                ),
                theme: theme
            )
        case .minimal:
            return ShareRenderer.image(
                WorkoutShareCardMinimal(workout: workout, exercises: exercises, theme: theme),
                theme: theme
            )
        case .full:
            return WorkoutShareRenderer.image(
                for: workout,
                exercises: exercises,
                theme: theme,
                hrSamples: hrSamples,
                recoveryPoints: recoveryPoints,
                routeMaps: routeMaps
            )
        }
    }

    // MARK: - Saving

    /// Add-only Photos write — the system shows its own permission prompt on
    /// first use (NSPhotoLibraryAddUsageDescription is in the plist).
    private func saveCurrentImage() {
        guard let image = pages[selection] else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, _ in
            Task { @MainActor in
                if success {
                    showSavedToast = true
                    try? await Task.sleep(for: .seconds(2))
                    showSavedToast = false
                } else {
                    showSaveFailed = true
                }
            }
        }
    }

    @ViewBuilder
    private var savedToast: some View {
        if showSavedToast {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                Text("Saved to Photos").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.surfaceElevated)
            .clipShape(Capsule())
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
