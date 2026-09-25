// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpanishLearningMac",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SpanishLearningMac", targets: ["SpanishLearningMac"])],
    targets: [.executableTarget(name: "SpanishLearningMac", resources: [.process("Resources")])],
    swiftLanguageModes: [.v5]
)
