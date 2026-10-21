// swift-tools-version: 6.3

import PackageDescription
import Foundation

// Published packages are the default. Contributors can opt into local sources.
let ecosystem = ProcessInfo.processInfo.environment["ROOST_ECOSYSTEM_PATH"]
let frameworkPath = ProcessInfo.processInfo.environment["ROOST_FRAMEWORK_PATH"]
    ?? ecosystem.map { "\($0)/Roost" }
let frameworkDependency: Package.Dependency = frameworkPath.map {
    .package(name: "swift-roost", path: $0)
} ?? .package(url: "https://github.com/roost-framework/swift-roost", from: "2.3.0")
let eswPath = ProcessInfo.processInfo.environment["ROOST_ESW_PATH"]
    ?? ecosystem.map { "\($0)/esw" }
let eswDependency: Package.Dependency = eswPath.map {
    .package(name: "esw", path: $0)
} ?? .package(url: "https://github.com/roost-framework/ESW.git", from: "1.7.0")

let package = Package(
    name: "RoostExample",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        frameworkDependency,
        eswDependency,
    ],
    targets: [
        .executableTarget(
            name: "RoostExample",
            dependencies: [
                .product(name: "Roost", package: "swift-roost"),
                .product(name: "ESW", package: "esw"),
            ],
            resources: [.copy("Migrations/SQL")],
            plugins: [
                .plugin(name: "ESWBuildPlugin", package: "esw"),
            ]
        ),
        .testTarget(
            name: "RoostExampleTests",
            dependencies: [
                "RoostExample",
                .product(name: "RoostTest", package: "swift-roost"),
            ]
        ),
    ]
)
