// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeCore",
    platforms: [
        .iOS(.v26), .watchOS(.v26), .macOS(.v26)
    ],
    products: [
        .library(name: "ForgeCore", targets: ["ForgeCore"])
    ],
    targets: [
        .target(
            name: "ForgeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForgeCoreTests",
            dependencies: ["ForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
