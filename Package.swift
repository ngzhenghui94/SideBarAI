// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SideBarAI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SideBarAI", targets: ["SideBarAI"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "SideBarAI",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SideBarAI",
            resources: [.process("Assets")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "SideBarAITests",
            dependencies: ["SideBarAI"],
            path: "Tests/SideBarAITests"
        )
    ]
)
