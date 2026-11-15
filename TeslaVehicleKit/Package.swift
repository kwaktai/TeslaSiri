// swift-tools-version: 6.0
import PackageDescription

/// Vendored copy of the TeslaVehicleKit RealityKit loader and the subset of its
/// exported Fleet assets that TeslaSiri can map from Tessie's `car_type`.
/// Source: tesla-extract-models (Tesla Android 4.62.5 asset export).
let package = Package(
    name: "TeslaVehicleKit",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "TeslaVehicleKit", targets: ["TeslaVehicleKit", "TeslaVehicleFleet"])
    ],
    targets: [
        .target(name: "TeslaVehicleKit", resources: [.copy("Shaders")]),
        .target(name: "TeslaVehicleFleet", resources: [.copy("Fleet")])
    ]
)
