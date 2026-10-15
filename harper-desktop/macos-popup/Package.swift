// swift-tools-version:6.0
// Added in this fork (taehee-pd/harperSwift): native SwiftUI suggestion popup for the macOS
// highlighter. Built and linked by `src-tauri/build_swift.rs`.

import PackageDescription

let package = Package(
    name: "HarperPopup",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HarperPopup", type: .static, targets: ["HarperPopup"])
    ],
    targets: [
        .target(name: "HarperPopup"),
        .testTarget(
            name: "HarperPopupTests",
            dependencies: ["HarperPopup"],
            // Shared with the Rust tests; read from disk by path.
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
