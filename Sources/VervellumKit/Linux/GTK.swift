#if os(Linux)
import Foundation
import CGtk

/// A thin Swift layer over GTK4.
///
/// Every raw C call in the Linux front end goes through this file, on purpose. GObject
/// interop is the part most likely to be wrong, and concentrating it here makes it
/// reviewable and keeps the interface code readable.
///
/// The casts and macro gaps are handled in `Sources/CGtk/shim.h` rather than here.
/// That is not tidiness: Swift represents an *opaque* GTK type (`GtkLabel`,
/// `GtkScrolledWindow`) as `OpaquePointer` and a *complete* one (`GtkWidget`,
/// `GtkWindow`) as `UnsafeMutablePointer<T>`, depending on whether the public header
/// defines the struct. Casting in C means Swift never has to know which is which, and
/// a mistake becomes a C compile error instead of a silent pointer reinterpretation.
enum GTK {

    typealias Widget = UnsafeMutablePointer<GtkWidget>

    // MARK: Signals

    /// Holds a Swift closure for the lifetime of a signal connection.
    ///
    /// A C function pointer cannot capture, so the closure travels as `user_data` and
    /// is unboxed inside the trampoline. The matching `GClosureNotify` is the only hook
    /// that balances the retain when the object is finalised; without it every
    /// connection leaks its closure.
    private final class Box {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }

