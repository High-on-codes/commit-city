// swift-tools-version: 6.0
//
// Commit City: a blueprint city that grows with every commit.
//   • CityKit     — git log parsing, the seeded generator, decay, merging and the shared blueprint
//                   geometry. Pure Swift + Foundation, builds and tests on Linux and Apple platforms.
//   • CityKitUI   — SwiftUI Canvas renderer for the same geometry (Apple platforms only; compiles
//                   to an empty module elsewhere). Used by the widget.
//   • commitcity  — the CLI that writes city.json, city.svg, badges and share cards.
// Zero third-party dependencies.

import PackageDescription

let package = Package(
    name: "CommitCity",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CityKit", targets: ["CityKit"]),
        .library(name: "CityKitUI", targets: ["CityKitUI"]),
        .executable(name: "commitcity", targets: ["commitcity"]),
    ],
    targets: [
        .target(name: "CityKit"),
        .target(name: "CityKitUI", dependencies: ["CityKit"]),
        .executableTarget(name: "commitcity", dependencies: ["CityKit"]),
        .testTarget(name: "CityKitTests", dependencies: ["CityKit"]),
    ],
    swiftLanguageModes: [.v6]
)
