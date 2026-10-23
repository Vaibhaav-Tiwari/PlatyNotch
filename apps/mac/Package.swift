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
            ],
            // Sounds (Resources/Sounds, made by scripts/make-sounds.py). Built as
            // PlatyNotch_PlatyNotchUI.bundle; scripts/build-app.sh copies it into
            // Contents/Resources. Read through `UIResources`, never `Bundle.module`.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "PlatyNotch",
            dependencies: ["PlatyNotchKit", "PlatyNotchUI"]
        ),
        .testTarget(
            name: "PlatyNotchKitTests",
            dependencies: ["PlatyNotchKit"],
            exclude: ["Fixtures"]   // read through #filePath
        ),
        .testTarget(name: "PlatyNotchUITests", dependencies: ["PlatyNotchUI"]),
    ]
)
