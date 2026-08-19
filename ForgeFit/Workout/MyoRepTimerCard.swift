import SwiftUI

struct MyoRepTimerCard: View {
    @Environment(\.theme) private var theme
    let setID: UUID
    var timer = RestTimerController.shared

    var body: some View {
        if timer.microOwnerID == setID, timer.isRunning {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .center, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("MICRO-REST")
                            .font(.tag)
                            .foregroundStyle(theme.secondaryAccentForeground)
                        Text(timer.label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Text(Fmt.restTimer(timer.remaining(at: context.date)))
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .foregroundStyle(theme.textPrimary)
                    }
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let remaining = timer.remaining(at: context.date)
                    let fraction = timer.totalSeconds > 0
                        ? Double(remaining) / Double(timer.totalSeconds)
                        : 0
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.secondaryAccent.opacity(0.18))
                            Capsule()
                                .fill(theme.secondaryAccent)
                                .frame(width: max(6, geometry.size.width * fraction))
                        }
                    }
                    .frame(height: 7)
                }

                HStack {
                    Spacer()
                    Button("Skip Rest", systemImage: "forward.end.fill") {
                        timer.skip()
                    }
                    .font(.bodyStrong)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("myo-skip-rest")
                }
            }
            .padding(.vertical, Space.sm)
        }
    }
}
