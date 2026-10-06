// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import AppleDeckCore

@main
struct AppleDeckApp: App {
    @StateObject private var launcher = LauncherModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(launcher)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var launcher: LauncherModel

    var body: some View {
        // A session takes the whole screen and hides the launcher, the way the
        // Android activity does with immersive sticky mode. There is no
        // half-and-half state to recover from: a session either has the screen
        // or the launcher does.
        if launcher.session.isActive {
            SessionScreen(session: launcher.session)
        } else {
            LauncherScreen()
        }
    }
}

// MARK: - The launcher

/// The rail and the page beside it, which is DroidDeck's launcher in the shape
/// a phone wants: a top tab bar rather than a left rail (a left rail on a
/// portrait phone is a thumb trap), and the same destinations in the same order.
struct LauncherScreen: View {
    @EnvironmentObject private var launcher: LauncherModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $launcher.page) {
                    ForEach(LauncherPage.visible(for: launcher), id: \.self) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        launcher.beginSession(.steam(ui: .bigPicture, url: nil))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(!launcher.canStart)
                }
            }
            .navigationTitle(launcher.page.title)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch launcher.page {
        case .frontEnd:
            FrontEndView(launcher: launcher)
        case .library:
            LibraryView(launcher: launcher)
        case .store:
            StoreView(launcher: launcher)
        case .files:
            FilesView(launcher: launcher)
        case .components:
            ComponentsView(launcher: launcher)
        case .driver:
            DriverView(launcher: launcher)
        case .settings:
            SettingsView()
        case .storeBeta, .cases:
            // Android-only pages (the beta store rail, the keyboard-case
            // screens). They exist so a preferences dump from DroidDeck still
            // round-trips, and they are never reachable here.
            ContentUnavailableViewCompat("Not on iOS", detail: launcher.page.title)
        }
    }
}

/// One page of the launcher. `.cases` is a DroidDeck addition that has no iOS
/// counterpart: a DroidDeck keyboard accessory case, so the page is kept so
/// switching stores does not lose a user's place, and is never shown.
enum LauncherPage: String, CaseIterable, Identifiable {
    case frontEnd, library, store, files, components, driver, settings
    case storeBeta, cases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontEnd: return "Home"
        case .library: return "Library"
        case .store: return "Store"
        case .files: return "Files"
        case .components: return "Components"
        case .driver: return "Driver"
        case .settings: return "Settings"
        case .storeBeta: return "Store (beta)"
        case .cases: return "Cases"
        }
    }

    /// Which pages the tab bar shows: the Store is behind its preference, as on
    /// Android, so a user who never turned it on never sees it.
    static func visible(for launcher: LauncherModel) -> [LauncherPage] {
        var pages: [LauncherPage] = [.frontEnd, .library]
        if launcher.prefs.storeEnabled { pages.append(.store) }
        pages += [.files, .components, .driver, .settings]
        return pages
    }
}