// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ReadFlow", targets: ["ReadFlow"])
    ],
    dependencies: [
        // No external dependencies. Apple frameworks only:
        // AppKit, SwiftUI, AVFoundation, PDFKit, Vision, Carbon, Security, Combine.
    ],
    targets: [
        .executableTarget(
            name: "ReadFlow",
            path: "Sources/ReadFlow"
        )
    ]
)
