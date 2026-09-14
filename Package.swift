// swift-tools-version: 5.9
import PackageDescription

// No XCTest: Apple ships it with Xcode, not the Command Line Tools, and this
// package deliberately builds with CLT alone. `switcher-selftest` is a plain
// executable that runs the same assertions and exits non-zero on failure, so it
// works in CI and from a bare toolchain. Swap it for a real .testTarget if Xcode
// is ever installed.
let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitcherKit", targets: ["SwitcherKit"]),
        .executable(name: "switcher", targets: ["switcher"]),
        .executable(name: "SwitcherApp", targets: ["SwitcherApp"]),
    ],
    targets: [
        .target(name: "SwitcherKit", path: "Sources/SwitcherKit"),
        .executableTarget(name: "switcher", dependencies: ["SwitcherKit"], path: "Sources/switcher"),
        .executableTarget(name: "SwitcherApp", dependencies: ["SwitcherKit"], path: "Sources/SwitcherApp"),
        .executableTarget(name: "switcher-selftest", dependencies: ["SwitcherKit"], path: "Tests/SelfTest"),
    ]
)
