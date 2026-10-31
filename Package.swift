// swift-tools-version:5.9
import Foundation
import PackageDescription

// sm(SpaceManager)과 Fine이 함께 쓰는 libghostty 터미널 층.
// 두 앱이 같은 엔진·패치·입력 처리를 한 곳에서 고치게 하려고 떼어 냈다(2026-10-31).

// libghostty. scripts/build-ghostty.sh로 Frameworks/에 직접 빌드했으면 그것을 쓰고(패치를 고치는 곳),
// 아니면 이 저장소 릴리스의 미리 빌드한 엔진을 받는다 — 쓰는 쪽은 zig가 없어도 된다.
let localEngine = Context.packageDirectory + "/Frameworks/GhosttyKit.xcframework"
let engine: Target = FileManager.default.fileExists(atPath: localEngine)
    ? .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework")
    : .binaryTarget(
        name: "GhosttyKit",
        url: "https://github.com/oesoll/GhosttyTerminal/releases/download/v0.1.0/GhosttyKit.xcframework.zip",
        checksum: "ba68fdaa7ca90cf6ae212a8f73da473cd03504becfd6d7a93b70bfd94e8d291a"
    )

let package = Package(
    name: "GhosttyTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    targets: [
        engine,
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttyTerminal",
            exclude: ["LICENSE-ghostty"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "GhosttyTerminalTests",
            dependencies: ["GhosttyTerminal", "GhosttyKit"],
            path: "Tests/GhosttyTerminalTests"
        ),
    ]
)
