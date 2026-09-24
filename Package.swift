// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PhraseLens",
  defaultLocalization: "en",
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
      name: "PhraseLens",
      resources: [
        .copy("Resources/Dictionaries"),
        .process("Resources/en.lproj"),
        .process("Resources/zh-Hans.lproj")
      ]
    )
  ]
)
