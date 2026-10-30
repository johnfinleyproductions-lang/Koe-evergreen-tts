// swift-tools-version: 6.0
// Koe for iPad — companion app, built and installed with xtool (no Xcode project).
// The Mac app stays in ../Package.swift; shared code moves into a KoeCore
// library there in Phase 1 and is added here as a path dependency.
import PackageDescription

let package = Package(
    name: "KoeiPad",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // xtool: exactly one library product = the app.
        .library(name: "KoeiPad", targets: ["KoeiPad"]),
    ],
    targets: [
        .target(
            name: "KoeiPad",
            swiftSettings: [.swiftLanguageMode(.v5)]   // strict-concurrency pass comes with the KoeCore split
        ),
    ]
)
