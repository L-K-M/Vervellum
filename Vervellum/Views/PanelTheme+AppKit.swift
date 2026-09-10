import AppKit
import SwiftUI

/// The theme, as AppKit needs it.
///
/// The answer's prose is drawn by an `NSTextView` rather than a SwiftUI `Text`, because
/// a `Text` has no per-run hit testing and a citation chip has to answer a hover. That
/// view takes `NSFont` and `NSColor`, and neither can be got out of a SwiftUI `Font` or
/// `Color` — they are opaque. So the sizes and the palette are read a second time here,
/// from the same numbers.
///
/// Second *reading*, not second source. Every size comes from `PanelTheme.Metrics` and
/// every colour from the palette, so the drift this file would otherwise invite — one
/// literal edited on one side — cannot happen: there is only one literal. What is still
/// stated twice is the weights, because `SwiftUI.Font.Weight` and `NSFont.Weight` are
/// unrelated types with no shared spelling; there are four of them, and `body(_:)` here
/// and `body(_:)` there are meant to be read side by side.
extension PanelTheme {

    enum NativeFont {

        /// The theme's family, as a font descriptor design.
        static var design: NSFontDescriptor.SystemDesign {
            switch PanelTheme.palette.fontDesign {
            case .system: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            }
        }

        /// The one place a point size becomes an `NSFont`, mirroring `Font.at`.
        ///
        /// A design that the running system cannot supply falls back to the plain system
        /// font rather than to nothing: `withDesign` answers nil for a descriptor it
        /// cannot make, and a nil font here would draw the paragraph in Helvetica 12.
        static func at(_ size: CGFloat,
                       _ scale: Double,
                       weight: NSFont.Weight = .regular,
                       design: NSFontDescriptor.SystemDesign = PanelTheme.NativeFont.design)
            -> NSFont {
            let point = size * scale
            let base = NSFont.systemFont(ofSize: point, weight: weight)
            guard design != .default,
                  let descriptor = base.fontDescriptor.withDesign(design),
                  let designed = NSFont(descriptor: descriptor, size: point)
            else { return base }
            return designed
        }

        static func body(_ scale: Double) -> NSFont { at(PanelTheme.Metrics.body, scale) }
        static func bodyEmphasis(_ scale: Double) -> NSFont {
            at(PanelTheme.Metrics.bodyEmphasis, scale, weight: .semibold)
        }
        static func heading(_ level: Int, _ scale: Double) -> NSFont {
            switch level {
            case 1: return at(PanelTheme.Metrics.heading1, scale, weight: .semibold)
            case 2: return at(PanelTheme.Metrics.heading2, scale, weight: .semibold)
            default: return at(PanelTheme.Metrics.heading3, scale, weight: .semibold)
            }
        }
        /// The monospaced face, at a weight.
        ///
        /// A weight rather than a trait, because this is the one face in the panel that
        /// is *replaced* rather than decorated: `adding(_:to:)` asks a family for a bold
        /// descriptor and takes what it gets, while `monospacedSystemFont` always
        /// resolves one. So a bold code span keeps its weight here where it could not
        /// have kept it there.
        static func code(_ scale: Double, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: PanelTheme.Metrics.code * scale, weight: weight)
        }
        static func citation(_ scale: Double) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: PanelTheme.Metrics.citation * scale,
                                        weight: .medium)
        }

        /// The same font with a symbolic trait added, or the original when the family has
        /// no such face.
        ///
        /// Asked of the *descriptor* rather than of `NSFontManager.convert`, which
        /// silently returns the unconverted font and gives a caller no way to tell an
        /// applied trait from a missing one. Here a missing face is the same outcome —
        /// unemphasised text — but arrived at deliberately.
        static func adding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
            var symbolic = font.fontDescriptor.symbolicTraits
            symbolic.formUnion(traits)
            let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
    }

    /// The palette's text colours, as AppKit sees them.
    ///
    /// A theme that names no colour keeps the *semantic* one — `labelColor` rather than
    /// a fixed grey — which is what lets the panel follow Dark Mode, Increase Contrast
    /// and Reduce Transparency without stating a light and a dark variant of itself.
    /// Same rule as `PanelTheme.Palette`, which resolves to `Color.primary` there.
    enum NativePalette {
        private static var theme: PanelPalette { PanelTheme.palette }

        static var accent: NSColor { NSColor(theme.accent) }
        static var primaryText: NSColor { theme.primaryText.map { NSColor($0) } ?? .labelColor }
        static var secondaryText: NSColor {
            theme.secondaryText.map { NSColor($0) } ?? .secondaryLabelColor
        }
    }
}

extension NSColor {
    /// A `ThemeColor` as AppKit sees it.
    ///
    /// sRGB explicitly, for the reason the SwiftUI initializer beside it gives: the
    /// components came from a hex string somebody typed, and a hex string means sRGB
    /// everywhere else they will have used one.
    convenience init(_ themeColor: ThemeColor) {
        self.init(srgbRed: CGFloat(themeColor.red),
                  green: CGFloat(themeColor.green),
                  blue: CGFloat(themeColor.blue),
                  alpha: CGFloat(themeColor.alpha))
    }
}
