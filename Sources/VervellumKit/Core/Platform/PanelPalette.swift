import Foundation

/// A colour, stored the only way a settings file can hold one.
///
/// Plain sRGB components rather than a platform colour, because this has to survive a
/// round trip through `settings.json` and be readable by a build that has no AppKit —
/// and because a hex string a user can paste from a palette they found is worth more
/// than any richer representation.
struct ThemeColor: Codable, Equatable, Hashable {

    /// Read-only from outside this file, so the clamp below is not advice. They were
    /// plain `var`s, and `hexString` multiplies by 255 without checking — so one
    /// `colour.red = 5` produced `#4FB0000`, a string `init(hex:)` refuses, which the
    /// lenient decoder then drops back to the default at the next launch. Nothing in the
    /// app assigned a component; the point is that nothing can.
    private(set) var red: Double
    private(set) var green: Double
    private(set) var blue: Double
    private(set) var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red.clampedToUnit
        self.green = green.clampedToUnit
        self.blue = blue.clampedToUnit
        self.alpha = alpha.clampedToUnit
    }

    /// Reads `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`, with or without the hash.
    ///
    /// Lenient on purpose: this is the field someone pastes into from a palette site,
    /// and rejecting `0xFF8A4C` or a stray space would be a worse experience than
    /// accepting it.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["#", "0x"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }
        // CSS Color 4's short forms, both of them: `#FED` and `#FEDC` double each digit
        // onto the six- and eight-digit paths below.
        if text.count == 3 || text.count == 4 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else {
            return nil
        }
        let hasAlpha = text.count == 8
        let shift = hasAlpha ? 8 : 0
        let scale = 255.0
        self.init(Double((value >> (16 + shift)) & 0xFF) / scale,
                  Double((value >> (8 + shift)) & 0xFF) / scale,
                  Double((value >> shift) & 0xFF) / scale,
                  hasAlpha ? Double(value & 0xFF) / scale : 1)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when it is not opaque.
    var hexString: String {
        let byte = { (component: Double) in Int((component * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? base : base + String(format: "%02X", byte(alpha))
    }

    /// The same colour with its alpha replaced by `value`.
    ///
    /// Named for AppKit's `withAlphaComponent`, not for SwiftUI's `opacity`, because it
    /// behaves like the first: it *sets* alpha rather than scaling what is there.
    /// `.opacity(0.5)` twice in SwiftUI leaves you at a quarter; this twice leaves you at
    /// a half, and a caller who wants the SwiftUI reading has to write the multiply out —
    /// which the one caller does.
    func withAlpha(_ value: Double) -> ThemeColor {
        ThemeColor(red, green, blue, value)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    /// Decoded through the clamping initializer rather than straight into the stored
    /// properties.
    ///
    /// The synthesized decoder would write whatever the file said, and this is a value
    /// people hand-edit: a red of `5` or a `NaN` that reached a colour would otherwise
    /// draw as something undefined rather than as the nearest real colour.
    init(from decoder: Decoder) throws {
        // A hex string where `encode` wrote components. `encode` never produces one, but
        // this type's whole argument for storing plain sRGB is that a person can paste a
        // colour into the settings file — and a string is what they will paste. Reading
        // only the object form made that story true everywhere except the one place it
        // was told, and the paste was discarded without a word.
        if let text = try? decoder.singleValueContainer().decode(String.self),
           let parsed = ThemeColor(hex: text) {
            self = parsed
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func component(_ key: CodingKeys, _ fallback: Double) -> Double {
            ((try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(component(.red, 0), component(.green, 0), component(.blue, 0),
                  component(.alpha, 1))
    }

    /// Perceived brightness, 0…1, by the usual luma weights.
    ///
    /// What the preset tests measure to keep text off its own surface — no drawing code
    /// reads it, and the comment here used to imply otherwise.
    ///
    /// Alpha blends the result toward mid-grey, because a translucent colour shows
    /// whatever is behind it and the honest answer for one is "closer to unknown".
    /// Reporting `ThemeColor(1, 1, 1, 0.1)` as fully light would wave through a preset
    /// whose surface is, in practice, whatever the desktop is.
    var luminance: Double {
        let opaque = 0.299 * red + 0.587 * green + 0.114 * blue
        return opaque * alpha + 0.5 * (1 - alpha)
    }
}

private extension Double {
    var clampedToUnit: Double { isFinite ? Swift.min(Swift.max(self, 0), 1) : 0 }
}

/// The typeface family the panel's prose uses.
///
/// Code and citations stay monospaced whatever this says: they are monospaced because
/// alignment carries meaning there, not because of taste.
enum ThemeFontDesign: String, Codable, CaseIterable, Identifiable {
    case system, serif, rounded, monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        }
    }
}

/// What is behind the panel's content.
enum ThemeBackdrop: String, Codable, CaseIterable, Identifiable {
    /// Liquid Glass on macOS 26, a blurred visual-effect view below it.
    case glass
    /// The same blur without the glass pass — cheaper, and steadier over video.
    case frosted
    /// An opaque surface. The one setting that makes the panel legible over literally
    /// anything, and the one some people simply prefer.
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .frosted: return "Frosted"
        case .solid: return "Solid"
        }
    }
}

/// Everything about how the panel looks.
///
/// A value, not a set of constants, so it can be persisted, shipped as a preset, and
/// swapped while the panel is open. Colours that are `nil` follow the system's semantic
/// ones, which is what makes a palette track Dark Mode, Increase Contrast and Reduce
/// Transparency without every preset having to state a light and a dark variant.
///
/// One rule survives every theme: **meaning is never carried by colour alone.** The
/// verdict colours are themeable, but each verdict keeps its own symbol and its written
/// label, so a palette invented at two in the morning cannot make the table unreadable
/// to a colour-blind reader — only ugly.
struct PanelPalette: Codable, Equatable {

    /// The preset this came from, or what the reader called their own.
    var name: String

    /// The one colour that is never nil: links, citation chips, the send button, focus.
    var accent: ThemeColor

    /// Text tiers. Nil means the system's semantic colour, which tracks appearance.
    var primaryText: ThemeColor?
    var secondaryText: ThemeColor?

    /// The panel's own surface, under the content. Nil means the system material.
    var surface: ThemeColor?

    var cardFill: ThemeColor
    var chipFill: ThemeColor
    var hairline: ThemeColor
    /// The legibility scrim. See `PanelBackground`: glass takes its colour from the
    /// desktop behind it, so without this the same paragraph is crisp over an editor
    /// and unreadable over a bright photo.
    var scrim: ThemeColor

    var supported: ThemeColor
    var contradicted: ThemeColor
    var mixed: ThemeColor
    var insufficient: ThemeColor
    var opinion: ThemeColor

    var fontDesign: ThemeFontDesign
    /// Multiplies every corner radius. 0 is square, 1 is as designed, 2 is very round.
    var cornerScale: Double {
        // The two initializers clamp, and the property was a plain `var` between them —
        // so `palette.cornerScale = a * b` could still land a NaN, which makes
        // `JSONEncoder` refuse the whole palette and costs the reader their theme.
        // Observers do not run during initialization, and an assignment inside `didSet`
        // does not re-enter it, so both existing paths behave exactly as before.
        didSet { cornerScale = Self.clampedCornerScale(cornerScale) }
    }
    var backdrop: ThemeBackdrop

    static let cornerScaleRange = 0.0...2.0

    /// `value` inside `cornerScaleRange`.
    ///
    /// One function because the initializer and the decoder clamped separately and
    /// disagreed. NaN is the whole reason either needs care: it has no order, so
    /// `Swift.max(.nan, 0)` hands back the NaN — `0 >= .nan` is false — and `min` then
    /// does the same, leaving a NaN corner radius for `RoundedRectangle` to draw and, far
    /// worse, a palette `JSONEncoder` refuses outright. That is how one bad `Double`
    /// erased a theme rather than rounding a corner oddly.
    ///
    /// Only NaN. An infinity compares fine and clamps to the end of the range it sits at,
    /// which is the answer a file saying `1e999` was asking for.
    private static func clampedCornerScale(_ value: Double) -> Double {
        guard !value.isNaN else { return 1 }
        return Swift.min(Swift.max(value, cornerScaleRange.lowerBound),
                         cornerScaleRange.upperBound)
    }

    init(name: String,
         accent: ThemeColor,
         primaryText: ThemeColor? = nil,
         secondaryText: ThemeColor? = nil,
         surface: ThemeColor? = nil,
         cardFill: ThemeColor = ThemeColor(0.5, 0.5, 0.5, 0.10),
         chipFill: ThemeColor = ThemeColor(0.5, 0.5, 0.5, 0.15),
         hairline: ThemeColor = ThemeColor(0.5, 0.5, 0.5, 0.22),
         scrim: ThemeColor = ThemeColor(0, 0, 0, 0.16),
         supported: ThemeColor = ThemeColor(0.20, 0.68, 0.42),
         contradicted: ThemeColor = ThemeColor(0.88, 0.30, 0.30),
         mixed: ThemeColor = ThemeColor(0.92, 0.66, 0.20),
         insufficient: ThemeColor = ThemeColor(0.47, 0.55, 0.68),
         opinion: ThemeColor = ThemeColor(0.60, 0.50, 0.85),
         fontDesign: ThemeFontDesign = .system,
         cornerScale: Double = 1,
         backdrop: ThemeBackdrop = .glass) {
        self.name = name
        self.accent = accent
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.surface = surface
        self.cardFill = cardFill
        self.chipFill = chipFill
        self.hairline = hairline
        self.scrim = scrim
        self.supported = supported
        self.contradicted = contradicted
        self.mixed = mixed
        self.insufficient = insufficient
        self.opinion = opinion
        self.fontDesign = fontDesign
        self.cornerScale = Self.clampedCornerScale(cornerScale)
        self.backdrop = backdrop
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case name, accent, primaryText, secondaryText, surface
        case cardFill, chipFill, hairline, scrim
        case supported, contradicted, mixed, insufficient, opinion
        case fontDesign, cornerScale, backdrop
    }

    /// Lenient for the reason `ModelProfile.init(from:)` is, and more so: this is the
    /// one settings value people will hand-edit and paste to each other, so a document
    /// missing half its keys should read as "the default, plus what it did say" rather
    /// than cost the reader every other setting in the file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PanelPalette.ember
        // `try?` on `decodeIfPresent` yields a double optional — a decode that threw and
        // a key that was absent are different things. Flattened with `?? nil`, which is
        // the spelling the other lenient decoders in this module use.
        func colour(_ key: CodingKeys, _ fallback: ThemeColor) -> ThemeColor {
            optionalColour(key) ?? fallback
        }
        func optionalColour(_ key: CodingKeys) -> ThemeColor? {
            (try? container.decodeIfPresent(ThemeColor.self, forKey: key)) ?? nil
        }
        // Blank counts as absent. A hand-edited `"name": ""` is not a name a reader chose,
        // and `name` is a stored property — so it would round-trip back out through
        // `encode` and stay blank for good.
        let named = ((try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        // The trimmed form is what gets stored, not just what gets measured. `name` round
        // trips through `encode`, so `"  Ocean  "` kept its padding for good and compared
        // unequal to the `"Ocean"` beside it in a list.
        let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? "Custom" : trimmed
        accent = colour(.accent, fallback.accent)
        primaryText = optionalColour(.primaryText)
        secondaryText = optionalColour(.secondaryText)
        surface = optionalColour(.surface)
        cardFill = colour(.cardFill, fallback.cardFill)
        chipFill = colour(.chipFill, fallback.chipFill)
        hairline = colour(.hairline, fallback.hairline)
        scrim = colour(.scrim, fallback.scrim)
        supported = colour(.supported, fallback.supported)
        contradicted = colour(.contradicted, fallback.contradicted)
        mixed = colour(.mixed, fallback.mixed)
        insufficient = colour(.insufficient, fallback.insufficient)
        opinion = colour(.opinion, fallback.opinion)
        let design = (try? container.decodeIfPresent(String.self, forKey: .fontDesign)) ?? nil
        fontDesign = design.flatMap { ThemeFontDesign(rawValue: $0) } ?? .system
        let corner = ((try? container.decodeIfPresent(Double.self, forKey: .cornerScale)) ?? nil) ?? 1
        cornerScale = Self.clampedCornerScale(corner)
        let back = (try? container.decodeIfPresent(String.self, forKey: .backdrop)) ?? nil
        backdrop = back.flatMap { ThemeBackdrop(rawValue: $0) } ?? .glass
    }

    // MARK: Persistence

    static func encode(_ palette: PanelPalette) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(palette) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ text: String) -> PanelPalette? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PanelPalette.self, from: data)
    }
}
