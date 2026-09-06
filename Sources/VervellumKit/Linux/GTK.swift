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
