import AppIntents
import ForgeCore
import SwiftUI
import WidgetKit

struct StartWorkoutControlConfigurationIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Workout"
    static let description = IntentDescription("Choose the workout this control opens.")

    @Parameter(title: "Workout")
    var workout: ForgeFitControlWorkoutEntity?

    init() {}
}

struct ForgeFitStartWorkoutControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "org.xpetsllc.ForgeFit.control.start-workout",
            intent: StartWorkoutControlConfigurationIntent.self
        ) { configuration in
            ControlWidgetButton(
                action: OpenForgeFitControlWorkoutIntent(
                    target: configuration.workout ?? .chooseWorkout
                )
            ) {
                Label(
                    configuration.workout?.name ?? "Choose Workout",
                    systemImage: configuration.workout?.systemImageName ?? "dumbbell.fill"
                )
            }
        }
        .displayName("Start Workout")
        .description("Choose a ForgeFit workout to open with one tap.")
    }
}

struct ForgeFitStartNextWorkoutControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.xpetsllc.ForgeFit.control.start-next") {
            ControlWidgetButton(
                action: OpenForgeFitControlRouteIntent(target: .startNextWorkout)
            ) {
                Label("Start Next Workout", systemImage: "forward.fill")
            }
        }
        .displayName("Start Next Workout")
        .description("Open the next workout in your tracked microcycle.")
    }
}

struct ForgeFitResumeWorkoutControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.xpetsllc.ForgeFit.control.resume-workout") {
            ControlWidgetButton(
                action: OpenForgeFitControlRouteIntent(target: .resumeWorkout)
            ) {
                Label("Resume Workout", systemImage: "arrow.up.forward.app.fill")
            }
        }
        .displayName("Resume Workout")
        .description("Open the ForgeFit workout already in progress.")
    }
}
