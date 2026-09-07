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

    func testReadsAndWritesAlpha() {
        let colour = ThemeColor(hex: "#00000029")
        XCTAssertEqual(colour?.alpha ?? 1, 0.161, accuracy: 0.01)
        XCTAssertEqual(colour?.hexString, "#00000029")
        XCTAssertEqual(ThemeColor(0, 0, 0, 1).hexString, "#000000", "opaque needs no alpha pair")
    }

    func testRejectsWhatIsNotAColour() {
        XCTAssertNil(ThemeColor(hex: ""))
        XCTAssertNil(ThemeColor(hex: "#12345"))
        XCTAssertNil(ThemeColor(hex: "cornflower"))
        XCTAssertNil(ThemeColor(hex: "#ggghhh"))
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

    /// The panel floats over the whole desktop. A theme with no opaque surface of its own
    /// needs a scrim, or the same paragraph is crisp over an editor and unreadable over a
    /// bright photo.
    func testEveryTranslucentPresetKeepsAScrim() {
        for preset in PanelPalette.presets where preset.surface == nil {
            XCTAssertGreaterThan(preset.scrim.alpha, 0,
                                 "\(preset.name) has neither a surface nor a scrim")
        }
    }

    /// A preset that states its own text colour has to state one that can be read on its
    /// own surface.
    func testEveryPresetsTextCanBeReadOnItsSurface() {
        for preset in PanelPalette.presets {
            guard let surface = preset.surface, let text = preset.primaryText else { continue }
            XCTAssertGreaterThan(abs(surface.luminance - text.luminance), 0.4,
                                 "\(preset.name) puts text too close to its own surface")
        }
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
