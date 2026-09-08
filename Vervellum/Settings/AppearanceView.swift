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
                        // The `Text` beside it is a sibling, not a label: without these
                        // VoiceOver reads "slider, 65%" and never says of what.
                        .accessibilityLabel("Corners")
                        .accessibilityValue(cornerLabel)
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
            Button("Reset", role: .destructive) {
                // The dialog promises everything goes back, and `setAside` is an undo for
                // a click on a checkbox — not for a reset. Left standing, switching Text
                // back on afterwards would return the colour that was just thrown away.
                setAside = [:]
                preferences.panelPalette = .ember
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every colour, the typeface, the corners and the backdrop go back to the "
                 + "colours Vervellum ships with.")
        }
    }

    // MARK: Presets

    private var presetGrid: some View {
        // Resolved once for the whole grid rather than per swatch: `matchingPreset` walks
        // every preset and copies two palettes for each, and ten rows asking it the same
        // question is the sort of thing that makes a colour well feel sticky to drag.
        let current = preferences.panelPalette.matchingPreset?.name
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                         alignment: .leading, spacing: 10) {
            ForEach(PanelPalette.presets, id: \.name) { preset in
                Button {
                    // Same reason Reset clears it: `setAside` is an undo for unticking a
                    // checkbox, and picking a preset is not that. Left standing, ticking
                    // Text back on after switching themes returned the *previous*
                    // theme's colour — and, since it matches no preset, relabelled the
                    // palette "Custom" one click after the reader asked for Ember.
                    setAside = [:]
                    preferences.panelPalette = preset
                } label: {
                    presetSwatch(preset, selected: current == preset.name)
                }
                .buttonStyle(.plain)
                .help("Use the \(preset.name) theme")
                // The checkmark says which preset is on to the eye only — the image
                // carries no label, and a plain button exposes no state of its own.
                .accessibilityAddTraits(current == preset.name ? [.isSelected] : [])
            }
        }
    }

    /// A preset as a small picture of itself: its surface, its accent, and the five
    /// verdict colours in a row — which is what actually differs between two themes that
    /// both look "dark blue" in a list of names.
    private func presetSwatch(_ preset: PanelPalette, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        return scale.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Bindings

    /// A binding straight through to one field of the stored palette.
    ///
    /// Written on every drag of a colour well, which is the point: the panel repaints as
    /// the value moves, and judging a theme any other way is guesswork. Each write is one
    /// small settings write, which is what every other control in this window already
    /// does per keystroke.
    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<PanelPalette, Value>)
        -> Binding<Value> {
        Binding(
            get: { preferences.panelPalette[keyPath: keyPath] },
            set: { newValue in
                var palette = preferences.panelPalette
                // A no-op write still copied the palette, walked all ten presets and
                // persisted. SwiftUI controls emit those, and the corner slider emits
                // far more events per drag than a colour well does.
                guard palette[keyPath: keyPath] != newValue else { return }
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
                    // Live on the way out as well as on the way in. The `set` below reads
                    // the binding for the same reason: a drag lands several events before
                    // SwiftUI re-renders, and `current` is the value this body was built
                    // with, so a read in that window answered with the pre-drag colour and
                    // the well flicked back to it.
                    get: { stored.wrappedValue.map { Color($0) } ?? Color(current) },
                    // The live value on the failure path, not the `current` this body was
                    // built with. A drag can land two sets before SwiftUI re-renders, so
                    // a conversion that fails on the second would have written the colour
                    // from before the first — undoing a change rather than declining one.
                    set: { stored.wrappedValue = $0.themeColor ?? stored.wrappedValue }),
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
    ///
    /// Resolved from the semantic colour the token falls back to while the slot is
    /// Automatic, rather than written out as constants. The constants were the dark
    /// answers to all three — so ticking Text on in Light Mode pinned near-white text to
    /// a light panel, which is exactly the recovery-not-adjustment the toggle above
    /// promises not to hand anybody. `Color.primary` and `Color.secondary` are what
    /// `PanelTheme.Palette` uses for a nil text colour, and the window background is what
    /// shows through a nil surface, so these are the panel's current appearance rather
    /// than a second opinion about it.
    private func fallback(for keyPath: WritableKeyPath<PanelPalette, ThemeColor?>) -> ThemeColor {
        if keyPath == \PanelPalette.surface { return Self.resolved(.windowBackgroundColor) }
        if keyPath == \PanelPalette.secondaryText { return Self.resolved(.secondaryLabelColor) }
        return Self.resolved(.labelColor)
    }

    /// `colour` as sRGB components, resolved against the appearance the app is drawing in.
    ///
    /// A semantic `NSColor` has no components until an appearance is named — reading them
    /// off one outside a drawing context answers for whichever appearance happened to be
    /// current, which in a settings window is not reliably the one on screen.
    private static func resolved(_ colour: NSColor) -> ThemeColor {
        // Mid grey only if the conversion fails, which it does not for these three: it is
        // a value that is obviously neither text nor a surface, rather than a black that
        // would look deliberate.
        var components = ThemeColor(0.5, 0.5, 0.5)
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let srgb = colour.usingColorSpace(.sRGB) else { return }
            components = ThemeColor(Double(srgb.redComponent),
                                    Double(srgb.greenComponent),
                                    Double(srgb.blueComponent),
                                    Double(srgb.alphaComponent))
        }
        return components
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
