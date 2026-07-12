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
    targets: [
        .target(
            name: "NookKit",
            resources: [.process("Localizable.xcstrings")]
        ),
    ]
)
