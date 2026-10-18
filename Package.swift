// swift-tools-version: 6.3

import PackageDescription
import Foundation

// Opt in when developing the four repositories together. Published dependencies
// remain the default and are tested separately in CI.
func ecosystem(_ name: String, from version: Version,
               traits: Set<Package.Dependency.Trait> = [.defaults]) -> Package.Dependency {
    if name == "ESW", let path = ProcessInfo.processInfo.environment["ROOST_ESW_PATH"] {
        return .package(name: "esw", path: path)
    }
    if let root = ProcessInfo.processInfo.environment["ROOST_ECOSYSTEM_PATH"] {
        return .package(name: name.lowercased(), path: "\(root)/\(name == "ESW" ? "esw" : name)", traits: traits)
    }
    return .package(url: "https://github.com/roost-framework/\(name).git", from: version, traits: traits)
}

let package = Package(
    name: "swift-roost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Roost", targets: ["Roost"]),
        .library(name: "RoostTest", targets: ["RoostTest"]),
    ],
    traits: [
        // Off by default: SwiftPM 6.4 cannot resolve a dependency trait enabled through a
        // default trait of a non-root package. Apps opt in with
        // `traits: [.defaults, "RichTerminal"]` on swift-roost, as `roost new` writes it.
        .trait(name: "RichTerminal",
               description: "Colors, spinners, prompts, and styled tables in `roost spectro`, from Spectro's Noora output."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // `roost spectro` builds the app's own spectro command, which needs `CLI`. Roost's
        // `RichTerminal` trait passes Spectro's on; without it spectro prints plain text
        // and Noora is not fetched. `Migrations` gives `App migrate` Spectro's migration
        // command; it shares ArgumentParser with `CLI`.
        ecosystem("Spectro", from: "2.3.1", traits: [
            "CLI", "Migrations",
            .trait(name: "RichTerminal", condition: .when(traits: ["RichTerminal"])),
        ]),
        // Roost doesn't use Nexus's Vapor adapter.
        ecosystem("Nexus", from: "2.1.0", traits: []),
        ecosystem("ESW", from: "1.6.0"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            from: "3.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-metrics.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-distributed-tracing.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "Roost",
            dependencies: [
                .product(name: "SpectroKit", package: "Spectro"),
                .product(name: "SpectroMigrations", package: "Spectro"),
                .product(name: "SpectroCommon", package: "Spectro"),
                .product(name: "Nexus", package: "Nexus"),
                .product(name: "NexusRouter", package: "Nexus"),
                .product(name: "NexusHummingbird", package: "Nexus"),
                .product(name: "ESW", package: "esw"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "RoostTest",
            dependencies: [
                "Roost",
                .product(name: "NexusTest", package: "Nexus"),
            ]
        ),
        .testTarget(
            name: "RoostTests",
            dependencies: [
                "Roost",
                "RoostTest",
                .product(name: "NexusTest", package: "Nexus"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
