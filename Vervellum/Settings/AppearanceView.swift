import SwiftUI
import AppKit

/// The theme pane: pick a preset, then wreck it.
///
/// Written to be played with. Every control writes straight through to the preference,
/// so the panel repaints as the colour well moves — there is no Save button here and
/// there should not be one, because the only way to judge a theme is to look at it.
/// **Settings ▸ General ▸ Preview** puts the panel back beside this window while you do,
/// since opening Settings dismisses it.
///
/// The one thing the reader cannot break is meaning. Verdict colours are editable, but
/// each verdict keeps its own symbol and its written label everywhere it appears, so the
/// worst a palette can do is be ugly.
struct AppearanceView: View {

    @ObservedObject var preferences: Preferences

    /// Confirmation for the one destructive control on this pane.
    @State private var showsResetConfirmation = false

    var body: some View {
        SettingsPane {
            SettingsSection(
                title: "Theme",
                footnote: "Picking a preset copies its values here — it is a starting "
                    + "point, not a mode, so everything below stays yours to change. Turn "
                    + "on Settings ▸ General ▸ Preview to watch the panel change as you do.") {
                presetGrid
            }

            SettingsSection(
                title: "Colours",
                footnote: "Text and surface follow the system when left on Automatic, which "
                    + "is what lets a theme track Dark Mode, Increase Contrast and Reduce "
                    + "Transparency without having a light and a dark version of itself.") {
                colourWell("Accent", binding(\.accent))
                optionalColourWell("Text", keyPath: \.primaryText, automatic: "Automatic")
                optionalColourWell("Secondary text", keyPath: \.secondaryText,
                                   automatic: "Automatic")
                optionalColourWell("Surface", keyPath: \.surface, automatic: "System material")
                colourWell("Cards", binding(\.cardFill))
                colourWell("Chips", binding(\.chipFill))
                colourWell("Lines", binding(\.hairline))
                colourWell("Scrim", binding(\.scrim))
            }

            SettingsSection(
                title: "Shape and type",
                footnote: "Code and citations stay monospaced whatever the typeface says: "
                    + "there, alignment carries meaning.") {
                Picker("Typeface", selection: binding(\.fontDesign)) {
                    ForEach(ThemeFontDesign.allCases) { Text($0.label).tag($0) }
                }
                Picker("Backdrop", selection: binding(\.backdrop)) {
                    ForEach(ThemeBackdrop.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Corners")
                    Slider(value: binding(\.cornerScale),
                           in: PanelPalette.cornerScaleRange)
                    Text(cornerLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            SettingsSection(
                title: "Verdict colours",
                footnote: "Every verdict is also drawn with its own symbol and its name in "
                    + "words, so these can be anything you like without making the table "
                    + "unreadable — including to a colour-blind reader.") {
                colourWell("Supported", binding(\.supported))
                colourWell("Contradicted", binding(\.contradicted))
                colourWell("Mixed", binding(\.mixed))
                colourWell("Insufficient", binding(\.insufficient))
                colourWell("Opinion", binding(\.opinion))
            }

            SettingsSection(title: "Start over") {
                HStack {
                    Button("Reset to Ember") { showsResetConfirmation = true }
                    Text(currentName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Reset the theme?",
                            isPresented: $showsResetConfirmation) {
            Button("Reset", role: .destructive) { preferences.panelPalette = .ember }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every colour, the typeface, the corners and the backdrop go back to the "
                 + "colours Vervellum ships with.")
        }
    }

    // MARK: Presets

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            ForEach(PanelPalette.presets, id: \.name) { preset in
                Button {
                    preferences.panelPalette = preset
                } label: {
                    presetSwatch(preset)
                }
                .buttonStyle(.plain)
                .help("Use the \(preset.name) theme")
            }
        }
    }

    /// A preset as a small picture of itself: its surface, its accent, and the five
    /// verdict colours in a row — which is what actually differs between two themes that
    /// both look "dark blue" in a list of names.
    private func presetSwatch(_ preset: PanelPalette) -> some View {
        let selected = preferences.panelPalette.matchingPreset?.name == preset.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(Color(preset.accent)).frame(width: 13, height: 13)
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(preset.accent))
                }
            }
            HStack(spacing: 3) {
                let verdicts = [preset.supported, preset.contradicted, preset.mixed,
                                preset.insufficient, preset.opinion]
                ForEach(verdicts.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(verdicts[index]))
                        .frame(height: 6)
                }
            }
        }
        .padding(9)
        .background(swatchSurface(preset),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color(preset.accent) : Color(preset.hairline),
                              lineWidth: selected ? 2 : 1)
        }
        // The swatch draws in the preset's own colours, so its label has to come from the
        // preset too — otherwise Terminal's name is black text on near-black.
        .foregroundStyle(preset.primaryText.map { Color($0) } ?? Color.primary)
    }

    private func swatchSurface(_ preset: PanelPalette) -> Color {
        preset.surface.map { Color($0) } ?? Color.primary.opacity(0.06)
    }

    private var currentName: String {
        preferences.panelPalette.matchingPreset.map { "Using \($0.name)." }
            ?? "Using your own colours."
    }

    private var cornerLabel: String {
        let scale = preferences.panelPalette.cornerScale
        if scale <= 0.01 { return "Square" }
        return String(format: "%.0f%%", scale * 100)
    }

    // MARK: Bindings

    /// A binding straight through to one field of the stored palette.
    ///
    /// Written on every drag of a colour well, which is the point: the panel repaints as
    /// the value moves, and judging a theme any other way is guesswork. Each write is one
    /// small settings write, which is what every other control in this window already
    /// does per keystroke.
    private func binding<Value>(_ keyPath: WritableKeyPath<PanelPalette, Value>)
        -> Binding<Value> {
        Binding(
            get: { preferences.panelPalette[keyPath: keyPath] },
            set: { newValue in
                var palette = preferences.panelPalette
                palette[keyPath: keyPath] = newValue
                // Editing anything makes it no longer that preset, and the name is what
                // the pane says out loud — so it stops claiming to be Terminal the moment
                // it stops looking like it. `matchingPreset` compares values, so a palette
                // edited back to a preset exactly is recognised again.
                palette.name = palette.matchingPreset?.name ?? "Custom"
                preferences.panelPalette = palette
            })
    }

    private func colourWell(_ title: String, _ value: Binding<ThemeColor>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(value.wrappedValue) },
            set: { value.wrappedValue = $0.themeColor ?? value.wrappedValue }),
                    supportsOpacity: true)
    }

    /// A colour that may be "follow the system", which several of them default to.
    @ViewBuilder
    private func optionalColourWell(_ title: String,
                                    keyPath: WritableKeyPath<PanelPalette, ThemeColor?>,
                                    automatic: String) -> some View {
        let stored = binding(keyPath)
        HStack {
            Toggle(isOn: Binding(
                get: { stored.wrappedValue != nil },
                set: { isOn in
                    // Turning it on starts from what the panel is already showing rather
                    // than from black, so the first drag is an adjustment and not a
                    // recovery. Turning it off remembers, because the toggle sits one
                    // click away from a colour someone spent a while choosing and
                    // "Automatic" should be a thing you can look at and undo.
                    if isOn {
                        stored.wrappedValue = stored.wrappedValue
                            ?? setAside[keyPath]
                            ?? fallback(for: keyPath)
                    } else {
                        setAside[keyPath] = stored.wrappedValue
                        stored.wrappedValue = nil
                    }
                })) {
                Text(title)
            }
            .toggleStyle(.checkbox)

            if let current = stored.wrappedValue {
                ColorPicker("", selection: Binding(
                    get: { Color(current) },
                    set: { stored.wrappedValue = $0.themeColor ?? current }),
                            supportsOpacity: true)
                    .labelsHidden()
                    // The label is hidden from the eye, not from VoiceOver: without this
                    // all three of these read as "color well" and none says which.
                    .accessibilityLabel(title)
            } else {
                Text(automatic)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Colours handed back to Automatic this session, so switching one on again returns
    /// what it was rather than a constant. Not persisted: it is an undo for a click, not
    /// a second copy of the theme.
    @State private var setAside: [WritableKeyPath<PanelPalette, ThemeColor?>: ThemeColor] = [:]

    /// Where an optional colour starts when it is switched on and nothing was set aside.
    private func fallback(for keyPath: WritableKeyPath<PanelPalette, ThemeColor?>) -> ThemeColor {
        if keyPath == \PanelPalette.surface { return ThemeColor(0.10, 0.10, 0.12) }
        if keyPath == \PanelPalette.secondaryText { return ThemeColor(0.55, 0.55, 0.58) }
        return ThemeColor(0.90, 0.90, 0.92)
    }
}

extension Color {
    /// The stored form of a colour chosen in a `ColorPicker`.
    ///
    /// Converted through sRGB, which is what `ThemeColor` documents itself as holding, so
    /// a colour picked from the wide-gamut wheel is stored as the sRGB it will be drawn
    /// as rather than as components that mean something else.
    var themeColor: ThemeColor? {
        let converted = NSColor(self).usingColorSpace(.sRGB)
        guard let converted else { return nil }
        return ThemeColor(Double(converted.redComponent),
                          Double(converted.greenComponent),
                          Double(converted.blueComponent),
                          Double(converted.alphaComponent))
    }
}
