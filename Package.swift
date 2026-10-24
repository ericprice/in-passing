// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "InPassing",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "InPassing", targets: ["InPassing"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
                   .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.92.0")],
    targets: [
        .target(name: "InPassingCore"),
        .executableTarget(name: "InPassing", dependencies: ["InPassingCore", .product(name: "Sparkle", package: "Sparkle"), .product(name: "PostHog", package: "posthog-ios")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "InPassingCoreTests", dependencies: ["InPassingCore"]),
        .testTarget(name: "InPassingTests", dependencies: ["InPassing", "InPassingCore"])
    ],
    swiftLanguageModes: [.v5]
)
