// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SideBarAI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SideBarAI", targets: ["SideBarAI"])
    ],
    targets: [
        .executableTarget(
            name: "SideBarAI",
            path: "Sources/SideBarAI",
            resources: [.process("Assets")]
        ),
        .testTarget(
            name: "SideBarAITests",
            dependencies: ["SideBarAI"],
            path: "Tests/SideBarAITests"
        )
    ]
)
