// swift-tools-version:6.0
// llama.cpp's official prebuilt XCFramework (https://github.com/ggml-org/llama.cpp),
// pinned to release b11457 (2026-10-06) by URL and SHA-256 checksum.

import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "llama", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11457/llama-b11457-xcframework.zip",
            checksum: "4c344f0b9ec2c972b2262eb45b2c5b23d6ff4a644135f40642a7a37336e94f1c"
        ),
    ]
)
