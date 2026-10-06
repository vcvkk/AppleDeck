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
        // Husk's floor and Madeira's: the JIT paths that everything else depends on
        // are only reliable from here on. Kept in one place so the app target and
        // this package cannot drift apart.
        .iOS(.v16)
    ],
    products: [
        .library(name: "AppleDeckCore", targets: ["AppleDeckCore"])
    ],
    targets: [
        .target(name: "AppleDeckCore"),
        .testTarget(name: "AppleDeckCoreTests", dependencies: ["AppleDeckCore"])
    ]
)