    private static let releaseBox: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<Box>.fromOpaque(data).release()
    }

    /// Connects a signal whose handler takes only the instance and the user data —
    /// `GtkButton`'s "clicked", `GApplication`'s "activate", "destroy".
    ///
    /// Only for two-argument signals. Anything else needs its own trampoline with the
    /// exact arity: see `onActionActivated`.
    static func onSignal(_ instance: UnsafeMutableRawPointer, _ name: String,
                         _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
        }
        vv_connect(instance, name, unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    /// Connects `GtkEventControllerKey`'s "key-pressed".
    ///
    /// Separate because the signature differs and because the return value matters:
    /// `true` stops the key reaching the widget underneath, which is how Return sends a
    /// question instead of also inserting a newline.
    static func onKeyPressed(_ controller: UnsafeMutableRawPointer,
                             _ handler: @escaping (_ keyval: UInt32, _ modifiers: UInt32) -> Bool) {
        let box = Unmanaged.passRetained(KeyBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType,
                                        UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
            guard let data else { return 0 }
            let handled = Unmanaged<KeyBox>.fromOpaque(data).takeUnretainedValue()
                .call(UInt32(keyval), UInt32(state.rawValue))
            return handled ? 1 : 0
        }
        vv_connect(controller, "key-pressed",
                   unsafeBitCast(trampoline, to: GCallback.self), box, releaseKeyBox)
    }

    /// Connects a `GSimpleAction`'s "activate".
    ///
    /// A *separate* function from `onSignal`, and the difference is not cosmetic. That
    /// signal's handler is `(GSimpleAction*, GVariant*, gpointer)` — three arguments,
    /// where a button's "clicked" has two. `GCallback` is `void(*)(void)`, so
    /// `unsafeBitCast` defeats every type check: connecting a two-argument trampoline
    /// here would read the `GVariant*` where the user data should be, and dereference
    /// it as the boxed closure. That is a crash, not a warning.
    static func onActionActivated(_ action: UnsafeMutableRawPointer,
                                  _ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().call()
        }
        vv_connect(action, "activate",
                   unsafeBitCast(trampoline, to: GCallback.self), box, releaseBox)
    }

    /// Connects a `GtkLabel`'s "activate-link", which fires when a markup link is
    /// clicked. Returning true suppresses GTK's own handler.
    static func onLinkActivated(_ label: Widget, _ handler: @escaping (String) -> Bool) {
        let box = Unmanaged.passRetained(LinkBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
                                        UnsafeMutableRawPointer?) -> gboolean = { _, uri, data in
            guard let data, let uri else { return 0 }
            let handled = Unmanaged<LinkBox>.fromOpaque(data).takeUnretainedValue()
                .call(String(cString: uri))
            return handled ? 1 : 0
        }
        vv_connect(UnsafeMutableRawPointer(label), "activate-link",
                   unsafeBitCast(trampoline, to: GCallback.self), box, releaseLinkBox)
    }

    // MARK: Drops and pastes

    /// What a drop or a paste turned out to be carrying.
    ///
    /// Paths rather than bytes for files: reading them is `AttachmentIntake`'s job on
    /// both platforms, and it refuses an oversized file from its directory entry rather
    /// than after loading it.
    enum Dropped: Equatable {
        case files([String])
        case image(Data)
    }

    /// Makes `widget` accept a drop of files or an image.
    ///
    /// The handler returns whether the drop was taken; a false lets GTK fall back to
    /// whatever the widget did before — a text drag onto the composer still inserts
    /// text, because a drag carrying only text never reaches here at all.
    static func onDrop(_ widget: Widget, _ handler: @escaping (Dropped) -> Bool) {
        // A nil here is a failed `g_object_new`, and losing drag-and-drop is not worth
        // taking the window down for: the composer still accepts a paste and a typed
        // question.
        guard let controller = vv_drop_target_new() else { return }
        let box = Unmanaged.passRetained(DropBox(handler)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<GValue>?,
                                        Double, Double,
                                        UnsafeMutableRawPointer?) -> gboolean = { _, value, _, _, data in
            guard let data, let value, let dropped = GTK.dropped(from: value) else { return 0 }
            let taken = Unmanaged<DropBox>.fromOpaque(data).takeUnretainedValue().call(dropped)
            return taken ? 1 : 0
        }
        vv_connect(UnsafeMutableRawPointer(controller), "drop",
                   unsafeBitCast(trampoline, to: GCallback.self), box, releaseDropBox)
        gtk_widget_add_controller(widget, controller)
    }

    /// Reads the clipboard for something to attach, and calls back on the main loop.
    ///
    /// Files win, then words, then pictures — the order the pasteboard uses, decided
    /// here for the same reasons.
    ///
    /// Text is answered by returning false *without calling the handler*: the caller
    /// reads that as "not mine" and lets GTK paste the words itself. A clipboard
    /// carrying a web page's words *and* its picture is a copy of the words.
    ///
    /// But not when it is carrying a file. A file manager offers the copied file as
    /// `text/uri-list` *and* as text — GDK will serialise a file list into a string for
    /// anyone who asks for one, which is what `has_text` asks — so a text-first guard
    /// answers yes for the commonest way there is to paste a file, and Ctrl-V drops
    /// `file:///home/…` into the question instead of attaching anything. Nothing about
    /// the words-over-picture rule argues for words over a file, and the macOS side has
    /// always read it the other way round.
    ///
    /// Otherwise exactly one asynchronous read is started, because the formats on the
    /// clipboard are known up front and trying all three in turn would mean two
    /// failures per paste.
    static func readClipboard(_ widget: Widget, _ handler: @escaping (Dropped?) -> Void) -> Bool {
        guard let clipboard = vv_widget_clipboard(widget) else { return false }

        let wantsFiles = vv_clipboard_has_files(clipboard) != 0
        guard wantsFiles || vv_clipboard_has_text(clipboard) == 0 else { return false }
        guard wantsFiles || vv_clipboard_has_texture(clipboard) != 0 else { return false }
        // A read has to ask for the type the clipboard advertises. Most apps put a file
        // *list* on it even for one file, but an app that put a single `G_TYPE_FILE`
        // there answers "type not contained" to a request for a list — and the paste
        // would fail for a file that is plainly on the clipboard.
        let wantsList = vv_clipboard_has_file_list(clipboard) != 0

        // The contract this release depends on: each `vv_clipboard_read_*` below is a
        // one-line wrapper around `gdk_clipboard_read_value_async`, which GLib
        // guarantees calls its callback exactly once — on failure included. A shim that
        // grew an early return without calling back would leak this box and everything
        // the handler captured; one that called back twice would over-release it. Both
        // are fixed in the shim, never with a defensive release here.
        let box = Unmanaged.passRetained(ClipboardBox(handler)).toOpaque()
        let callback: GAsyncReadyCallback = { source, result, data in
            guard let data else { return }
            // Retained once and released here: a read answers exactly once, and the
            // closure has nothing to be kept alive for afterwards.
            let handler = Unmanaged<ClipboardBox>.fromOpaque(data).takeRetainedValue().call
            guard let source, let result, let value = vv_clipboard_read_finish(source, result)
            else { return handler(nil) }
            handler(GTK.dropped(from: value))
        }
        switch (wantsFiles, wantsList) {
        case (true, true): vv_clipboard_read_files(clipboard, callback, box)
        case (true, false): vv_clipboard_read_file(clipboard, callback, box)
        // Spelled out rather than `default`, and `(false, true)` is unreachable — but
        // by the shim, not by anything here: `vv_clipboard_has_files` is
        // `can_provide(GDK_TYPE_FILE_LIST) || can_provide(G_TYPE_FILE)` (shim.h:235), so
        // a clipboard holding a list always answers yes to both. Naming the pair that
        // way keeps the compiler honest if the tuple grows, and says where to look if
        // the two shim predicates ever stop nesting — the fix would be there, as it is
        // for the callback contract above, rather than a defensive branch here.
        case (false, _): vv_clipboard_read_texture(clipboard, callback, box)
        }
        return true
    }

    /// Turns a dropped or pasted `GValue` into paths or PNG bytes.
    ///
    /// The `GValue` is borrowed in both cases and must not be unset here: a signal
    /// argument belongs to the emitter, and `gdk_clipboard_read_value_finish` is
    /// documented `transfer none` — "the returned data is owned by the instance". A
    /// `g_value_unset` on either would be a free of something still in use.
    private static func dropped(from value: UnsafePointer<GValue>) -> Dropped? {
        if vv_value_is_texture(value) != 0 {
            guard let bytes = vv_texture_png(value) else { return nil }
            // Transfer full, unlike the `GValue` this came out of: `vv_texture_png` ends
            // at `gdk_texture_save_to_png_bytes`, which encodes into a fresh `GBytes`
            // rather than lending one the texture owns. So this release is a release and
            // not the double free the paragraph above is about.
            defer { g_bytes_unref(bytes) }
            // `gsize`, not `Int`: it is unsigned and platform-width, and a mismatch
            // here is a pointer type error rather than a conversion.
            var size: gsize = 0
            guard let raw = g_bytes_get_data(bytes, &size), size > 0 else { return nil }
            return .image(Data(bytes: raw, count: Int(size)))
        }
        guard let array = vv_value_file_paths(value) else { return nil }
        // Transfer full, and the one place this file frees memory it did not allocate:
        // `vv_value_file_paths` builds a fresh NUL-terminated `strv` of copied paths
        // rather than handing back anything owned by the `GValue`. A shim that ever
        // "simplified" that into a borrowed pointer would turn this into a double free —
        // which is why the shim says so at its own end too.
        defer { g_strfreev(array) }
        var paths: [String] = []
        var cursor = array
        while let entry = cursor.pointee {
            paths.append(String(cString: entry))
            cursor += 1
        }
        return paths.isEmpty ? nil : .files(paths)
    }

    private final class DropBox {
        let call: (Dropped) -> Bool
        init(_ call: @escaping (Dropped) -> Bool) { self.call = call }
    }
    private static let releaseDropBox: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<DropBox>.fromOpaque(data).release()
    }

    private final class ClipboardBox {
        let call: (Dropped?) -> Void
        init(_ call: @escaping (Dropped?) -> Void) { self.call = call }
    }

    private final class KeyBox {
        let call: (UInt32, UInt32) -> Bool
        init(_ call: @escaping (UInt32, UInt32) -> Bool) { self.call = call }
    }
    private static let releaseKeyBox: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<KeyBox>.fromOpaque(data).release()
    }

    private final class LinkBox {
        let call: (String) -> Bool
        init(_ call: @escaping (String) -> Bool) { self.call = call }
    }
    private static let releaseLinkBox: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<LinkBox>.fromOpaque(data).release()
    }

    // MARK: Threading

    /// Runs `work` on the GTK main loop.
    ///
    /// This is the **only** correct way to touch the interface from a Swift concurrency
    /// task on Linux. A GLib main loop does not drain libdispatch's main queue, so
    /// `DispatchQueue.main.async` never fires and a `MainActor` hop hangs forever — and
    /// it fails silently, with no warning and no crash, so the symptom is a window that
    /// simply never updates.
    static func onMainLoop(_ work: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data else { return 0 }
            let unmanaged = Unmanaged<Box>.fromOpaque(data)
            unmanaged.takeUnretainedValue().call()
            unmanaged.release()
            return 0   // G_SOURCE_REMOVE
        }
        g_idle_add(unsafeBitCast(trampoline, to: GSourceFunc.self), box)
    }

    // MARK: Layout

    /// Keep borrowed widget pointers valid when the window manager closes the panel.
    static func hideOnClose(_ window: Widget) {
        gtk_window_set_hide_on_close(vv_window(window), 1)
    }

    static func verticalBox(spacing: Int32 = 0) -> Widget { vv_vbox(spacing) }
    static func horizontalBox(spacing: Int32 = 0) -> Widget { vv_hbox(spacing) }

    static func append(_ parent: Widget, _ child: Widget) {
        gtk_box_append(vv_box(parent), child)
    }

    static func removeAllChildren(of parent: Widget) {
        while let child = gtk_widget_get_first_child(parent) {
            gtk_box_remove(vv_box(parent), child)
        }
    }

    static func margins(_ widget: Widget, _ all: Int32) { vv_set_margins(widget, all) }

    static func expandVertically(_ widget: Widget) { gtk_widget_set_vexpand(widget, 1) }

    static func addStyle(_ widget: Widget, _ name: String) {
        gtk_widget_add_css_class(widget, name)
    }

    /// A thin vertical rule, for separating groups inside a horizontal box.
    ///
    /// There is no `removeStyle` counterpart to `addStyle` here and none is wanted: a
    /// row whose selection changes is rebuilt (`removeAllChildren` then append), which
    /// is what the attachment row already does, so a widget never has to un-learn a
    /// class it was given.
    static func verticalSeparator() -> Widget {
        gtk_separator_new(GTK_ORIENTATION_VERTICAL)
    }

    // MARK: Text

    /// A wrapping, selectable label carrying Pango markup.
    ///
    /// Markup rather than a text view: it gives bold, italic, monospace, colour and
    /// clickable links for the cost of one string, with no tag table to manage — which
    /// is most of what rendering a research answer needs.
    static func markupLabel(_ markup: String) -> Widget {
        let label = gtk_label_new(nil)!
        gtk_label_set_markup(vv_label(label), markup)
        gtk_label_set_wrap(vv_label(label), 1)
        gtk_label_set_wrap_mode(vv_label(label), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_xalign(vv_label(label), 0)
        gtk_label_set_selectable(vv_label(label), 1)
        gtk_widget_set_halign(label, GTK_ALIGN_FILL)
        return label
    }

    static func setMarkup(_ label: Widget, _ markup: String) {
        gtk_label_set_markup(vv_label(label), markup)
    }

    /// A scroller that grows with its content up to `maxHeight`, then scrolls.
    ///
    /// `propagate-natural-height` plus `max-content-height` is the whole supported
    /// recipe; a manual size-allocate handler is the usual wrong answer.
    static func scrolled(_ child: Widget, maxHeight: Int32? = nil) -> Widget {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(vv_scrolled(scroller), child)
        gtk_scrolled_window_set_policy(vv_scrolled(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        if let maxHeight {
            gtk_scrolled_window_set_propagate_natural_height(vv_scrolled(scroller), 1)
            gtk_scrolled_window_set_max_content_height(vv_scrolled(scroller), maxHeight)
        } else {
            gtk_widget_set_vexpand(scroller, 1)
        }
        return scroller
    }

    /// Whether the scroller is at (or within a few pixels of) the end of its content.
    static func isScrolledToBottom(_ scroller: Widget) -> Bool {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(vv_scrolled(scroller)) else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let end = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
        return value >= end - 8
    }

    /// Scrolls to the end of the content. Call from an idle after a rebuild, once
    /// the adjustment's upper bound reflects the new children.
    static func scrollToBottom(_ scroller: Widget) {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(vv_scrolled(scroller)) else { return }
        gtk_adjustment_set_value(adjustment,
                                 gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
    }

    /// The composer: a wrapping text view.
    static func textView() -> Widget {
        let view = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(vv_text_view(view), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(vv_text_view(view), 6)
        gtk_text_view_set_bottom_margin(vv_text_view(view), 6)
        gtk_text_view_set_left_margin(vv_text_view(view), 8)
        gtk_text_view_set_right_margin(vv_text_view(view), 8)
        return view
    }

    static func text(of view: Widget) -> String {
        let buffer = gtk_text_view_get_buffer(vv_text_view(view))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    static func setText(_ view: Widget, _ value: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(vv_text_view(view)), value, -1)
    }

    static func button(_ title: String, _ action: @escaping () -> Void) -> Widget {
        let button = gtk_button_new_with_label(title)!
        onSignal(UnsafeMutableRawPointer(button), "clicked", action)
        return button
    }

    static func setEnabled(_ widget: Widget, _ enabled: Bool) {
        gtk_widget_set_sensitive(widget, enabled ? 1 : 0)
    }

    /// Attaches a key controller in the default bubble phase.
    static func observeKeys(_ widget: Widget, _ handler: @escaping (UInt32, UInt32) -> Bool) {
        let controller = gtk_event_controller_key_new()!
        onKeyPressed(UnsafeMutableRawPointer(controller), handler)
        gtk_widget_add_controller(widget, controller)
    }

    // MARK: Keys

    /// Numpad and ISO Enter as well as the main one — otherwise a numpad Enter inserts
    /// a newline instead of sending, which reads as the app ignoring the key.
    static func isReturn(_ keyval: UInt32) -> Bool {
        keyval == vv_key_return() || keyval == vv_key_kp_enter() || keyval == vv_key_iso_enter()
    }

    static func isEscape(_ keyval: UInt32) -> Bool { keyval == vv_key_escape() }
    /// Control-V. The paste that GTK would otherwise handle by itself, intercepted only
    /// when the clipboard is carrying something a text view cannot show.
    ///
    /// Both spellings of the key, because a keyval follows the effective lock state: with
    /// Caps Lock on, Ctrl-V arrives as `GDK_KEY_V`, and matching only the lowercase one
    /// would make pasting a screenshot fail for exactly the users who could never work
    /// out why.
    ///
    /// Shift disqualifies the gesture whichever spelling arrives, and that is the whole
    /// of the rule: plain Ctrl-V never carries Shift, while Ctrl-Shift-V — a gesture of
    /// its own in most applications — arrives capitalised with Caps Lock *off* and in
    /// lowercase with it *on*, because the two locks cancel. Guarding only the capital
    /// left the second of those looking exactly like a plain paste.
    ///
    /// Both spellings are Latin ones, and that is a known gap rather than an oversight.
    /// A keyval follows the active keyboard group, so under a Cyrillic or Greek layout
    /// the same physical key arrives as its native letter even with Control held, and
    /// this answers false. The paste is then GTK's, which inserts the clipboard's text
    /// flavour — for a copied file that is the `file:///…` URI, which is the thing the
    /// interception exists to keep out of a question. Closing it means matching the
    /// event's hardware keycode instead of its keyval, which is a value this does not
    /// receive; it belongs to whatever revisits how keys reach here.
    static func isPaste(_ keyval: UInt32, _ modifiers: UInt32) -> Bool {
        guard hasControl(modifiers), !hasShift(modifiers) else { return false }
        return keyval == vv_key_v() || keyval == vv_key_capital_v()
    }
    static func hasShift(_ modifiers: UInt32) -> Bool { modifiers & vv_mask_shift() != 0 }
    static func hasControl(_ modifiers: UInt32) -> Bool { modifiers & vv_mask_control() != 0 }

    // MARK: Styling

    static func applyStylesheet(_ css: String) {
        guard let display = gdk_display_get_default() else { return }
        let provider = gtk_css_provider_new()!
        vv_css_load(provider, css)
        vv_add_style_provider(display, provider)
        // `GtkCssProvider` is a final type with no public struct, so Swift imports it as
        // `OpaquePointer` — and there is no implicit conversion from that to the
        // `gpointer` that `g_object_unref` takes, unlike from a typed pointer. The cast
        // has to be spelled.
        g_object_unref(UnsafeMutableRawPointer(provider))
    }

    // MARK: Escaping

    /// Escapes text for inclusion in Pango markup.
    ///
    /// Mandatory for anything from the model or the web: one unescaped `<` in a search
    /// result's title makes `gtk_label_set_markup` reject the string, and the whole
    /// paragraph renders as an error message.
    static func escape(_ text: String) -> String {
        guard let escaped = g_markup_escape_text(text, -1) else { return "" }
        defer { g_free(escaped) }
        return String(cString: escaped)
    }

    /// Opens a URI in the user's browser, but only if it is one Vervellum fetched.
    ///
    /// The scheme check is the point: GTK's default `activate-link` handler will launch
    /// *any* URI in a label, including `file://`. Since the markup is built from model
    /// output, the handler is taken over and restricted to http(s).
    @discardableResult
    static func openLink(_ uri: String) -> Bool {
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        g_app_info_launch_default_for_uri(uri, nil, nil)
        return true
    }
}
#endif
