// swift-tools-version:5.10
import PackageDescription

// FaceOrbCore and FaceOrbWeb are plain Swift (builds and tests on Linux too).
// FaceOrbKit + the FaceOrb app need macOS (Vision, AppKit, SwiftUI, ONNX Runtime).
var products: [Product] = [
    .library(name: "FaceOrbCore", targets: ["FaceOrbCore"]),
    .library(name: "FaceOrbWeb", targets: ["FaceOrbWeb"]),
    .executable(name: "faceorb-sim", targets: ["faceorb-sim"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "FaceOrbCore"),
    .target(name: "FaceOrbWeb", dependencies: ["FaceOrbCore"], resources: [.copy("Resources")]),
    .executableTarget(name: "faceorb-sim", dependencies: ["FaceOrbCore", "FaceOrbWeb"]),
    .testTarget(name: "FaceOrbCoreTests", dependencies: ["FaceOrbCore", "FaceOrbWeb"], resources: [.copy("Fixtures")]),
]

#if os(macOS)
products.append(.executable(name: "FaceOrb", targets: ["FaceOrb"]))
dependencies.append(.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"))
targets += [
    .target(
        name: "FaceOrbKit",
        dependencies: ["FaceOrbCore", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
    ),
    .executableTarget(name: "FaceOrb", dependencies: ["FaceOrbCore", "FaceOrbKit", "FaceOrbWeb"]),
]
#endif

let package = Package(
    name: "FaceOrb",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
