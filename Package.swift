// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PhraseLens",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "PhraseLens",
      targets: ["PhraseLens"]
    )
  ],
  targets: [
    .executableTarget(
      name: "PhraseLens"
    )
  ]
)
