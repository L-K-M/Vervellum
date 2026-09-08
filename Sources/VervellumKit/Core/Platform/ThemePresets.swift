import Foundation

/// The themes Vervellum ships with.
///
/// A preset is a starting point, not a mode: picking one copies its values into the
/// reader's palette, which they are then free to wreck. That is why nothing here is
/// referenced by name at render time — a palette is always a full set of values, so a
/// preset that is renamed or dropped in a later version cannot leave anyone with a panel
/// that will not draw.
///
/// Two things every preset must keep, however loud it is:
///
/// * **Five distinguishable verdict colours.** They are paired with symbols and written
///   labels everywhere they appear, so colour is never the only carrier — but a preset
///   that made two verdicts the same colour would still be throwing away information the
///   reader is entitled to.
/// * **A scrim.** The panel floats over the whole desktop. Glass with no scrim is
///   readable over a dark editor and unreadable over a bright photo, and a preset is not
///   a licence to ship the second one. It has to be real even on a preset that ships an
///   opaque surface, because `surface` is one of the colours a reader can hand back to
///   Automatic — and the scrim is what they are handing it back *to*. It costs nothing
///   while the surface is set: `PanelBackground` paints one or the other, never both.
extension PanelPalette {

    /// The default. The orange Vervellum has always used.
    static let ember = PanelPalette(
        name: "Ember",
        accent: ThemeColor(1.0, 0.541, 0.298),
        cardFill: ThemeColor(0.5, 0.5, 0.5, 0.10),
        chipFill: ThemeColor(0.5, 0.5, 0.5, 0.15),
        hairline: ThemeColor(0.5, 0.5, 0.5, 0.22),
        scrim: ThemeColor(0, 0, 0, 0.16))

    /// Quiet. For people who find an accent colour distracting in a reading surface.
    static let graphite = PanelPalette(
        name: "Graphite",
        accent: ThemeColor(0.42, 0.52, 0.62),
        scrim: ThemeColor(0, 0, 0, 0.20),
        cornerScale: 0.8)

    /// Warm, opaque and serif. A reading surface rather than a HUD.
    static let paper = PanelPalette(
        name: "Paper",
        accent: ThemeColor(0.55, 0.34, 0.16),
        primaryText: ThemeColor(0.16, 0.14, 0.11),
        secondaryText: ThemeColor(0.38, 0.35, 0.30),
        surface: ThemeColor(0.98, 0.96, 0.91),
        cardFill: ThemeColor(0.45, 0.37, 0.25, 0.07),
        chipFill: ThemeColor(0.45, 0.37, 0.25, 0.12),
        hairline: ThemeColor(0.40, 0.34, 0.24, 0.22),
        scrim: ThemeColor(1, 1, 1, 0.45),
        supported: ThemeColor(0.18, 0.46, 0.28),
        contradicted: ThemeColor(0.996, 0.20, 0.20),
        mixed: ThemeColor(0.996, 0.48, 0.10),
        insufficient: ThemeColor(0.36, 0.40, 0.48),
        opinion: ThemeColor(0.44, 0.32, 0.62),
        fontDesign: .serif,
        cornerScale: 0.5,
        backdrop: .solid)

    /// Deep blue, opaque, for a dark desk at night.
    static let midnight = PanelPalette(
        name: "Midnight",
        accent: ThemeColor(0.40, 0.68, 1.0),
        primaryText: ThemeColor(0.90, 0.93, 0.98),
        secondaryText: ThemeColor(0.62, 0.68, 0.78),
        surface: ThemeColor(0.055, 0.075, 0.12),
        cardFill: ThemeColor(0.55, 0.70, 1.0, 0.07),
        chipFill: ThemeColor(0.55, 0.70, 1.0, 0.13),
        hairline: ThemeColor(0.60, 0.72, 1.0, 0.20),
        scrim: ThemeColor(0, 0, 0, 0.40),
        supported: ThemeColor(0.30, 0.82, 0.55),
        contradicted: ThemeColor(1.0, 0.42, 0.45),
        mixed: ThemeColor(1.0, 0.76, 0.32),
        insufficient: ThemeColor(0.55, 0.64, 0.80),
        opinion: ThemeColor(0.72, 0.60, 1.0),
        backdrop: .solid)

