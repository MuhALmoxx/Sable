// swift-tools-version: 6.0
// SableKit: platform-independent core of the Sable player.
// Every target here is Foundation-only so it builds and tests on Linux (CI + local toolchain).
import PackageDescription

let package = Package(
    name: "SableKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
        .library(name: "TranslationKit", targets: ["TranslationKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
    ],
    targets: [
        // Cue model, SRT/VTT/ASS parsing, SRT export, Matroska text-track extraction,
        // timing (offsets, sync math, cue lookup).
        .target(name: "SubtitleKit"),
        // Provider-agnostic, chunked, resumable, cached subtitle translation.
        .target(name: "TranslationKit", dependencies: ["SubtitleKit"]),
        // Library items, per-video playback memory, per-track timing persistence.
        .target(name: "LibraryKit", dependencies: ["SubtitleKit"]),

        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TranslationKitTests", dependencies: ["TranslationKit", "SubtitleKit"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit", "SubtitleKit"]),
    ],
    swiftLanguageModes: [.v5]
)
