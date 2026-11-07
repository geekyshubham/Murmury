// swift-tools-version:5.10
import PackageDescription

// Command Line Tools ship swift-testing outside the default search paths.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Murmury",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MurmuryKit",
            path: "Sources/MurmuryKit",
            swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CreateML"),
                .linkedFramework("CoreML"),
                .linkedFramework("Speech"),
            ]
        ),
        .executableTarget(name: "Murmury", dependencies: ["MurmuryKit"], path: "Sources/Murmury"),
        .executableTarget(
            name: "murmury-tests",
            dependencies: ["MurmuryKit"],
            path: "Tests/MurmuryTests",
            exclude: ["Fixtures"],
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", cltFrameworks, "-framework", "Testing",
                "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", cltLib,
            ])]
        ),
    ]
)
