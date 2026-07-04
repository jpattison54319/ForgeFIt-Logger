// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeData",
    platforms: [
        .iOS(.v26), .watchOS(.v26), .macOS(.v26)
    ],
    products: [
        .library(name: "ForgeData", targets: ["ForgeData"])
    ],
    dependencies: [
        .package(path: "../ForgeCore")
    ],
    targets: [
        .target(
            name: "ForgeData",
            dependencies: ["ForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForgeDataTests",
            dependencies: ["ForgeData", "ForgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
