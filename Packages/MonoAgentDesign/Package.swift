// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
  name: "MonoAgentDesign",
  platforms: [.iOS(.v27)],
  products: [.library(name: "MonoAgentDesign", targets: ["MonoAgentDesign"])],
  targets: [
    .target(name: "MonoAgentDesign"),
    .testTarget(name: "MonoAgentDesignTests", dependencies: ["MonoAgentDesign"]),
  ],
  swiftLanguageModes: [.v6]
)
