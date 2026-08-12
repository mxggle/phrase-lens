// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "NextAITranslatorNative",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "NextAITranslatorNative",
      targets: ["NextAITranslatorNative"]
    )
  ],
  targets: [
    .executableTarget(
      name: "NextAITranslatorNative"
    )
  ]
)
