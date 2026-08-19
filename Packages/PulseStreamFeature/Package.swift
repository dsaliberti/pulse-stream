// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PulseStreamFeature",
  platforms: [
    .iOS(.v26),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "PulseStreamFeature",
      targets: ["PulseStreamFeature"]
    ),
  ],
  dependencies: [
    .package(path: "../BluetoothHealth"),
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
    .package(
      url: "https://github.com/pointfreeco/swift-sharing",
      from: "2.9.1"
    ),
  ],
  targets: [
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
        .product(
          name: "Sharing",
          package: "swift-sharing"
        ),
      ]
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
