// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NookKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "NookKit", targets: ["NookKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "NookKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Readability.js"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "NookKitTests",
            dependencies: ["NookKit"]
        ),
    ]
)
