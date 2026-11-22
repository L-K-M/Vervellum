import SwiftUI
import AppKit
import UpdraftKit

/// What this is, what it does with your data, and where the source lives.
struct AboutView: View {

    @ObservedObject var updateChecker: UpdateChecker

    private static let repositoryURL = URL(string: "https://github.com/L-K-M/Vervellum")!

    var body: some View {
        SettingsPane {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vervellum")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Version \(Bundle.main.shortVersionString)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("A hotkey-summoned research panel for macOS.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            SettingsSection(
                title: "How it answers",
                footnote: "Vervellum plans web searches, runs them, and writes an answer that may "
                    + "cite only the sources it actually retrieved — it refers to them by number, "
                    + "so it has no way to express a link it did not find. It then grades its own "
                    + "claims against that same evidence, and shows you every verdict, including "
                    + "the ones the evidence could not settle.") { EmptyView() }

            SettingsSection(
                title: "What leaves this Mac",
                footnote: "Your question, the thread it belongs to, and the search results go to "
                    + "the two providers you configured, and nowhere else. There is no Vervellum "
                    + "account, no telemetry and no analytics. Threads and preferences stay on "
                    + "this Mac; API keys stay in your Keychain.") { EmptyView() }

            HStack {
                Button("Source & Issues") {
                    NSWorkspace.shared.open(Self.repositoryURL)
                }
                Button("Check for Updates") { updateChecker.checkNow() }
                    .disabled(updateChecker.isChecking)
                Spacer()
            }

            Text("Vervellum is public-domain software (Unlicense), built with substantial help "
                 + "from large language models.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
