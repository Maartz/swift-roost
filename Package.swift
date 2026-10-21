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
        .macOS(.v15),
    ],
    products: [
        .library(name: "Roost", targets: ["Roost"]),
        .library(name: "RoostTest", targets: ["RoostTest"]),
    ],
    traits: [
        // No effect since roost-cli dropped `roost spectro`. Declared so apps that enable
        // it, as `roost new` used to write, still resolve.
        .trait(name: "RichTerminal", description: "No effect; kept for apps that enable it."),
        // Off by default, so apps without a Valkey store don't fetch valkey-swift.
        .trait(name: "Valkey",
               description: "A Valkey or Redis server as the app's key-value store: `ROOST_STORE_URL=valkey://…`."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // `Migrations` gives `App migrate` Spectro's migration command. Without `CLI`,
        // apps don't build the spectro executable or fetch Noora.
        ecosystem("Spectro", from: "2.3.1", traits: ["Migrations"]),
        // Roost doesn't use Nexus's Vapor adapter.
        ecosystem("Nexus", from: "2.1.0", traits: []),
        ecosystem("ESW", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.12.1"),
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
        // Used only with the `Valkey` trait. Its other dependencies are already in Roost's graph.
        .package(
            url: "https://github.com/valkey-io/valkey-swift.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            from: "2.29.0"
        ),
        // Background jobs, kept in the app's PostgreSQL database.
        .package(url: "https://github.com/hummingbird-project/swift-jobs.git", from: "1.4.0"),
        .package(url: "https://github.com/hummingbird-project/swift-jobs-postgres.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.1.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.30.1"),
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
                .product(name: "ESWLive", package: "esw"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdHTTP2", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Valkey", package: "valkey-swift", condition: .when(traits: ["Valkey"])),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Jobs", package: "swift-jobs"),
                .product(name: "JobsPostgres", package: "swift-jobs-postgres"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
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
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