    /// Green on black, monospaced, square. Yes, really.
    static let terminal = PanelPalette(
        name: "Terminal",
        // Deliberately the same green as `supported`: a terminal has one colour, and
        // that is the preset. Verdicts stay distinguishable from *each other*, which is
        // what the contract at the top of this file asks for.
        accent: ThemeColor(0.20, 1.0, 0.45),
        primaryText: ThemeColor(0.78, 1.0, 0.82),
        secondaryText: ThemeColor(0.42, 0.74, 0.50),
        surface: ThemeColor(0.02, 0.05, 0.03),
        cardFill: ThemeColor(0.20, 1.0, 0.45, 0.06),
        chipFill: ThemeColor(0.20, 1.0, 0.45, 0.12),
        hairline: ThemeColor(0.20, 1.0, 0.45, 0.26),
        scrim: ThemeColor(0, 0, 0, 0.40),
        supported: ThemeColor(0.20, 1.0, 0.45),
        contradicted: ThemeColor(1.0, 0.28, 0.28),
        mixed: ThemeColor(1.0, 0.86, 0.20),
        insufficient: ThemeColor(0.45, 0.72, 0.85),
        opinion: ThemeColor(0.85, 0.55, 1.0),
        fontDesign: .monospaced,
        cornerScale: 0,
        backdrop: .solid)

    /// The Solarized palette, which a lot of people have strong feelings about.
    static let solarized = PanelPalette(
        name: "Solarized",
        accent: ThemeColor(0.71, 0.54, 0.0),
        primaryText: ThemeColor(0.51, 0.58, 0.59),
        secondaryText: ThemeColor(0.40, 0.48, 0.51),
        surface: ThemeColor(0.0, 0.17, 0.21),
        cardFill: ThemeColor(0.03, 0.21, 0.26, 0.85),
        chipFill: ThemeColor(0.35, 0.43, 0.46, 0.18),
        hairline: ThemeColor(0.35, 0.43, 0.46, 0.30),
        scrim: ThemeColor(0, 0, 0, 0.40),
        supported: ThemeColor(0.52, 0.60, 0.0),
        // Solarized's own red and orange, and the closest pair of verdict colours in this
        // file: different, but not by much, and the contract at the top only asks that no
        // two be *equal*. Kept as the palette states them — a Solarized that spreads its
        // red and orange apart is not Solarized — and written down so the next edit here
        // knows this is the tight pair rather than discovering it on screen.
        contradicted: ThemeColor(0.86, 0.20, 0.18),
        mixed: ThemeColor(0.80, 0.29, 0.09),
        insufficient: ThemeColor(0.15, 0.55, 0.82),
        opinion: ThemeColor(0.42, 0.44, 0.77),
        backdrop: .solid)

    /// Pink, purple and very round.
    static let bubblegum = PanelPalette(
        name: "Bubblegum",
        accent: ThemeColor(1.0, 0.35, 0.68),
        primaryText: ThemeColor(0.24, 0.10, 0.24),
        secondaryText: ThemeColor(0.48, 0.30, 0.48),
        surface: ThemeColor(1.0, 0.95, 0.98),
        cardFill: ThemeColor(1.0, 0.35, 0.68, 0.10),
        chipFill: ThemeColor(1.0, 0.35, 0.68, 0.18),
        hairline: ThemeColor(0.85, 0.40, 0.70, 0.30),
        scrim: ThemeColor(1, 1, 1, 0.45),
        supported: ThemeColor(0.11, 0.70, 0.50),
        contradicted: ThemeColor(0.95, 0.20, 0.42),
        mixed: ThemeColor(1.0, 0.62, 0.20),
        insufficient: ThemeColor(0.45, 0.52, 0.75),
        opinion: ThemeColor(0.66, 0.36, 0.94),
        fontDesign: .rounded,
        cornerScale: 1.8,
        backdrop: .solid)

