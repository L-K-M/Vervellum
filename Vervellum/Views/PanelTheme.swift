import SwiftUI
import AppKit

/// The panel's design tokens.
///
/// One file, no magic numbers anywhere else. A research panel is dense — a question,
/// a process trail, prose, a verdict table, a source list and a composer all inside
/// 460 points — so consistency is not an aesthetic preference here, it is what keeps
/// the density readable.
///
/// Three rules the palette follows:
///
/// * **Meaning is never carried by colour alone.** Every verdict pairs its colour
///   with a distinct SF Symbol and a text label, so the table survives colour-blind
///   vision, a dimmed display, and a screenshot in a bug report.
/// * **Text colour comes from the semantic set**, so it tracks the user's appearance,
///   Increase Contrast, and Reduce Transparency settings without special-casing.
/// * **Glass is never nested.** The panel background is glass; everything inside it
///   is a flat translucent fill. Layering glass on glass produces mud and costs a
///   render pass per layer.
enum PanelTheme {

    // MARK: The active theme

    /// The palette every token below reads.
    ///
    /// A stored value rather than an environment key, and deliberately, because the
    /// palette is needed in places an environment cannot reach: `CitationText` builds an
    /// `AttributedString` whose citation chips carry the accent colour, and that is not a
    /// `View` body. One assignment point keeps those in step with the panel.
    ///
    /// Written by the composition root when the preference changes, and read on the main
    /// thread during layout. It is set *before* SwiftUI re-renders — `Preferences` posts
    /// `objectWillChange` and then calls its `onChanged` hook, and the re-render happens
    /// on a later turn of the run loop — so a body never reads a stale palette.
    static var palette: PanelPalette = .ember {
        // The contract above is documented for readers; this is the part a compiler can
        // check. A palette import or an async settings load is exactly the kind of
        // future writer that would race a value SwiftUI reads during layout.
        willSet {
            assert(Thread.isMainThread, "PanelTheme.palette must only be set on the main thread")
        }
    }

    // MARK: Spacing

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let section: CGFloat = 20
        /// Horizontal padding of the content column.
        static let gutter: CGFloat = 16
    }

    // MARK: Shape

    /// Corner radii, multiplied by the theme's roundness. Zero is square, which is the
    /// whole point of shipping a Terminal preset.
    enum Radius {
        static var chip: CGFloat { 5 * scale }
        static var card: CGFloat { 9 * scale }
        static var panel: CGFloat { 14 * scale }

        private static var scale: CGFloat { CGFloat(PanelTheme.palette.cornerScale) }
    }

    // MARK: Type

    enum Font {
        /// The theme's family for prose. Code and citations do not use it: they are
        /// monospaced because alignment carries meaning there, not because of taste.
        static var design: SwiftUI.Font.Design {
            switch PanelTheme.palette.fontDesign {
            case .system: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            }
        }

        /// The one place a point size becomes a font.
        ///
        /// Every size in the panel goes through here so the text-size preference cannot
        /// be forgotten at a call site — which is exactly how the setting came to move
        /// the answer prose and nothing else around it. The theme's family defaults in
        /// here for the same reason: prose picks it up without every call site naming
        /// it, and the two that must stay monospaced say so out loud.
        static func at(_ size: CGFloat,
                       _ scale: Double,
                       weight: SwiftUI.Font.Weight = .regular,
                       design: SwiftUI.Font.Design = PanelTheme.Font.design) -> SwiftUI.Font {
            .system(size: size * scale, weight: weight, design: design)
        }

        static func body(_ scale: Double) -> SwiftUI.Font { at(13, scale) }
        static func bodyEmphasis(_ scale: Double) -> SwiftUI.Font { at(13, scale, weight: .semibold) }
        static func heading(_ level: Int, _ scale: Double) -> SwiftUI.Font {
            switch level {
            case 1: return at(16, scale, weight: .semibold)
            case 2: return at(14.5, scale, weight: .semibold)
            default: return at(13, scale, weight: .semibold)
            }
        }
        static func code(_ scale: Double) -> SwiftUI.Font { at(11.5, scale, design: .monospaced) }
        static func citation(_ scale: Double) -> SwiftUI.Font {
            at(10.5, scale, weight: .medium, design: .monospaced)
        }
        /// Section labels: small, uppercase, tracked out.
        static func label(_ scale: Double) -> SwiftUI.Font { at(10, scale, weight: .semibold) }
        static func caption(_ scale: Double) -> SwiftUI.Font { at(11, scale) }
        static func question(_ scale: Double) -> SwiftUI.Font { at(13.5, scale, weight: .medium) }
    }

    // MARK: Colour

    enum Palette {
        private static var theme: PanelPalette { PanelTheme.palette }

        static var accent: Color { Color(theme.accent) }

        /// Text tiers. A theme that names no text colour keeps the *semantic* one, which
        /// is what lets a palette follow Dark Mode, Increase Contrast and Reduce
        /// Transparency without stating a light and a dark variant of itself.
        static var primaryText: Color { theme.primaryText.map { Color($0) } ?? Color.primary }
        static var secondaryText: Color { theme.secondaryText.map { Color($0) } ?? Color.secondary }
        static var tertiaryText: Color {
            theme.secondaryText.map { Color($0.opacity($0.alpha * 0.62)) }
                ?? Color.secondary.opacity(0.62)
        }

        /// Flat fills for cards and chips. Deliberately not materials: see the note
        /// about nesting glass in this type's documentation.
        static var cardFill: Color { Color(theme.cardFill) }
        static var chipFill: Color { Color(theme.chipFill) }
        static var hairline: Color { Color(theme.hairline) }

        /// A legibility scrim behind the content column. Liquid Glass over an
        /// arbitrary desktop — a photo, a bright IDE, a video — cannot be relied on to
        /// keep 13pt text readable, and the system does not add one for you. A theme with
        /// its own opaque surface sets this transparent, because it no longer needs one.
        static var scrim: Color { Color(theme.scrim) }

        /// The panel's own surface, or nil to use the system material behind it.
        static var surface: Color? { theme.surface.map { Color($0) } }

        static func verdict(_ verdict: Verdict) -> Color {
            switch verdict {
            case .supported: return Color(theme.supported)
            case .contradicted: return Color(theme.contradicted)
            case .mixed: return Color(theme.mixed)
            case .insufficient: return Color(theme.insufficient)
            case .opinion: return Color(theme.opinion)
            }
        }
    }

    // MARK: Motion

    enum Motion {
        /// Streaming text must not animate its own layout — the answer would shiver
        /// on every token. Only discrete state changes (a stage completing, a section
        /// expanding) animate.
        static let stage: Animation = .easeOut(duration: 0.18)
        static let disclosure: Animation = .easeInOut(duration: 0.16)
    }
}

