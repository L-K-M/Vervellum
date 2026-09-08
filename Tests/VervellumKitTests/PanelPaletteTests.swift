import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The theme's portable parts: the colour type people will paste into, the persistence
/// a hand-edited settings file has to survive, and the promises every preset makes.
final class PanelPaletteTests: XCTestCase {

    // MARK: Colours

    func testReadsTheHexSpellingsPeoplePaste() {
        XCTAssertEqual(ThemeColor(hex: "#FF8A4C")?.hexString, "#FF8A4C")
        XCTAssertEqual(ThemeColor(hex: "ff8a4c")?.hexString, "#FF8A4C")
        XCTAssertEqual(ThemeColor(hex: "0xFF8A4C")?.hexString, "#FF8A4C")
        XCTAssertEqual(ThemeColor(hex: "  #ff8a4c  ")?.hexString, "#FF8A4C")
    }

    /// The three-digit form is what a lot of palette sites hand out.
    func testExpandsTheShortHexForm() {
        XCTAssertEqual(ThemeColor(hex: "#f84")?.hexString, "#FF8844")
    }

    func testReadsAndWritesAlpha() throws {
        // Unwrapped rather than coalesced: `colour?.alpha ?? 1` reported a parse that
        // returned nil as "1.0 is not within 0.01 of 0.161", which reads like a rounding
        // problem rather than the string not parsing at all.
        let colour = try XCTUnwrap(ThemeColor(hex: "#00000029"))
        XCTAssertEqual(colour.alpha, 0.161, accuracy: 0.01)
        XCTAssertEqual(colour.hexString, "#00000029")
        XCTAssertEqual(ThemeColor(0, 0, 0, 1).hexString, "#000000", "opaque needs no alpha pair")
    }

    func testRejectsWhatIsNotAColour() {
        XCTAssertNil(ThemeColor(hex: ""))
        XCTAssertNil(ThemeColor(hex: "#12345"))
        XCTAssertNil(ThemeColor(hex: "cornflower"))
        XCTAssertNil(ThemeColor(hex: "#ggghhh"))
    }

