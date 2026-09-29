// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpanishLearningMac",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SpanishLearningMac", targets: ["SpanishLearningMac"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SpanishLearningMac",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageModes: [.v5]
)
