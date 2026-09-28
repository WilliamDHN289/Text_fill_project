// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Autocomplete",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // DPHM (Dual-Path Habit Memory): low-latency personal habit memory
        // layer. Pure Foundation — no AppKit/llama deps — so it unit-tests
        // fast and stays embeddable.
        .target(
            name: "DPHMemory",
            path: "Sources/DPHMemory"
        ),
        .testTarget(
            name: "DPHMemoryTests",
            dependencies: ["DPHMemory"],
            path: "Tests/DPHMemoryTests"
        ),
        .executableTarget(
            name: "Autocomplete",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "DPHMemory",
            ],
            path: "Sources/Autocomplete",
            cSettings: [
                .headerSearchPath("../../Frameworks/include"),
            ],
            swiftSettings: [
                .interoperabilityMode(.C),
                .unsafeFlags(["-import-objc-header", "Sources/Autocomplete/AI/LlamaBridge.h"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-blas"),
                .unsafeFlags(["-L\(Context.packageDirectory)/Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "Frameworks"]),
            ]
        )
    ]
)
