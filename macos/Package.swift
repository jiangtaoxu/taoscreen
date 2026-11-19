// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaoScreen",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "154.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "DesktopVirtualDisplayBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "TaoScreen", dependencies: [.product(name: "WebRTC", package: "WebRTC"),
                                                      .product(name: "Sparkle", package: "Sparkle"),
                                                      "DesktopVirtualDisplayBridge"],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TaoScreenTests", dependencies: ["TaoScreen"])
    ]
)
