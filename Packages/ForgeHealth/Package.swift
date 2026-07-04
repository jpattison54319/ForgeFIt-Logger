// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeHealth",
    platforms: [
        .iOS(.v26), .watchOS(.v26), .macOS(.v26)
    ],
    products: [
        .library(name: "ForgeHealth", targets: ["ForgeHealth"])
    ],
    targets: [
        .target(
            name: "ForgeHealth",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
