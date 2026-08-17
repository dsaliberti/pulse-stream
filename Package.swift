// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PulseStream",
  platforms: [
    .iOS(.v26),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "BluetoothHealth",
      targets: ["BluetoothHealth"]
    ),
    .library(
      name: "PulseStreamFeature",
      targets: ["PulseStreamFeature"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.26.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-custom-dump",
      from: "1.7.0"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-dependencies",
      from: "1.15.0"
    ),
  ],
  targets: [
    .target(name: "BluetoothHealth"),
    .target(
      name: "PulseStreamFeature",
      dependencies: [
        "BluetoothHealth",
        .product(
          name: "ComposableArchitecture",
          package: "swift-composable-architecture"
        ),
        .product(
          name: "Dependencies",
          package: "swift-dependencies"
        ),
      ]
    ),
    .testTarget(
      name: "BluetoothHealthTests",
      dependencies: ["BluetoothHealth"]
    ),
    .testTarget(
      name: "PulseStreamFeatureTests",
      dependencies: [
        "PulseStreamFeature",
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),
  ]
)