    /// Absolute, like AppKit's `withAlphaComponent` and unlike SwiftUI's `opacity`, which
    /// composes: going through here twice leaves the alpha where it was asked for rather
    /// than at a quarter of it.
    func testSettingAnAlphaReplacesWhateverWasThere() {
        let faint = ThemeColor(0.2, 0.4, 0.6, 0.2)
        XCTAssertEqual(faint.withAlpha(0.5).alpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(faint.withAlpha(0.5).withAlpha(0.5).alpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(faint.withAlpha(0.5).red, 0.2, accuracy: 0.0001, "only the alpha moves")
    }

    /// Components arrive from a settings file a hand edit can leave holding anything.
    func testComponentsAreClamped() {
        let wild = ThemeColor(4, -2, .nan, 99)
        XCTAssertEqual(wild.red, 1)
        XCTAssertEqual(wild.green, 0)
        XCTAssertEqual(wild.blue, 0, "a non-finite component is not a colour")
        XCTAssertEqual(wild.alpha, 1)
    }

    /// Used to decide whether a palette wants light or dark text over it.
    func testLuminanceSeparatesLightFromDark() {
        XCTAssertGreaterThan(ThemeColor(1, 1, 1).luminance, 0.9)
        XCTAssertLessThan(ThemeColor(0, 0, 0).luminance, 0.1)
        XCTAssertGreaterThan(ThemeColor(0, 1, 0).luminance, ThemeColor(0, 0, 1).luminance,
                             "green reads brighter than blue, which is the point of the weights")
    }

    /// The same clamping on the way in from a file, because that is where an absurd
    /// component actually comes from — the memberwise initializer is called by code that
    /// already knows what it is doing.
    func testComponentsAreClampedWhenDecodedToo() throws {
        let wild = #"{"red":5,"green":-2,"blue":0.5,"alpha":9}"#
        let colour = try JSONDecoder().decode(ThemeColor.self, from: Data(wild.utf8))
        XCTAssertEqual(colour.red, 1)
        XCTAssertEqual(colour.green, 0)
        XCTAssertEqual(colour.blue, 0.5, accuracy: 0.001)
        XCTAssertEqual(colour.alpha, 1)
    }

    // MARK: Persistence

    func testAPaletteSurvivesTheRoundTrip() throws {
        let encoded = try XCTUnwrap(PanelPalette.encode(.terminal))
        XCTAssertEqual(PanelPalette.decode(encoded), .terminal)
    }

    /// This is the one settings value people will hand-edit and paste to each other, so a
    /// document missing most of its keys reads as "the default, plus what it did say".
    func testAHalfWrittenPaletteReadsAsTheDefaultPlusWhatItSaid() throws {
        let partial = #"{"name":"Mine","accent":{"red":0,"green":0,"blue":1,"alpha":1}}"#
        let palette = try XCTUnwrap(PanelPalette.decode(partial))
        XCTAssertEqual(palette.name, "Mine")
        XCTAssertEqual(palette.accent, ThemeColor(0, 0, 1))
        XCTAssertEqual(palette.cardFill, PanelPalette.ember.cardFill, "the rest is the default")
        XCTAssertEqual(palette.fontDesign, .system)
        XCTAssertEqual(palette.backdrop, .glass)
    }

    /// A value a newer build wrote, or a hand edit fat-fingered, must not cost the reader
    /// their whole theme.
    func testUnknownEnumeratedValuesFallBack() throws {
        let odd = #"{"fontDesign":"gothic","backdrop":"hologram","cornerScale":99}"#
        let palette = try XCTUnwrap(PanelPalette.decode(odd))
        XCTAssertEqual(palette.fontDesign, .system)
        XCTAssertEqual(palette.backdrop, .glass)
        XCTAssertEqual(palette.cornerScale, PanelPalette.cornerScaleRange.upperBound,
                       "clamped rather than obeyed")
    }

    /// Two answers, because the two bad values are not the same kind of bad. NaN has no
    /// order, so the `min`/`max` pair hands it straight back and it has no end of the
    /// range to be nearest to — it reads as "as designed". An infinity compares fine and
    /// gets clamped like any other out-of-range number. The initializer and the decoder
    /// used to reach that pair by different routes and could disagree about both.
    func testAStrangeCornerScaleLandsSomewhereSensible() {
        func palette(_ scale: Double) -> PanelPalette {
            PanelPalette(name: "Odd", accent: ThemeColor(0.5, 0.5, 0.5), cornerScale: scale)
        }
        XCTAssertEqual(palette(.nan).cornerScale, 1)
        XCTAssertEqual(palette(.infinity).cornerScale, PanelPalette.cornerScaleRange.upperBound,
                       "an infinity has an end of the range to clamp to")
        XCTAssertEqual(palette(-.infinity).cornerScale, PanelPalette.cornerScaleRange.lowerBound)
    }

    /// The clamp lived in the two initializers, and the property between them was a plain
    /// `var` — so `palette.cornerScale = a * b` could still land a NaN, and a NaN is
    /// exactly what makes `JSONEncoder` refuse the palette and cost the reader a theme.
    func testACornerScaleAssignedAfterConstructionIsClampedToo() {
        var palette = PanelPalette(name: "Odd", accent: ThemeColor(0.5, 0.5, 0.5))
        palette.cornerScale = .nan
        XCTAssertEqual(palette.cornerScale, 1)
        palette.cornerScale = 5
        XCTAssertEqual(palette.cornerScale, PanelPalette.cornerScaleRange.upperBound)
        palette.cornerScale = -1
        XCTAssertEqual(palette.cornerScale, PanelPalette.cornerScaleRange.lowerBound)
        XCTAssertNotNil(PanelPalette.encode(palette), "and the palette still encodes")
    }

    /// The cost of getting the line above wrong, and why it is not a cosmetic bug:
    /// `JSONEncoder` refuses a non-finite `Double`, so a NaN that reached a stored field
    /// did not draw a strange corner — it made the whole palette unencodable, and
    /// `CorePreferences` then had nothing to write.
    func testAPaletteBuiltWithANaNStillEncodes() throws {
        let odd = PanelPalette(name: "Odd", accent: ThemeColor(0.5, 0.5, 0.5), cornerScale: .nan)
        let encoded = try XCTUnwrap(PanelPalette.encode(odd))
        XCTAssertEqual(PanelPalette.decode(encoded), odd)
    }

    /// A hand edit that empties the name leaves neither a preset's name nor one the reader
    /// chose, and `name` is stored — so it would go back out through `encode` and stay.
    func testANameThatIsBlankReadsAsCustom() throws {
        XCTAssertEqual(try XCTUnwrap(PanelPalette.decode(#"{"name":""}"#)).name, "Custom")
        XCTAssertEqual(try XCTUnwrap(PanelPalette.decode(#"{"name":"   "}"#)).name, "Custom")
        XCTAssertEqual(try XCTUnwrap(PanelPalette.decode(#"{"name":"Mine"}"#)).name, "Mine")
    }

    func testTextThatIsNotJSONIsNoPalette() {
        XCTAssertNil(PanelPalette.decode("{ not json"))
        XCTAssertNil(PanelPalette.decode(""))
    }

    // MARK: Presets

    /// Colour is never the only carrier of a verdict — every one is drawn with its own
    /// symbol and its name in words — but a preset that made two verdicts the same colour
    /// would still be throwing away information the reader is entitled to.
    func testEveryPresetKeepsFiveDistinguishableVerdicts() {
        for preset in PanelPalette.presets {
            let verdicts = [preset.supported, preset.contradicted, preset.mixed,
                            preset.insufficient, preset.opinion]
            XCTAssertEqual(Set(verdicts).count, 5, "\(preset.name) reuses a verdict colour")
        }
    }

    /// The panel floats over the whole desktop, so a scrim is what stands in when there
    /// is no surface — crisp over an editor, unreadable over a bright photo, otherwise.
    ///
    /// Every preset, not only the translucent ones: `surface` is a colour the reader can
    /// hand back to Automatic, and the scrim is what they are handing it back to. The
    /// filtered version of this test also passed vacuously if every preset shipped a
    /// surface, which by then eight of the ten did.
    func testEveryPresetKeepsAScrimToFallBackOn() {
        XCTAssertFalse(PanelPalette.presets.isEmpty, "there is nothing to check otherwise")
        for preset in PanelPalette.presets {
            XCTAssertGreaterThan(preset.scrim.alpha, 0,
                                 "\(preset.name) leaves nothing behind a cleared surface")
        }
    }

    /// A preset that states its own text colour has to state one that can be read on its
    /// own surface.
    func testEveryPresetsTextCanBeReadOnItsSurface() {
        var checked = 0
        for preset in PanelPalette.presets {
            guard let surface = preset.surface, let text = preset.primaryText else { continue }
            checked += 1
            // The 0.4 bar is calibrated to `luminance` as it is written — the plain
            // weighted sum of sRGB components. Solarized is the only preset anywhere near
            // it: base0 text on base03 comes to 0.437, where the next tightest (Bubblegum)
            // is 0.811. Gamma-linearised WCAG relative luminance would put Solarized at
            // roughly 0.26 and fail it, for a pairing that is canonical Solarized and
            // reads fine — so if `luminance` ever changes formula, this number has to
            // change with it rather than the preset.
            XCTAssertGreaterThan(abs(surface.luminance - text.luminance), 0.4,
                                 "\(preset.name) puts text too close to its own surface")
        }
        // Counted, because `continue` on both optionals means a preset set that stopped
        // stating its own colours would leave this test green while asserting nothing.
        XCTAssertGreaterThan(checked, 0, "no preset states both a surface and a text colour")
    }

    // MARK: Colours a person typed

    /// The type's argument for plain sRGB is that somebody can paste a colour into the
    /// settings file. A string is what they will paste.
    func testAHexStringDecodesWhereComponentsAreExpected() throws {
        // Inside an array rather than as a bare top-level string: a JSON fragment is not
        // what a settings file holds, and this keeps the test about the decoder.
        let decoded = try JSONDecoder().decode(
            [ThemeColor].self, from: Data(##"["#FF8A4C", "0xFED"]"##.utf8))
        XCTAssertEqual(decoded.first, ThemeColor(hex: "#FF8A4C"))
        XCTAssertEqual(decoded.first?.hexString, "#FF8A4C")
        XCTAssertEqual(decoded[1], ThemeColor(hex: "#FFEEDD"), "the short form too")
    }

    /// A string that is not a colour is not silently read as black: it falls through to
    /// the component path, which cannot read keys from a string and throws — which is
    /// what `PanelPalette`'s lenient decoder is there to turn into that field's default.
    func testAStringThatIsNotAColourIsNotDecoded() {
        XCTAssertThrowsError(
            try JSONDecoder().decode([ThemeColor].self, from: Data(#"["nonsense"]"#.utf8)))
    }

    /// And the object form `encode` actually writes still round-trips unchanged.
    func testTheEncodedFormStillDecodesToItself() throws {
        let colour = ThemeColor(0.2, 0.4, 0.6, 0.8)
        let data = try JSONEncoder().encode(colour)
        XCTAssertEqual(try JSONDecoder().decode(ThemeColor.self, from: data), colour)
    }

    /// CSS Color 4's four-digit short form, which the parser used to reject.
    func testFourDigitHexCarriesItsAlpha() throws {
        let colour = try XCTUnwrap(ThemeColor(hex: "#FEDC"))
        XCTAssertEqual(colour, ThemeColor(hex: "#FFEEDDCC"))
        XCTAssertEqual(colour.alpha, 0.8, accuracy: 0.01)
        // Still nothing that is not a short or a long form.
        XCTAssertNil(ThemeColor(hex: "#FEDCB"))
        XCTAssertNil(ThemeColor(hex: "#FE"))
    }

    /// A translucent colour shows whatever is behind it, so calling it fully light would
    /// wave through a preset whose surface is in practice the desktop.
    func testLuminanceAccountsForAlpha() {
        XCTAssertEqual(ThemeColor(1, 1, 1).luminance, 1, accuracy: 0.001)
        XCTAssertEqual(ThemeColor(0, 0, 0).luminance, 0, accuracy: 0.001)
        XCTAssertEqual(ThemeColor(1, 1, 1, 0).luminance, 0.5, accuracy: 0.001,
                       "a fully transparent colour is not a light one")
        XCTAssertLessThan(ThemeColor(1, 1, 1, 0.1).luminance, 0.6)
    }

    func testPresetNamesAreUniqueSoThePickerCanUseThem() {
        XCTAssertEqual(Set(PanelPalette.presets.map(\.name)).count, PanelPalette.presets.count)
    }

    /// Compared on values rather than the name, so a palette edited back to exactly what a
    /// preset says is recognised as that preset again — and one that merely borrowed the
    /// name is not.
    func testAPresetIsRecognisedByItsValuesNotItsName() {
        XCTAssertEqual(PanelPalette.terminal.matchingPreset?.name, "Terminal")

        var renamed = PanelPalette.terminal
        renamed.name = "Custom"
        XCTAssertEqual(renamed.matchingPreset?.name, "Terminal", "still Terminal underneath")

        var edited = PanelPalette.terminal
        edited.accent = ThemeColor(1, 0, 0)
        XCTAssertNil(edited.matchingPreset, "no longer Terminal, whatever it is called")

        var impostor = PanelPalette.ember
        impostor.name = "Terminal"
        XCTAssertEqual(impostor.matchingPreset?.name, "Ember")
    }

    /// The default has to be the colours Vervellum has always shipped.
    func testTheDefaultIsEmber() {
        XCTAssertEqual(PanelPalette.ember.accent.hexString, "#FF8A4C")
        XCTAssertEqual(PanelPalette.presets.first, .ember)
    }
}
