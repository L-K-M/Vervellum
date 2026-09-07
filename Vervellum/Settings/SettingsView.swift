import SwiftUI

/// The settings window: five panes, in the order a new user needs them.
///
/// Providers comes first because nothing works until it is filled in — a settings
/// window whose first pane is "Appearance" makes an unconfigured app look broken
/// rather than unfinished. Appearance comes last before About for the same reason: it
/// is the pane people spend the longest in and the one they need least on day one.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var store: ThreadStore
    @ObservedObject var updateChecker: UpdateChecker
    var onShortcutsChanged: () -> Void

    var body: some View {
        TabView {
            ProvidersView(preferences: preferences)
                .tabItem { Label("Providers", systemImage: "key") }
            ShortcutsView(preferences: preferences, onChanged: onShortcutsChanged)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            GeneralView(preferences: preferences, store: store, updateChecker: updateChecker)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceView(preferences: preferences)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutView(updateChecker: updateChecker)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 540, minHeight: 480)
        .padding(.top, 8)
    }
}

/// A settings pane's standard scaffolding: a scrolling form with consistent padding.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// A titled group of related controls with an explanatory footnote.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
