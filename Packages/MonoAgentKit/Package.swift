// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
  name: "MonoAgentKit",
  platforms: [.iOS(.v27), .macOS(.v14)],
  products: [
    .library(name: "MonoAgentKit", targets: ["MonoAgentKit"]),
    .library(name: "MonoAgentTestSupport", targets: ["MonoAgentTestSupport"]),
  ],
  targets: [
    .target(name: "MonoAgentKit"),
    .target(name: "MonoAgentTestSupport", dependencies: ["MonoAgentKit"]),
    .testTarget(
      name: "MonoAgentKitTests", dependencies: ["MonoAgentKit", "MonoAgentTestSupport"],
      resources: [.copy("Resources/Contracts")]),
  ],
  swiftLanguageModes: [.v6]
)
