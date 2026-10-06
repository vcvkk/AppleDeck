// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 AppleDeck contributors
//
// The platform-independent half of AppleDeck: everything the port shares with
// DroidDeck that is a decision rather than a widget. Foundation only, no UIKit,
// so `swift test` runs it on a Linux CI runner and the iOS app imports it as a
// local package. See ios/README.md.
import PackageDescription

let package = Package(
    name: "AppleDeckCore",
    platforms: [
        // Kept in one place so the app target and this package cannot drift
        // apart. The floor is 18 for the Metal texture API; the real one is
        // iOS 26, where TXM makes executable memory a debugger's privilege.
        .iOS(.v18)
    ],
    products: [
        .library(name: "AppleDeckCore", targets: ["AppleDeckCore"])
    ],
    targets: [
        .target(name: "AppleDeckCore"),
        .testTarget(name: "AppleDeckCoreTests", dependencies: ["AppleDeckCore"])
    ]
)