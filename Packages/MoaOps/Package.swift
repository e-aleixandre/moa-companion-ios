// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MoaOpsCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MoaOpsCore", targets: ["MoaOpsCore"]),
        .library(name: "MoaOpsPresentation", targets: ["MoaOpsPresentation"]),
    ],
    targets: [
        .target(name: "MoaOpsCore"),
        .target(name: "MoaOpsPresentation", dependencies: ["MoaOpsCore"]),
        .testTarget(name: "MoaOpsCoreTests", dependencies: ["MoaOpsCore"]),
        .testTarget(name: "MoaOpsPresentationTests", dependencies: ["MoaOpsPresentation", "MoaOpsCore"]),
    ]
)
