// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
  name: "MonoAgentDesign",
  platforms: [.iOS(.v27)],
  products: [.library(name: "MonoAgentDesign", targets: ["MonoAgentDesign"])],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")
  ],
  targets: [
    .target(
      name: "MonoAgentDesign", dependencies: [.product(name: "Markdown", package: "swift-markdown")]
    ),
    .testTarget(name: "MonoAgentDesignTests", dependencies: ["MonoAgentDesign"]),
  ],
  swiftLanguageModes: [.v6]
)
