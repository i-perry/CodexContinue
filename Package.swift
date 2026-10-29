// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexContinue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexContinue", targets: ["CodexContinue"])
    ],
    targets: [
        .executableTarget(
            name: "CodexContinue",
            path: "Sources/CodexContinue"
        )
    ]
)
