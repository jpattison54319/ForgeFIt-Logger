# ForgeFit

A native iOS/watchOS training operating system for hybrid athletes: strength,
cardio, and recovery in one system, deeply integrated with HealthKit/watchOS and
synced across devices via CloudKit. Target OS floor: iOS 26 / watchOS 26.

## Status

Early build. Foundations are in progress. The complete epic board lives in
`docs/EPICS.md` and `docs/epics/`.

| | |
|---|---|
| Xcode project | `ForgeFit.xcodeproj` |
| iOS target | `ForgeFit` |
| watchOS target | `ForgeFitWatch Watch App` |
| Planning docs | `docs/` |
| Core/data | `Packages/ForgeCore` and `Packages/ForgeData` |
| Support stubs | `Packages/ForgeHealth`, `Packages/ForgeWorkoutSession`, `Packages/ForgeUI` |
| Schema | `docs/02-schema.sql` (reference DDL mirrored by the SwiftData `@Model`s in `Packages/ForgeData`) |

## Build And Test

The CommandLineTools toolchain does not expose XCTest to SwiftPM, so the
Makefile pins package tests to the full Xcode toolchain.

```bash
make test
make build-ios
make build-watch
```

`make test` runs the ForgeCore and ForgeData package tests and builds the support
package stubs. The iOS app seeds the global exercise library into SwiftData on
launch.

## Design Pillars

- Fast strength logging with deterministic load, volume, and e1RM math.
- Watch-primary workout sessions with correct HealthKit mirroring.
- Honest recovery signals from HRV, resting heart rate, sleep, and training load.
- Privacy-first data ownership with automatic iCloud sync via CloudKit (Apple ecosystem only).
