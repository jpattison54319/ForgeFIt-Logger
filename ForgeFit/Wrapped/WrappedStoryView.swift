import ForgeData
import SwiftData
import SwiftUI

/// The full-screen, story-style Wrapped experience: swipe or tap through
/// pages, segmented progress across the top, per-page share. Renders purely
/// from the report's frozen payload; opening it marks the report viewed
/// (which clears the Home card — the report stays in Profile forever).
struct WrappedStoryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let report: WrappedReportModel

    @State private var payload: WrappedPayload?
    @State private var pageIndex = 0
    @State private var sharePayload: ShareImagePayload?

    var body: some View {
        ZStack {
            if let payload {
                story(payload)
            } else {
                // Undecodable payload (future version, corrupted row) —
                // never a crash, always an exit.
                brokenState
            }
        }
        .onAppear {
            payload = WrappedPayload.decode(from: report.payloadJSON)
            WrappedReportService.markViewed(report, in: modelContext)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.image])
        }
    }

    private func story(_ payload: WrappedPayload) -> some View {
        ZStack(alignment: .top) {
            TabView(selection: $pageIndex) {
                ForEach(Array(payload.pages.enumerated()), id: \.offset) { index, page in
                    WrappedPageView(page: page, periodLabel: payload.periodLabel)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            // Story-style tap zones: right two-thirds advances, left third
            // rewinds. Swipes still work natively via the page TabView.
            .overlay {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { step(-1, in: payload) }
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(1, in: payload) }
                        .frame(maxWidth: .infinity)
                }
                .accessibilityHidden(true)
                // Keep the top controls tappable above the zones.
                .padding(.top, 90)
            }

            VStack(spacing: Space.md) {
                progressBar(count: payload.pages.count)
                HStack {
                    Text(payload.periodLabel)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark") { dismiss() }
                        .accessibilityLabel("Close report")
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.sm)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                share(payload)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 44, height: 44)   // HIG minimum touch target
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Share this page")
            .padding(.trailing, Space.lg)
            .padding(.bottom, Space.xl)
        }
        .background(theme.background.ignoresSafeArea())
    }

    private func step(_ direction: Int, in payload: WrappedPayload) {
        let next = pageIndex + direction
        guard payload.pages.indices.contains(next) else {
            if direction > 0 { dismiss() }  // tapping past the last page exits
            return
        }
        if reduceMotion {
            pageIndex = next
        } else {
            withAnimation(.snappy(duration: 0.3)) { pageIndex = next }
        }
    }

    private func progressBar(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= pageIndex ? theme.accent : theme.textTertiary.opacity(0.35))
                    .frame(height: 3)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: pageIndex)
        .accessibilityLabel("Page \(pageIndex + 1) of \(count)")
    }

    private func share(_ payload: WrappedPayload) {
        guard payload.pages.indices.contains(pageIndex) else { return }
        if let image = WrappedShareRenderer.image(
            page: payload.pages[pageIndex],
            periodLabel: payload.periodLabel,
            theme: .sageDark
        ) {
            sharePayload = ShareImagePayload(image: image)
        }
    }

    private var brokenState: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(theme.textTertiary)
            Text("This report can't be opened")
                .font(.cardTitle)
                .foregroundStyle(theme.textPrimary)
            Text("It may have been created by a newer version of ForgeFit.")
                .font(.label)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            SecondaryButton(title: "Close") { dismiss() }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
    }
}
