// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRThaiSub",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OCRThaiSub", targets: ["OCRThaiSub"]),
    ],
    targets: [
        // OCR, subtitle stabilisation, and Claude translation (no UI, testable)
        .target(name: "SubtitleCore"),
        // macOS app: capture card input, live preview, Thai overlay
        .executableTarget(name: "OCRThaiSub", dependencies: ["SubtitleCore"]),
        .testTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"]),
    ],
    swiftLanguageModes: [.v5]
)