/// The panel's background: Liquid Glass on macOS 26, a blurred `NSVisualEffectView`
/// below it, and in both cases a legibility scrim.
///
/// The scrim is not optional. Glass takes its colour from whatever is behind the
/// window, and "whatever is behind the window" is the user's entire desktop — so
/// without a scrim the same 13pt paragraph is crisp over a dark editor and unreadable
/// over a bright photo.
struct PanelBackground: View {
    var cornerRadius: CGFloat = PanelTheme.Radius.panel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            backdrop(in: shape)
            // The scrim is what stands in for a surface, not a wash over one. Painting
            // both meant a theme with an opaque surface had to remember to clear its
            // scrim or get an unasked-for tint, and it put the legibility rule in the
            // theme data rather than in the code that depends on it. Compositing is
            // associative, so a surface that wants a scrim's darkening can carry it in
            // its own alpha; nothing is lost by choosing.
            if let surface = PanelTheme.Palette.surface {
                shape.fill(surface)
            } else {
                shape.fill(PanelTheme.Palette.scrim)
            }
            shape.strokeBorder(PanelTheme.Palette.hairline, lineWidth: 0.5)
        }
    }

    /// What sits behind the surface.
    ///
    /// A theme with an opaque surface still gets one: the panel's corners are rounded, so
    /// something has to be behind them, and the blur is cheaper than it looks once it is
    /// covered. `Reduce Transparency` still wins over the theme, because that setting is
    /// an accessibility request rather than a preference.
    @ViewBuilder
    private func backdrop(in shape: RoundedRectangle) -> some View {
        switch PanelTheme.palette.backdrop {
        case .glass:
            if #available(macOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(shape)
            }
        case .frosted, .solid:
            // No `reduceTransparency` check, unlike `.glass` above: `VisualEffectBlur`
            // wraps `NSVisualEffectView`, which answers the setting itself by turning
            // its material opaque. The guarantee is kept here, just not by this code.
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(shape)
        }
    }

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

extension Color {
    /// A `ThemeColor` as SwiftUI sees it.
    ///
    /// sRGB explicitly, not `.displayP3`: the components came from a hex string a person
    /// typed or pasted, and a hex string means sRGB everywhere else they will have used
    /// one.
    init(_ themeColor: ThemeColor) {
        self.init(.sRGB,
                  red: themeColor.red,
                  green: themeColor.green,
                  blue: themeColor.blue,
                  opacity: themeColor.alpha)
    }
}

/// The panel's text-size preference, as a multiplier.
///
/// An environment value rather than a parameter because the panel is roughly twenty
/// small view structs deep in places — a header button, a citation chip, a source row —
/// and threading a `scale` argument through every initializer is how the setting got
/// dropped on the way down in the first place. Read it, multiply by it, and a new view
/// cannot silently opt out.
private struct PanelTextScaleKey: EnvironmentKey {
    /// Unscaled, so a view rendered outside the panel — a preview, a test — looks
    /// exactly as it always did.
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var panelTextScale: Double {
        get { self[PanelTextScaleKey.self] }
        set { self[PanelTextScaleKey.self] = newValue }
    }
}
