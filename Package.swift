// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ranunculus",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CVosk",
            path: "Sources/CVosk",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "whisper",
            path: "Frameworks/whisper.xcframework"
        ),
        .executableTarget(
            name: "Ranunculus",
            dependencies: ["CVosk", "whisper"],
            path: "Sources/Ranunculus",
            linkerSettings: [
                .unsafeFlags(["-L", "Libraries", "-lvosk"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "Libraries"])
            ]
        )
    ]
)
