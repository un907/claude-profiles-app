// swift-tools-version: 5.10
//
// Package manifest for Claude Profiles.
//
// - ClaudeProfilesCore: UI-independent profile / process / shared-config logic (unit tested).
// - ClaudeProfilesApp:  the SwiftUI menu-bar launcher executable. It links Sparkle 2 for
//   self-updates; Scripts/build-app.sh wraps the executable into "Claude Profiles.app" and
//   embeds Sparkle.framework under Contents/Frameworks.

import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeProfilesApp", targets: ["ClaudeProfilesApp"])
    ],
    dependencies: [
        // Sparkle is distributed as a prebuilt binary xcframework. Package.resolved is
        // committed so CI resolves exactly the same binary as local builds.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "ClaudeProfilesCore",
            path: "Sources/ClaudeProfilesCore"
        ),
        .executableTarget(
            name: "ClaudeProfilesApp",
            dependencies: [
                "ClaudeProfilesCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClaudeProfilesApp",
            linkerSettings: [
                // SwiftPM executables only get rpaths pointing at the build directory.
                // Inside the .app bundle Sparkle.framework lives in Contents/Frameworks,
                // so the loader needs this rpath to find it at launch. unsafeFlags is
                // allowed because this is the root package.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ClaudeProfilesCoreTests",
            dependencies: ["ClaudeProfilesCore"],
            path: "Tests/ClaudeProfilesCoreTests"
        )
    ]
)
