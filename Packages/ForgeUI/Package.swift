// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeUI",
    platforms: [
        .iOS(.v26), .watchOS(.v26), .macOS(.v26)
    ],
    products: [
        .library(name: "ForgeUI", targets: ["ForgeUI"])
    ],
    targets: [
        .target(
            name: "ForgeUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
