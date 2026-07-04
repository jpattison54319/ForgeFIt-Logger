// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeWorkoutSession",
    platforms: [
        .iOS(.v26), .watchOS(.v26), .macOS(.v26)
    ],
    products: [
        .library(name: "ForgeWorkoutSession", targets: ["ForgeWorkoutSession"])
    ],
    dependencies: [
        .package(path: "../ForgeCore")
    ],
    targets: [
        .target(
            name: "ForgeWorkoutSession",
            dependencies: ["ForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
