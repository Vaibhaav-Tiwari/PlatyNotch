// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlatyNotch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlatyNotchKit", targets: ["PlatyNotchKit"]),
        .library(name: "PlatyNotchUI", targets: ["PlatyNotchUI"]),
        .executable(name: "PlatyNotch", targets: ["PlatyNotch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PlatyNotchKit"),
        .target(
            name: "PlatyNotchUI",
            dependencies: [
                "PlatyNotchKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "PlatyNotch",
            dependencies: ["PlatyNotchKit", "PlatyNotchUI"]
        ),
        .testTarget(name: "PlatyNotchKitTests", dependencies: ["PlatyNotchKit"]),
        .testTarget(name: "PlatyNotchUITests", dependencies: ["PlatyNotchUI"]),
    ]
)
