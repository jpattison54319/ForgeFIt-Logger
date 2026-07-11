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
test-app:
	xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ForgeFitTests

build-ios:
	xcodebuild -project ForgeFit.xcodeproj -scheme ForgeFit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

build-watch:
	xcodebuild -project ForgeFit.xcodeproj -scheme 'ForgeFitWatch Watch App' -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
