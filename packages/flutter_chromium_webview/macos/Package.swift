// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_chromium_webview",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .library(name: "flutter-chromium-webview", targets: ["flutter_chromium_webview"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "flutter_chromium_webview",
            dependencies: [
                "CEF",
                "CEFWrapper"
            ],
            path: "Classes",
            publicHeadersPath: "../include",
            cxxSettings: [
                .define("CEF_USE_SANDBOX")
            ]
        ),
        .binaryTarget(
            name: "CEF",
            url: "https://github.com/devflier/flutter_chromium_webview/releases/download/v0.5.0/CEF.xcframework.zip",
            checksum: "ba776406d758d30a434894fef465850e7a5bbcff9580487b05464df7de802d28"
        ),
        .binaryTarget(
            name: "CEFWrapper",
            url: "https://github.com/devflier/flutter_chromium_webview/releases/download/v0.5.0/CEFWrapper.xcframework.zip",
            checksum: "5b22e5f28c4aac0546301057e33b6db024c6894ff49fa5583d9e312d5ec8f83f"
        )
    ],
    cxxLanguageStandard: .cxx20
)
