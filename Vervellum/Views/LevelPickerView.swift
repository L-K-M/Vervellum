import SwiftUI

/// The four research levels, with what each does and what it may spend.
///
/// Shown from the chip above the composer. Every row carries its own explanation rather
/// than hiding it behind a hover, because the control exists to answer a question the
/// panel could not answer before — what the difference between these four *is* — and an
/// explanation a keyboard cannot reach does not answer it.
///
/// The two rules come from `ResearchLevel.beginsGroup`, and they are the honest part of
/// the design: the levels are drawn as a ladder because they are ordered by cost, but
/// only the middle pair is a ladder in the sense of "the same thing, more of it". A rule
/// is drawn where that stops being true, and the footer says what the order is on.
struct LevelPickerView: View {

    @Environment(\.panelTextScale) private var textScale

    let selected: ResearchLevel
    /// Read for the cost lines, which name the number of configured search engines: a
    /// deep round puts every planned search to every one of them, so the same level
    /// costs a different amount on two different installs.
    let settings: ProviderSettings
    var onSelect: (ResearchLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HOW HARD TO LOOK")
                .font(PanelTheme.Font.label(textScale))
                .tracking(0.7)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                .padding(.horizontal, PanelTheme.Space.medium)
                .padding(.top, PanelTheme.Space.small)
                .padding(.bottom, PanelTheme.Space.tight)

            ForEach(ResearchLevel.ordered) { level in
                if level.beginsGroup {
                    Divider().padding(.vertical, PanelTheme.Space.tight)
                }
                row(level)
            }

            Divider().padding(.top, PanelTheme.Space.tight)
            // Concatenated, so this is a String rather than a string literal and
            // `Text` takes it verbatim — no markdown pass, and therefore no backticks
            // around the command, which would render as backticks.
            Text("Ordered by what a turn may spend. The level is remembered until you "
                 + "change it; typing a command such as /\(ResearchLevel.deep.command) "
                 + "asks one question at that level without moving it.")
                .font(PanelTheme.Font.at(10, textScale))
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PanelTheme.Space.medium)
                .padding(.vertical, PanelTheme.Space.small)
        }
        // A card, like the command-completion list it sits in the same place as. The
        // width comes from the composer column rather than being fixed: the panel's
        // width is a preference, and a 320-point card would either overhang a narrow
        // panel or float in a wide one.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.Palette.cardFill,
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card,
                                         style: .continuous))
        // A group rather than a pile of buttons: arriving here by VoiceOver otherwise
        // gives no sense of having entered anything.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Research levels")
    }

    private func row(_ level: ResearchLevel) -> some View {
        Button { onSelect(level) } label: {
            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                // A checkmark rather than a filled track or a rank glyph. A track drawn
                // across four rows asserts even spacing between them, and the gap from
                // `One pass` to `Deep rounds` is a bigger budget while the gap to
                // `Agent loop` is the same budget spent differently — a picture that
                // cannot say that should not imply the opposite.
                Image(systemName: "checkmark")
                    .font(PanelTheme.Font.at(9, textScale, weight: .semibold))
                    .foregroundStyle(PanelTheme.Palette.accent)
                    .opacity(level == selected ? 1 : 0)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: PanelTheme.Space.tight) {
                        Text(level.displayName)
                            .font(PanelTheme.Font.at(12, textScale,
                                                     weight: level == selected ? .semibold : .regular))
                            .foregroundStyle(PanelTheme.Palette.primaryText)
                        Text("/\(level.command)")
                            .font(PanelTheme.Font.citation(textScale))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    }
                    Text(level.summary)
                        .font(PanelTheme.Font.at(10.5, textScale))
                        .foregroundStyle(PanelTheme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(level.cost(settings))
                        .font(PanelTheme.Font.at(9.5, textScale))
                        .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelTheme.Space.medium)
            .padding(.vertical, PanelTheme.Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the button rather than inside its label: a `Button` folds its label's
        // children into one element, so a trait set in there is carried up only as an
        // implementation detail — and this is the trait that tells VoiceOver which of
        // the four is live. The checkmark alone is a picture.
        .accessibilityAddTraits(level == selected ? .isSelected : [])
        .accessibilityLabel("\(level.displayName). \(level.summary). \(level.cost(settings))")
    }
}
