// swift-tools-version: 6.0
// Minimal standalone repro for the `isolated deinit` abort seen on macOS 15.x.
// No PlatyNotch code. See README in the workflow `.github/workflows/isolated-deinit-repro.yml`.
import PackageDescription
import Foundation

// Deployment target: 14 by default (below 15.4, so the compiler emits the
// `swift_task_deinitOnExecutorMainActorBackDeploy` shim, like PlatyNotch's macOS 15 target;
// it also lets the same build run on macos-14). REPRO_DEPLOY=15.4 makes the compiler call
// `swift_task_deinitOnExecutor` directly (no shim).
let deploy = ProcessInfo.processInfo.environment["REPRO_DEPLOY"] ?? "14.0"

var swiftSettings: [SwiftSetting] = []
#if compiler(<6.2)
// Before Swift 6.2, `isolated deinit` (SE-0371) is behind an experimental flag.
swiftSettings.append(.enableExperimentalFeature("IsolatedDeinit"))
#endif

let package = Package(
    name: "IsolatedDeinitRepro",
    platforms: [.macOS(deploy)],
    targets: [
        .target(name: "ReproLib", swiftSettings: swiftSettings),
        .executableTarget(name: "Repro", dependencies: ["ReproLib"], swiftSettings: swiftSettings),
        .testTarget(name: "ReproTests", dependencies: ["ReproLib"], swiftSettings: swiftSettings),
    ]
)
