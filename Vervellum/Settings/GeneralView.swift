import SwiftUI

/// Panel behaviour, history, and updates.
struct GeneralView: View {

    /// The limits offered. A short list of round numbers rather than a slider: this is a
    /// number nobody wants to tune to the unit, and every value here is inside
    /// `ThreadLibrary.keptThreadsRange`.
    ///
    /// Asserted rather than asserted-by-comment. A row outside the range would clamp on
    /// its way to the store and the picker would settle on a different row than the one
    /// the reader clicked — which is the blank-selection confusion the note by the picker
    /// warns about, arrived at from the other side.
    static let threadLimits: [Int] = {
        let limits = [25, 50, 100, 200, 500, 1000]
        assert(limits.allSatisfy { ThreadLibrary.keptThreadsRange.contains($0) },
               "a row outside the clamp range can never stay selected")
        return limits
    }()

    /// The round numbers, plus whatever the limit actually is right now.
    private var offeredThreadLimits: [Int] {
        Array(Set(GeneralView.threadLimits + [preferences.keptThreads])).sorted()
    }


    @ObservedObject var preferences: Preferences
    @ObservedObject var store: ThreadStore
    @ObservedObject var updateChecker: UpdateChecker

    @State private var showsEraseConfirmation = false
    /// Whether the panel is on screen so these settings can be watched taking effect.
    /// Not persisted: it is a state of this window, not a preference.
    @State private var previewsPanel = false

    var body: some View {
        SettingsPane {
            SettingsSection(
                title: "Panel",
                footnote: "The panel opens on whichever screen your pointer is on, and floats above "
                    + "full-screen apps without switching Spaces. Opening Settings dismisses it, "
                    + "because it would otherwise cover this window — so put it back with Preview "
                    + "to watch these settings take effect. Every change below applies to an open "
                    + "panel immediately.") {
                Toggle("Preview the panel while I adjust these", isOn: $previewsPanel)
                Picker("Position", selection: Binding(
                    get: { preferences.panelSide },
                    set: { preferences.panelSide = $0 })) {
                    ForEach(PanelSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Width") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(preferences.panelWidth) },
                            set: { preferences.panelWidth = CGFloat($0) }),
                               in: Double(PanelPlacement.minimumWidth)...Double(PanelPlacement.maximumWidth))
                        Text("\(Int(preferences.panelWidth)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                if preferences.panelSide == .center {
                    // Only the centered layout has a height of its own — an edge panel
                    // fills the screen's visible height — so the control appears with the
                    // layout it belongs to rather than sitting there doing nothing.
                    LabeledContent("Height") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(preferences.panelHeight) },
                                set: { preferences.panelHeight = CGFloat($0) }),
                                   in: Double(PanelPlacement.minimumHeight)...2000)
                            Text("\(Int(preferences.panelHeight)) pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }

                LabeledContent("Text size") {
                    HStack {
                        Slider(value: Binding(
                            get: { preferences.textScale },
                            set: { preferences.textScale = $0 }), in: 0.85...1.4)
                        Text(String(format: "%.0f%%", preferences.textScale * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            SettingsSection(
                title: "Behaviour",
                footnote: "Dismissing on focus loss makes the panel behave like Spotlight. It is off "
                    + "by default because research takes tens of seconds and the answer is meant to "
                    + "be read while you work — even with it on, a running search keeps the panel up.") {
                Toggle("Close the panel when it loses focus", isOn: Binding(
                    get: { preferences.dismissOnFocusLoss },
                    set: { preferences.dismissOnFocusLoss = $0 }))
                Toggle("Show what each search did", isOn: Binding(
                    get: { preferences.showProcessTrail },
                    set: { preferences.showProcessTrail = $0 }))
                Toggle("Return sends the question (Shift-Return for a new line)", isOn: Binding(
                    get: { preferences.submitOnReturn },
                    set: { preferences.submitOnReturn = $0 }))
                Toggle("Launch Vervellum at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { preferences.launchAtLogin = $0 }))
            }

            SettingsSection(
                title: "History",
                footnote: "Threads are stored as JSON in Vervellum's Application Support folder, "
                    + "readable only by you. Turning history off deletes the file — it does not "
                    + "merely hide it.") {
                Toggle("Keep past threads", isOn: Binding(
                    get: { preferences.historyEnabled },
                    // Only the preference, for the reason spelled out at the picker
                    // below: `AppDelegate` forwards both to the live store, and writing
                    // the store here as well would be a second path to keep in step by
                    // hand. This used to do both, five lines above a comment arguing
                    // against it.
                    set: { preferences.historyEnabled = $0 }))
                // Shown only while history is on: a limit on a history that is not being
                // kept is a control with nothing to do.
                if preferences.historyEnabled {
                    Picker("Keep at most", selection: Binding(
                        get: { preferences.keptThreads },
                        // Only the preference is written. `AppDelegate` forwards every
                        // preference change to the live store, so assigning both here
                        // would be a second path to keep in step by hand — and the one
                        // that goes stale is the one that makes this control show a
                        // limit the archive is not applying.
                        set: { limit in preferences.keptThreads = limit })) {
                        // The stored value is clamped, not snapped to this list, so a
                        // settings file holding 7 reads back as 10 — which has no row
                        // here, and a Picker whose selection matches no option renders
                        // blank. Offering the current value too means the control always
                        // shows where it actually is.
                        ForEach(offeredThreadLimits, id: \.self) { limit in
                            Text("\(limit) threads").tag(limit)
                        }
                    }
                    .help("Threads past this are deleted immediately and permanently when "
                          + "the limit is lowered — not at the next question.")
                }
                HStack {
                    Text("\(store.library.threads.count) thread\(store.library.threads.count == 1 ? "" : "s") stored")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete all…") { showsEraseConfirmation = true }
                        .disabled(store.library.threads.isEmpty)
                }
                // The file is still there. Saying so beats a toggle that reads "off"
                // over questions that are still on disk.
                if let failure = store.eraseFailure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection(
                title: "Updates",
                footnote: "Vervellum asks GitHub whether a newer release exists. It never installs "
                    + "one on its own: choosing Download saves the file to your Downloads folder "
                    + "and reveals it in the Finder.") {
                Toggle("Check for updates automatically", isOn: $updateChecker.automaticChecksEnabled)
                HStack {
                    Button("Check Now") { updateChecker.checkNow() }
                        .disabled(updateChecker.isChecking)
                    if let last = updateChecker.lastCheckDate {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        // The panel is a window, not a view in this hierarchy, so the toggle asks the
        // object that owns it. See `PanelController.setPreviewing(_:)`.
        .onChange(of: previewsPanel) { _, previewing in
            NotificationCenter.default.post(name: .vervellumPanelPreviewChanged, object: nil,
                                            userInfo: ["previewing": previewing])
        }
        // The Settings window is kept alive when it closes, so this view — and this
        // toggle's state — survives with it. Closing the window takes the preview panel
        // away; without this the switch would still read "on" the next time Settings was
        // opened, describing a panel that is not there.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumSettingsDidClose)) { _ in
            previewsPanel = false
        }
        .confirmationDialog("Delete every stored thread?",
                            isPresented: $showsEraseConfirmation) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the threads file from disk. It cannot be undone.")
        }
    }
}
