// swift-tools-version: 6.0
import PackageDescription

// Atlas is built as a Swift package so it compiles with the Command Line Tools alone.
// Scripts/build-app.sh wraps the executable into Atlas.app.
//
//   AtlasLayout  pure geometry and auto-layout algorithms (no dependencies)
//   AtlasCore    model, store, undo, persistence, import/export (no UI)
//   Atlas        the SwiftUI app
// Swift 5 language mode keeps concurrency checking at the level the UI code is written for.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Atlas",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Atlas", targets: ["Atlas"]),
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .library(name: "AtlasLayout", targets: ["AtlasLayout"]),
    ],
    targets: [
        .target(name: "AtlasLayout", swiftSettings: swift5),
        .target(
            name: "AtlasCore",
            dependencies: ["AtlasLayout"],
            swiftSettings: swift5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Atlas",
            dependencies: ["AtlasCore", "AtlasLayout"],
            swiftSettings: swift5
        ),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"], swiftSettings: swift5),
        .testTarget(name: "AtlasLayoutTests", dependencies: ["AtlasLayout"], swiftSettings: swift5),
    ]
)
