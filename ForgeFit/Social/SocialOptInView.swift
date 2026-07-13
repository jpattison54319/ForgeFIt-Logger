import ForgeData
import SwiftUI

/// The Social opt-in: nothing about the user reaches the public database until
/// they complete this. They pick a unique handle, a display name, and who may
/// follow them (private by default in spirit — approval-required is offered
/// alongside the public option).
struct SocialOptInView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social

    /// Computed fresh at enable time from the local training log.
    let makeSnapshot: () -> ProfileSnapshot

    @AppStorage("profileDisplayName") private var storedName = "Athlete"
    @State private var handle = ""
    @State private var displayName = ""
    @State private var visibility: SocialVisibility = .everyone
    @State private var availability: Availability = .unknown
    @State private var checkTask: Task<Void, Never>?
    @State private var busy = false
    @State private var errorText: String?

    private enum Availability: Equatable { case unknown, checking, available, taken, invalid }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Card {
                        Text("Share your training with friends. Your workouts publish as **training data only** — never your heart rate, sleep, readiness, or body weight. You can turn this off anytime.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }

                    SectionHeader("Handle")
                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack {
                                Text("@").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                                TextField("yourhandle", text: $handle)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityIdentifier("social-handle-field")
                                    .onChange(of: handle) { _, _ in scheduleCheck() }
                                availabilityBadge
                            }
                            Text("3–20 letters, numbers, or _. This is how friends find you.")
                                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        }
                    }

                    SectionHeader("Display name")
                    Card { TextField("Your name", text: $displayName) }

                    SectionHeader("Who can follow you")
                    Card {
                        VStack(spacing: Space.sm) {
                            visibilityRow(.everyone, "Anyone", "Discoverable by handle; anyone can follow and see your workouts.")
                            Divider().overlay(theme.separator)
                            visibilityRow(.approveFollowers, "Approve followers", "Not in global search; you approve each follower.")
                        }
                    }

                    if let errorText {
                        Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
                    }
                    PrimaryButton(title: busy ? "Enabling…" : "Enable Social", systemImage: "person.2.fill") {
                        Task { await enable() }
                    }
                    .disabled(!canEnable || busy)
                    .accessibilityIdentifier("social-optin-confirm")
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("ForgeFit Social")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if displayName.isEmpty { displayName = storedName } }
        }
    }

    private var canEnable: Bool {
        availability == .available && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var availabilityBadge: some View {
        switch availability {
        case .checking: ProgressView().controlSize(.small)
        case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .taken: Image(systemName: "xmark.circle.fill").foregroundStyle(theme.danger)
        case .invalid: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(theme.warmup)
        case .unknown: EmptyView()
        }
    }

    private func visibilityRow(_ value: SocialVisibility, _ title: String, _ subtitle: String) -> some View {
        Button { visibility = value } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: visibility == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(visibility == value ? theme.accent : theme.textTertiary).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        let normalized = SocialHandle.normalize(handle)
        guard SocialHandle.isValid(normalized) else { availability = normalized.isEmpty ? .unknown : .invalid; return }
        availability = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let taken = await social.lookup(handle: normalized) != nil
            guard !Task.isCancelled else { return }
            availability = taken ? .taken : .available
        }
    }

    private func enable() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await social.optIn(handle: handle, displayName: displayName.trimmingCharacters(in: .whitespaces), visibility: visibility, stats: makeSnapshot())
            storedName = displayName.trimmingCharacters(in: .whitespaces)
            dismiss()
        } catch SocialError.handleTaken {
            availability = .taken
            errorText = "That handle was just taken. Try another."
        } catch {
            errorText = "Couldn't enable social. Check your connection and try again."
        }
    }
}
