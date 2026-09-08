import SwiftUI

/// The verdict table: one row per claim the answer rests on.
///
/// This is the feature. Prose with citations still lets a reader assume the citations
/// support what the sentence says; a table that says *this claim is only partly
/// supported, and here is why* does not. It is placed below the answer rather than
/// above it because the answer is what was asked for — but it is never collapsed by
/// default when anything is contradicted, mixed, or unestablished, because burying a
/// caveat behind a disclosure triangle is how a research tool becomes a chatbot.
struct FindingsView: View {

    @Environment(\.panelTextScale) private var textScale

    let findings: [Finding]
    let sources: [Source]
    var onSelectSource: (Source) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            SectionLabel(text: "Claims", trailing: distributionText)
            VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
                ForEach(findings) { finding in
                    row(finding)
                }
            }
        }
    }

    /// "3 supported · 1 mixed" — a one-glance shape of the answer's evidential health.
    private var distributionText: String? {
        let counts = Dictionary(grouping: findings, by: \.verdict).mapValues(\.count)
        let parts = Verdict.allCases.compactMap { verdict -> String? in
            guard let count = counts[verdict], count > 0 else { return nil }
            return "\(count) \(verdict.label.lowercased())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: PanelTheme.Space.medium) {
            // The verdict rail. Colour is never the only channel: the glyph differs
            // per verdict and the accessibility label spells the verdict out.
            Image(systemName: finding.verdict.symbolName)
                .font(PanelTheme.Font.at(11, textScale, weight: .medium))
                .foregroundStyle(PanelTheme.Palette.verdict(finding.verdict))
                .frame(width: 14)
                .padding(.top, 1)
                .accessibilityLabel(finding.verdict.label)

            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                    Text(finding.verdict.label.uppercased())
                        .font(PanelTheme.Font.label(textScale))
                        .tracking(0.7)
                        .foregroundStyle(PanelTheme.Palette.verdict(finding.verdict))
                    ForEach(citedSources(finding)) { source in
                        CitationChip(source: source, action: { onSelectSource(source) })
                    }
                }
                Text(finding.claim)
                    .font(PanelTheme.Font.body(textScale))
                    .foregroundStyle(PanelTheme.Palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.reasoning.isEmpty {
                    Text(finding.reasoning)
                        .font(PanelTheme.Font.caption(textScale))
                        .foregroundStyle(PanelTheme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(PanelTheme.Space.medium)
        .background(PanelTheme.Palette.cardFill,
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            // A 2pt spine in the verdict colour, so the column is scannable without
            // reading a word of it.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(PanelTheme.Palette.verdict(finding.verdict).opacity(0.85))
                .frame(width: 2)
                .padding(.vertical, PanelTheme.Space.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.verdict.label): \(finding.claim)")
    }

    private func citedSources(_ finding: Finding) -> [Source] {
        finding.sourceNumbers.compactMap { number in
            sources.first { $0.number == number }
        }
    }
}

/// A compact `[3]` chip that opens its source.
struct CitationChip: View {
    @Environment(\.panelTextScale) private var textScale

    let source: Source
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("[\(source.number)]")
                .font(PanelTheme.Font.citation(textScale))
                .foregroundStyle(PanelTheme.Palette.accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(PanelTheme.Palette.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(source.title)\n\(source.domain)")
        .accessibilityLabel("Source \(source.number), \(source.domain)")
    }
}

/// A small uppercase section heading with an optional right-aligned summary.
struct SectionLabel: View {
    @Environment(\.panelTextScale) private var textScale

    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
            Text(text.uppercased())
                .font(PanelTheme.Font.label(textScale))
                .tracking(0.7)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
            if let trailing {
                Text(trailing)
                    .font(PanelTheme.Font.at(10, textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
