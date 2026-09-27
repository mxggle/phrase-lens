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
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
  ],
  targets: [
    .executableTarget(
      name: "PhraseLens",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      resources: [
        .copy("Resources/Dictionaries"),
        .process("Resources/en.lproj"),
        .process("Resources/zh-Hans.lproj")
      ],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
  ]
)
