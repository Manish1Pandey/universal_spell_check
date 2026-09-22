// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "universal_spell_check",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "universal-spell-check", targets: ["universal_spell_check"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "universal_spell_check",
            dependencies: [],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
