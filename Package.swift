// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tobken",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Tobken", targets: ["Tobken"])],
    targets: [
        .target(
            name: "CZstd",
            path: "Vendor/AgentSpeed/Sources/CZstd",
            exclude: ["LICENSE", "VENDOR.md"],
            publicHeadersPath: ".",
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_TRACE", to: "0"),
            ]
        ),
        .target(
            name: "AgentSpeedCore",
            dependencies: ["CZstd"],
            path: "Vendor/AgentSpeed/Sources/AgentSpeedCore",
            // Upstream features Tobken never starts: LAN sharing, profiles, characters, price/exchange-rate
            // fetchers, money formatting, the demo driver and the self-updater. Kept on disk so the pin stays
            // diffable against upstream; see Vendor/AgentSpeed/UPSTREAM.md.
            exclude: [
                "Characters", "DemoDriver.swift", "Lan", "Money", "Network", "Profile",
                "Reporting/ReportStreamSession.swift", "Reporting/URLSessionReportStream.swift",
                "Updates/Release.swift", "Updates/ReleaseNotes.swift", "Updates/SemanticVersion.swift",
                "Updates/UpdateSchedule.swift", "Updates/UpdateURLPolicy.swift", "Updates/ZipDirectory.swift",
            ]
        ),
        .target(name: "TobkenCore", dependencies: ["AgentSpeedCore"]),
        .executableTarget(name: "Tobken", dependencies: ["TobkenCore", "AgentSpeedCore"]),
        .testTarget(name: "TobkenTests", dependencies: ["TobkenCore", "AgentSpeedCore"]),
    ]
)