    /// Magenta and cyan over black.
    static let vapor = PanelPalette(
        name: "Vapor",
        accent: ThemeColor(1.0, 0.30, 0.85),
        primaryText: ThemeColor(0.93, 0.90, 1.0),
        secondaryText: ThemeColor(0.60, 0.85, 0.95),
        surface: ThemeColor(0.09, 0.04, 0.16),
        cardFill: ThemeColor(0.40, 0.90, 1.0, 0.08),
        chipFill: ThemeColor(1.0, 0.30, 0.85, 0.16),
        hairline: ThemeColor(0.40, 0.90, 1.0, 0.28),
        scrim: ThemeColor(0, 0, 0, 0.40),
        supported: ThemeColor(0.30, 1.0, 0.80),
        contradicted: ThemeColor(1.0, 0.25, 0.45),
        mixed: ThemeColor(1.0, 0.80, 0.30),
        insufficient: ThemeColor(0.55, 0.70, 1.0),
        opinion: ThemeColor(0.80, 0.50, 1.0),
        cornerScale: 1.4,
        backdrop: .solid)

    /// Black, white and a red pencil. Serif, sharp, almost no fill.
    static let newsprint = PanelPalette(
        name: "Newsprint",
        // Deliberately the same red as `contradicted`, for the reason Terminal's accent
        // doubles its green: one ink.
        accent: ThemeColor(0.72, 0.11, 0.11),
        primaryText: ThemeColor(0.07, 0.07, 0.07),
        secondaryText: ThemeColor(0.36, 0.36, 0.36),
        surface: ThemeColor(0.97, 0.97, 0.95),
        cardFill: ThemeColor(0, 0, 0, 0.04),
        chipFill: ThemeColor(0, 0, 0, 0.08),
        hairline: ThemeColor(0, 0, 0, 0.30),
        scrim: ThemeColor(1, 1, 1, 0.45),
        supported: ThemeColor(0.10, 0.42, 0.20),
        contradicted: ThemeColor(0.72, 0.11, 0.11),
        mixed: ThemeColor(0.62, 0.42, 0.05),
        insufficient: ThemeColor(0.30, 0.34, 0.40),
        opinion: ThemeColor(0.36, 0.24, 0.55),
        fontDesign: .serif,
        cornerScale: 0.2,
        backdrop: .solid)

    /// Maximum separation between text and surface, and between the five verdicts.
    static let highContrast = PanelPalette(
        name: "High contrast",
        accent: ThemeColor(1.0, 0.85, 0.0),
        primaryText: ThemeColor(1, 1, 1),
        secondaryText: ThemeColor(0.85, 0.85, 0.85),
        surface: ThemeColor(0, 0, 0),
        cardFill: ThemeColor(1, 1, 1, 0.10),
        chipFill: ThemeColor(1, 1, 1, 0.18),
        hairline: ThemeColor(1, 1, 1, 0.45),
        scrim: ThemeColor(0, 0, 0, 0.40),
        supported: ThemeColor(0.20, 1.0, 0.40),
        contradicted: ThemeColor(1.0, 0.35, 0.35),
        // Orange, not the accent's yellow. At (1.0, 0.80, 0.0) it was one twentieth of a
        // channel away from `accent`, so a link and a "mixed" verdict were the same
        // colour — in the preset whose whole argument is separation.
        mixed: ThemeColor(1.0, 0.62, 0.0),
        insufficient: ThemeColor(0.50, 0.80, 1.0),
        opinion: ThemeColor(0.85, 0.60, 1.0),
        cornerScale: 0.4,
        backdrop: .solid)

    /// Every preset, in the order the picker shows them: the default first, then light
    /// to dark, then the loud ones.
    static let presets: [PanelPalette] = [
        .ember, .graphite, .paper, .newsprint, .solarized,
        .midnight, .terminal, .vapor, .bubblegum, .highContrast,
    ]

    /// The preset whose values these are, if any.
    ///
    /// Compared on the values rather than the name, so a palette edited back to exactly
    /// what a preset says is recognised as that preset again — and one that merely
    /// borrowed the name is not.
    var matchingPreset: PanelPalette? {
        Self.presets.first { $0.hasTheSameValues(as: self) }
    }

    /// Equal on every field except `name`, which matching deliberately ignores.
    ///
    /// Named for what it answers rather than for how it is used: the old name asserted a
    /// difference, and this is true of two palettes that do not differ at all — which is
    /// the common case, since picking a preset copies its name across too.
    private func hasTheSameValues(as other: PanelPalette) -> Bool {
        var mine = self
        var theirs = other
        mine.name = ""
        theirs.name = ""
        return mine == theirs
    }
}
