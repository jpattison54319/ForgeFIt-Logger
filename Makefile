# ForgeFit developer tasks.
# The CommandLineTools toolchain does not expose XCTest to SwiftPM, so package
# tests use the full Xcode toolchain.

DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: test-core build-core test-data build-data build-stubs test test-app build-ios build-watch

test-core:
	cd Packages/ForgeCore && swift test

build-core:
	cd Packages/ForgeCore && swift build

test-data:
	cd Packages/ForgeData && swift test

build-data:
	cd Packages/ForgeData && swift build

build-stubs:
	cd Packages/ForgeHealth && swift build
	cd Packages/ForgeWorkoutSession && swift build
	cd Packages/ForgeUI && swift build

test: test-core test-data build-stubs

# App-target unit tests on the iOS simulator. UI tests are excluded here:
# they're slow, and the reset-store ones are known-flaky in CloudKit
# ModelContainer init (retry in isolation before calling a failure real).
# OS= pins a RELEASE runtime: a bare name resolves to the newest installed
# OS — the iOS 27.0 beta — where full-suite sessions lose 600 s to a hung
# "collecting diagnostics" step after the tests pass, and have failed
# outright with "runner never established connection" (the 2026-07-14 hang).
test-app:
	xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ForgeFitTests

build-ios:
	xcodebuild -project ForgeFit.xcodeproj -scheme ForgeFit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

build-watch:
	xcodebuild -project ForgeFit.xcodeproj -scheme 'ForgeFitWatch Watch App' -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
