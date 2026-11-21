import SwiftUI

/// What the panel shows before the first question.
///
/// Two states, and the difference matters: an app that is ready shows what it is for,
/// while an app that is missing its keys shows *only* that, with the fix one click
/// away. Mixing the two — a friendly welcome with a small warning at the bottom —
/// produces a first run where the user types a question and gets an error.
struct EmptyStateView: View {

    @Environment(\.panelTextScale) private var textScale

    let configurationProblems: [String]
    let searches: Bool
    let summonShortcut: String
    var onOpenSettings: () -> Void
    /// Loads the composer with the example — seeding, not submitting. The user
    /// should be able to edit or discard a suggestion, not be committed to it.
    var onSeedComposer: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.large) {
            if configurationProblems.isEmpty { ready } else { setup }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.medium) {
            Text("Ask a question.")
                .font(PanelTheme.Font.at(15, textScale, weight: .semibold))
                .foregroundStyle(PanelTheme.Palette.primaryText)
            Text(searches
                 ? "Vervellum plans web searches, runs them, then writes an answer that "
                    + "cites only what it found — and grades its own claims against that evidence."
                 : "No search sends the question only to the selected model. It does not "
                    + "search, cite sources, or run the evidence assessment.")
                .font(PanelTheme.Font.body(textScale))
                .foregroundStyle(PanelTheme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                hint("Return", "ask · Shift-Return for a new line")
                hint("/", "commands — and the four research levels by name")
                hint("Esc", "clear the draft, then close")
                // The feature nobody finds: dropped files and pasted images go
                // with the question, and the empty state is the one place that
                // can say so before it is needed.
                hint("Drop / ⌘V", "a file or image in the composer to attach it")
                hint(summonShortcut, "summon or dismiss from anywhere")
            }
            .padding(.top, PanelTheme.Space.small)

            // Three questions that show what the tool is for: current, checkable,
            // and worth citing. Clicking one seeds the composer.
            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                Text("TRY")
                    .font(PanelTheme.Font.label(textScale))
                    .tracking(0.7)
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                ForEach(Self.examples, id: \.self) { example in
                    Button { onSeedComposer(example) } label: {
                        Text(example)
                            .font(PanelTheme.Font.caption(textScale))
                            .foregroundStyle(PanelTheme.Palette.accent)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, PanelTheme.Space.medium)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.medium) {
            Label("Not configured yet", systemImage: "key")
                .font(PanelTheme.Font.at(14, textScale, weight: .semibold))
                .foregroundStyle(PanelTheme.Palette.verdict(.mixed))
            Text(configurationProblems.joined(separator: " "))
                .font(PanelTheme.Font.body(textScale))
                .foregroundStyle(PanelTheme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Provider keys stay in the Keychain and are sent only to the provider "
                 + "each one belongs to.")
                .font(PanelTheme.Font.caption(textScale))
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings", action: onOpenSettings)
                .font(PanelTheme.Font.body(textScale))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(PanelTheme.Palette.accent)
        }
    }

    private static let examples: [String] = [
        "Summarize today's top technology news",
        "Is Pluto a planet? What do astronomers currently say?",
        "Compare OLED and mini-LED displays for a laptop",
    ]

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
            Text(key)
                .font(PanelTheme.Font.citation(textScale))
                .foregroundStyle(PanelTheme.Palette.primaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(PanelTheme.Palette.chipFill,
                            in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip, style: .continuous))
            Text(meaning)
                .font(PanelTheme.Font.caption(textScale))
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
            Spacer(minLength: 0)
        }
    }
}
