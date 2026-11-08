// swift-tools-version: 5.9
import PackageDescription
import Foundation

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltFrameworks)
    ? [.unsafeFlags(["-F", cltFrameworks, "-plugin-path", cltPlugins])]
    : []
let testLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(atPath: cltFrameworks)
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : []
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
        .testTarget(name: "CozyCoreTests", dependencies: ["CozyCore"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "CozySearchTests", dependencies: ["CozySearch", "CozyCore"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "CozyNotesTests", dependencies: ["CozyNotes", "CozyCore", "CozySearch"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings)
    ]
)
