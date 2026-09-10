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
        // A debug-runtime trap, not a compile-time or a shipping check — `assert` is
        // compiled out with `-O`, and that is the intended severity. A palette import or
        // an async settings load is exactly the kind of future writer that would race a
        // value SwiftUI reads during layout, and this catches it in the build that writer
        // is running. `dispatchPrecondition` would carry into release, but the harm being
        // guarded against is a frame drawn in the wrong colours, and killing a running
        // app over that trades a cosmetic bug for a worse one.
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

    /// Every point size in the panel, once.
    ///
    /// Two families of font read these — SwiftUI's, for everything drawn by a `Text`,
    /// and AppKit's in `PanelTheme+AppKit`, for the answer prose that had to move to an
    /// `NSTextView` so a citation could answer a hover. Neither can be built from the
    /// other and a SwiftUI `Font` cannot be asked its size, so no test can catch the two
    /// drifting apart. This is the only thing that can: one literal, read twice.
    ///
    /// Weights are not here, because `SwiftUI.Font.Weight` and `NSFont.Weight` are
    /// unrelated types with no shared spelling. They are stated at both call sites, and
    /// there are four of them.
    enum Metrics {
        static let body: CGFloat = 13
        static let bodyEmphasis: CGFloat = 13
        static let heading1: CGFloat = 16
        static let heading2: CGFloat = 14.5
        static let heading3: CGFloat = 13
        static let code: CGFloat = 11.5
        static let citation: CGFloat = 10.5
        static let label: CGFloat = 10
        static let caption: CGFloat = 11
        static let question: CGFloat = 13.5
        static let previewTitle: CGFloat = 12
        static let previewMeta: CGFloat = 10.5
        static let previewSnippet: CGFloat = 10.5
        static let previewFootnote: CGFloat = 9.5
    }

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

        static func body(_ scale: Double) -> SwiftUI.Font { at(Metrics.body, scale) }
        static func bodyEmphasis(_ scale: Double) -> SwiftUI.Font {
            at(Metrics.bodyEmphasis, scale, weight: .semibold)
        }
        static func heading(_ level: Int, _ scale: Double) -> SwiftUI.Font {
            switch level {
            case 1: return at(Metrics.heading1, scale, weight: .semibold)
            case 2: return at(Metrics.heading2, scale, weight: .semibold)
            default: return at(Metrics.heading3, scale, weight: .semibold)
            }
        }
        static func code(_ scale: Double) -> SwiftUI.Font {
            at(Metrics.code, scale, design: .monospaced)
        }
        static func citation(_ scale: Double) -> SwiftUI.Font {
            at(Metrics.citation, scale, weight: .medium, design: .monospaced)
        }
        /// Section labels: small, uppercase, tracked out.
        static func label(_ scale: Double) -> SwiftUI.Font { at(Metrics.label, scale, weight: .semibold) }
        static func caption(_ scale: Double) -> SwiftUI.Font { at(Metrics.caption, scale) }
        static func question(_ scale: Double) -> SwiftUI.Font {
            at(Metrics.question, scale, weight: .medium)
        }
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
            theme.secondaryText.map { Color($0.withAlpha($0.alpha * 0.62)) }
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
        /// its own surface does *not* clear this: `PanelBackground` paints one or the
        /// other, never both, so the scrim costs nothing while a surface is set and is
        /// what stands in the moment the reader hands `surface` back to Automatic.
        static var scrim: Color { Color(theme.scrim) }

        /// The panel's own surface, or nil to use the system material behind it.
        ///
        /// An alpha near zero reads as absent. `PanelBackground` paints the surface *or*
        /// the scrim, so without this floor a surface dragged to 0.01 paints nothing
        /// while still cancelling the 0.16 scrim — the least legible arrangement the
        /// theme pane can produce, reached by a slider on its way to a state (Automatic)
        /// that is fine. The legibility floor has to be continuous across that drag, not
        /// fall away at one end and reappear at the other.
        static var surface: Color? {
            guard let surface = theme.surface, surface.alpha > 0.05 else { return nil }
            return Color(surface)
        }

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

        /// How a disclosed section's *change* is animated, or nil for not at all.
        ///
        /// The companion to `disclosureTransition`, and needed for the same reason:
        /// gating only the transition left the setting half-wired, because the
        /// transaction still animated the container's height — everything below the
        /// section sliding up or down — and the chevron's rotation. Those are the motion,
        /// as much as the rows arriving are. `withAnimation` takes an `Animation?`, so
        /// nil is the whole of "do it instantly".
        ///
        /// Paired with the transition rather than folded into it because SwiftUI needs
        /// them at two different places: one wraps the state change, the other decorates
        /// the view. Two functions with one argument each is what stops the next reader
        /// from gating one and not the other, which is the mistake this replaces.
        static func disclosureAnimation(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : disclosure
        }

        /// How a disclosed section arrives.
        ///
        /// A list that slides in from above is the shape Reduce Motion exists to
        /// flatten, and both of the panel's disclosures now start closed — so the slide
        /// is on the ordinary path rather than something a reader opts into once. Under
        /// the setting the travel is dropped and the section simply appears.
        ///
        /// Not a fade, which is what this used to claim and was wrong about. A
        /// transition only animates when the surrounding transaction carries one, and
        /// `disclosureAnimation` is nil under the same setting — so `.opacity` here takes
        /// no time at all. Nil is still right: that animation gates the container's
        /// height and the chevron's rotation as well as the rows arriving, and those are
        /// the motion. `.opacity` is the *shape* of the no-motion transition rather than
        /// something the reader sees, and it stays that way so a caller who ever animates
        /// without going through `disclosureAnimation` cross-fades rather than slides.
        ///
        /// A function of the environment value rather than a reader of
        /// `NSWorkspace.accessibilityDisplayShouldReduceMotion`, so a change to the
        /// setting redraws the views that depend on it instead of taking effect at the
        /// next relaunch.
        static func disclosureTransition(_ reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
        }
    }
}

/// The panel's background: the theme's backdrop, then its surface or, failing that, a
/// legibility scrim.
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
    /// A theme with an opaque surface still gets one, even though that surface fills the
    /// same rounded rectangle and hides it completely. `surface` is an optional the
    /// reader toggles and an alpha they drag, so making the view tree depend on either
    /// would build and tear down an `NSVisualEffectView` in the middle of that drag —
    /// a stutter, traded for a blur nothing is looking at. `Reduce Transparency` still
    /// wins over the theme, because that setting is an accessibility request rather than
    /// a preference.
    ///
    /// Three cases, three renderings. That is the whole contract: the picker offers three
    /// names, so two of them drawing the same pixels would read as a broken setting rather
    /// than as a taste nobody shares.
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
        case .frosted:
            // No `reduceTransparency` check, unlike `.glass` above: `VisualEffectBlur`
            // wraps `NSVisualEffectView`, which answers the setting itself by turning
            // its material opaque. The guarantee is kept here, just not by this code.
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(shape)
        case .solid:
            // Opaque here, rather than by leaning on the theme's surface to cover a blur.
            // `surface` is one of the colours the reader can hand back to Automatic, and
            // this is the backdrop that promises legibility over literally anything — so
            // sharing the `.frosted` branch made that promise depend on a checkbox two
            // rows above it in the same pane, and made two of the three menu items draw
            // the same thing. The semantic window colour rather than a fixed grey, so an
            // opaque panel still follows Dark Mode and Increase Contrast; a theme with a
            // surface of its own paints straight over this.
            shape.fill(Color(nsColor: .windowBackgroundColor))
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
