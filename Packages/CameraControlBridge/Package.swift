// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraControlBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CameraBridgeClient", targets: ["CameraBridgeClient"]),
        .executable(name: "camera-control-bridge", targets: ["CameraControlBridge"]),
    ],
    targets: [
        .target(name: "CameraBridgeClient"),
        .target(name: "CameraBridgeCore", dependencies: ["CameraBridgeClient"]),
        .executableTarget(name: "CameraControlBridge", dependencies: ["CameraBridgeCore"]),
        .testTarget(name: "CameraBridgeCoreTests", dependencies: ["CameraBridgeCore"]),
    ]
)
