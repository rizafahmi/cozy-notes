// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CozyNotes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CozyNotes", targets: ["CozyNotes"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2")
    ],
    targets: [
        .target(name: "CozyCore"),
        .executableTarget(name: "CozyNotes", dependencies: ["CozyCore", "SwiftTerm"]),
        .testTarget(name: "CozyCoreTests", dependencies: ["CozyCore"])
    ]
)
