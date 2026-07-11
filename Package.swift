// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoaOpsCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MoaOpsCore", targets: ["MoaOpsCore"]),
    ],
    targets: [
        .target(name: "MoaOpsCore"),
        .testTarget(name: "MoaOpsCoreTests", dependencies: ["MoaOpsCore"]),
    ]
)
