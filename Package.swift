// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChassisWatcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ChassisWatcher",
            path: "Sources/ChassisWatcher"
        )
    ]
)
