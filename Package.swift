// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacprFlow",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "MacprFlow", targets: ["MacprFlow"])],
    targets: [
        .executableTarget(name: "MacprFlow"),
        .testTarget(name: "MacprFlowTests", dependencies: ["MacprFlow"])
    ],
    swiftLanguageModes: [.v6]
)
