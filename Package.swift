// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inni",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "Inni", targets: ["Inni"]),
        .library(name: "InniCore", targets: ["InniCore"]),
        .library(name: "InniUI", targets: ["InniUI"]),
    ],
    targets: [
        .target(
            name: "InniCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "InniUI",
            dependencies: ["InniCore"]
        ),
        .executableTarget(
            name: "Inni",
            dependencies: ["InniCore", "InniUI"]
        ),
        .testTarget(
            name: "InniCoreTests",
            dependencies: ["InniCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
