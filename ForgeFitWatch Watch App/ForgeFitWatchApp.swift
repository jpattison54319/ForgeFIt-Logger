//
//  ForgeFitWatchApp.swift
//  ForgeFitWatch Watch App
//
//  Created by James Pattison on 6/29/26.
//

import HealthKit
import SwiftUI
import WatchKit

@main
struct ForgeFitWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    WatchStore.shared.activate()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Every wake-up re-checks "phone says a workout is live
                    // but the engine is idle" — collection must never stay
                    // silently stopped just because the app was backgrounded
                    // or relaunched mid-workout.
                    if phase == .active {
                        Task { await WatchStore.shared.recoverOrStartWorkoutSession() }
                    }
                }
        }
    }
}

/// Handles the phone launching us straight into a workout session
/// (`HKHealthStore.startWatchApp`) so a phone-started workout begins live
/// metric collection on the wrist immediately.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            WatchStore.shared.activate()
            WatchStore.shared.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: workoutConfiguration))
        }
    }

    func handleActiveWorkoutRecovery() {
        Task { @MainActor in
            WatchStore.shared.activate()
            await WatchStore.shared.recoverOrStartWorkoutSession()
        }
    }
}
