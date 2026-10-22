// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
  name: "MonoAgentStore",
  platforms: [.iOS(.v27), .macOS(.v14)],
  products: [.library(name: "MonoAgentStore", targets: ["MonoAgentStore"])],
  dependencies: [.package(path: "../MonoAgentKit")],
  targets: [
    .target(name: "MonoAgentStore", dependencies: ["MonoAgentKit"]),
    .testTarget(
      name: "MonoAgentStoreTests",
      dependencies: [
        "MonoAgentStore", .product(name: "MonoAgentTestSupport", package: "MonoAgentKit"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
