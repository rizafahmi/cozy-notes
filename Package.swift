// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CozyNotes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CozyNotes", targets: ["CozyNotes"])
    ],
    targets: [
        .target(name: "CozyCore"),
        .target(name: "CozySearch", dependencies: ["CozyCore"]),
        .executableTarget(name: "CozyNotes", dependencies: ["CozyCore", "CozySearch"]),
        .testTarget(name: "CozyCoreTests", dependencies: ["CozyCore"]),
        .testTarget(name: "CozySearchTests", dependencies: ["CozySearch", "CozyCore"])
    ]
)
