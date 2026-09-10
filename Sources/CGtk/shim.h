/*
 * Umbrella header for the CGtk system-library target.
 *
 * gtk/gtk.h transitively pulls in GLib, GObject, GIO, Pango and GDK, which is
 * everything the Linux front end talks to. It is included through pkg-config's include
 * paths rather than an absolute path, because those differ by distribution and by
 * architecture (Debian multiarch puts glib's config header under
 * /usr/lib/<triple>/glib-2.0/include).
 *
 * Everything below it exists because of three hard limits on what Swift can import
 * from C, each of which would otherwise have to be worked around in Swift with
 * unsafe pointer arithmetic:
 *
 *   1. **Function-like macros are invisible to Swift.** GTK_WINDOW(), G_OBJECT(),
 *      G_CALLBACK() and g_signal_connect() are all macros, so every upcast and every
 *      signal connection needs a real function to call.
 *   2. **Swift cannot call C variadics at all.** g_object_set/get, g_variant_new and
 *      g_markup_printf_escaped are unreachable; where one is needed, a fixed-arity
 *      wrapper stands in for it.
 *   3. **Swift's #if cannot see the GTK version.** A call that is deprecated in one
 *      supported release and absent in another has to be forked here, where
 *      GTK_CHECK_VERSION works.
 *
 * A second, quieter reason: the Clang importer represents an opaque GTK type
 * (GtkLabel, GtkScrolledWindow, GtkEventController) as OpaquePointer and a complete
 * one (GtkWidget, GtkWindow) as UnsafeMutablePointer<T>, and which is which is not
 * something the Swift side should have to know. Casting in C means it never has to.
 */
#ifndef VERVELLUM_CGTK_SHIM_H
#define VERVELLUM_CGTK_SHIM_H

#include <gtk/gtk.h>

/* ---- Upcasts (the GTK_*() / G_*() macros) ---------------------------------- */

static inline GtkWindow          *vv_window(GtkWidget *w)     { return GTK_WINDOW(w); }
static inline GtkBox             *vv_box(GtkWidget *w)        { return GTK_BOX(w); }
static inline GtkLabel           *vv_label(GtkWidget *w)      { return GTK_LABEL(w); }
static inline GtkButton          *vv_button(GtkWidget *w)     { return GTK_BUTTON(w); }
static inline GtkTextView        *vv_text_view(GtkWidget *w)  { return GTK_TEXT_VIEW(w); }
static inline GtkScrolledWindow  *vv_scrolled(GtkWidget *w)   { return GTK_SCROLLED_WINDOW(w); }
static inline GtkStyleProvider   *vv_style_provider(GtkCssProvider *p) { return GTK_STYLE_PROVIDER(p); }
static inline GApplication       *vv_gapp(GtkApplication *a)  { return G_APPLICATION(a); }
static inline GActionMap         *vv_action_map(GtkApplication *a) { return G_ACTION_MAP(a); }
static inline GActionGroup       *vv_action_group(GtkApplication *a) { return G_ACTION_GROUP(a); }
static inline GAction            *vv_action(GSimpleAction *a) { return G_ACTION(a); }
static inline gpointer            vv_object(void *p)          { return (gpointer)p; }

/* ---- Signals (g_signal_connect is a macro; G_CALLBACK is another) ---------- */

static inline gulong vv_connect(gpointer instance,
                                const char *signal,
                                GCallback handler,
                                gpointer user_data,
                                GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, user_data, destroy, (GConnectFlags)0);
}

/* ---- Version forks --------------------------------------------------------- */

/*
 * gtk_css_provider_load_from_string() arrived in 4.12, deprecating
 * load_from_data(). Both are in scope here; Swift can see neither version.
 */
static inline void vv_css_load(GtkCssProvider *provider, const char *css) {
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(provider, css);
#else
    gtk_css_provider_load_from_data(provider, css, -1);
#endif
}

/* ---- Small conveniences ---------------------------------------------------- */

/* GTK_STYLE_PROVIDER_PRIORITY_APPLICATION is a macro constant. */
static inline void vv_add_style_provider(GdkDisplay *display, GtkCssProvider *provider) {
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/* The enum constants below are plain enums and *are* visible to Swift; these
 * wrappers exist only so a call site reads as one operation rather than four. */
static inline GtkWidget *vv_vbox(int spacing) {
    return gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing);
}

static inline GtkWidget *vv_hbox(int spacing) {
    return gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing);
}

static inline void vv_set_margins(GtkWidget *w, int all) {
    gtk_widget_set_margin_top(w, all);
    gtk_widget_set_margin_bottom(w, all);
    gtk_widget_set_margin_start(w, all);
    gtk_widget_set_margin_end(w, all);
}

/* Keyvals are macros in gdk/gdkkeysyms.h. */
static inline guint vv_key_return(void)    { return GDK_KEY_Return; }
static inline guint vv_key_kp_enter(void)  { return GDK_KEY_KP_Enter; }
static inline guint vv_key_iso_enter(void) { return GDK_KEY_ISO_Enter; }
static inline guint vv_key_escape(void)    { return GDK_KEY_Escape; }
static inline guint vv_mask_shift(void)    { return GDK_SHIFT_MASK; }
static inline guint vv_mask_control(void)  { return GDK_CONTROL_MASK; }

/* G_APPLICATION_DEFAULT_FLAGS is 4.6+; G_APPLICATION_FLAGS_NONE before that. */
static inline GApplicationFlags vv_app_default_flags(void) {
#if GLIB_CHECK_VERSION(2, 74, 0)
    return G_APPLICATION_DEFAULT_FLAGS;
#else
    return G_APPLICATION_FLAGS_NONE;
#endif
}

/* ---- Attachments: drops and clipboard reads -------------------------------- */

/*
 * A drop target that accepts what a question may carry: a list of files, one file, or
 * an image. Here rather than in Swift because every GType named is a macro —
 * GDK_TYPE_FILE_LIST expands to a function call — and because
 * gtk_drop_target_set_gtypes takes a C array.
 */
static inline GtkEventController *vv_drop_target_new(void) {
    GtkDropTarget *target = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    GType types[3] = { GDK_TYPE_FILE_LIST, G_TYPE_FILE, GDK_TYPE_TEXTURE };
    gtk_drop_target_set_gtypes(target, types, 3);
    return GTK_EVENT_CONTROLLER(target);
}

/* G_VALUE_HOLDS is a macro, and so is every GType constant it is asked about. */
static inline int vv_value_is_texture(const GValue *value) {
    return G_VALUE_HOLDS(value, GDK_TYPE_TEXTURE);
}

/*
 * A file's local path, or its URI when it has none.
 *
 * g_file_get_path() answers NULL for anything not on this machine — an sftp or network
 * location — and a drop of only those would then look to Swift like a drop of nothing,
 * which is a drag that appears to do nothing. Handing back the URI instead gives
 * `AttachmentIntake` something to refuse *by name*, which is what the other front end
 * does with the same gesture.
 */
static inline char *vv_file_path_or_uri(GFile *file) {
    if (file == NULL) return NULL;
    char *path = g_file_get_path(file);
    return path ? path : g_file_get_uri(file);
}

/*
 * Every path in a dropped or pasted value, as a NULL-terminated array the caller frees
 * with g_strfreev().
 *
 * The flattening is done here because the alternative is walking a GSList of opaque
 * GFile pointers from Swift, where each element arrives as a raw pointer that has to be
 * re-typed by hand — the exact reinterpretation this header exists to avoid. A value
 * holding neither shape yields an array of length zero rather than NULL, so the caller
 * has one thing to free and one thing to check.
 */
static inline char **vv_value_file_paths(const GValue *value) {
    GPtrArray *paths = g_ptr_array_new();
    if (G_VALUE_HOLDS(value, G_TYPE_FILE)) {
        char *path = vv_file_path_or_uri((GFile *)g_value_get_object(value));
        if (path) g_ptr_array_add(paths, path);
    } else if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *list = (GdkFileList *)g_value_get_boxed(value);
        GSList *files = list ? gdk_file_list_get_files(list) : NULL;
        for (GSList *node = files; node != NULL; node = node->next) {
            char *path = vv_file_path_or_uri((GFile *)node->data);
            if (path) g_ptr_array_add(paths, path);
        }
        /* The list is transfer-container: the GFiles belong to the value. */
        g_slist_free(files);
    }
    g_ptr_array_add(paths, NULL);
    return (char **)g_ptr_array_free(paths, FALSE);
}

/*
 * An image on the clipboard is a texture, and a provider will only look at a PNG.
 * The texture is borrowed from the value; the GBytes returned is transfer-full and
 * belongs to the caller, who owes it a g_bytes_unref.
 */
static inline GBytes *vv_texture_png(const GValue *value) {
    GdkTexture *texture = (GdkTexture *)g_value_get_object(value);
    return texture ? gdk_texture_save_to_png_bytes(texture) : NULL;
}

static inline GdkClipboard *vv_widget_clipboard(GtkWidget *widget) {
    return gtk_widget_get_clipboard(widget);
}

/*
 * What the clipboard can give us, asked before anything is read from it. The formats are
 * available synchronously; the contents are not, and knowing which of the three cases
 * this is means exactly one asynchronous read rather than three attempts in order.
 *
 * So: whether a read for `type` could succeed — which is *not* the same question as whether
 * the clipboard advertises that GType, and getting the two confused breaks every paste
 * that matters.
 *
 * A clipboard owned by another process carries MIME types and nothing else: a screenshot
 * tool publishes "image/png", a file manager "text/uri-list", an editor
 * "text/plain;charset=utf-8". A GType only appears on a clipboard *this* process owns.
 * So `gdk_content_formats_contain_gtype` answers no for every cross-application paste,
 * while `gdk_clipboard_read_value_async` would have answered yes — it unions the
 * deserializable MIME types onto the requested GType before it matches, which is exactly
 * why those two functions do not agree.
 *
 * This asks the question the way the read asks it, so the probe and the read cannot
 * disagree. The union is built as `gdk_clipboard_read_value_internal` builds it, and
 * both halves are transfer-full: the builder is consumed by
 * `builder_free_to_formats`, and the formats it produces are consumed by the union.
 */
static inline int vv_clipboard_can_provide(GdkClipboard *clipboard, GType type) {
    GdkContentFormatsBuilder *builder = gdk_content_formats_builder_new();
    gdk_content_formats_builder_add_gtype(builder, type);
    GdkContentFormats *want = gdk_content_formats_union_deserialize_mime_types(
        gdk_content_formats_builder_free_to_formats(builder));
    int yes = gdk_content_formats_match(want, gdk_clipboard_get_formats(clipboard));
    gdk_content_formats_unref(want);
    return yes;
}

/*
 * Text covers the charset spelling too, without naming it: X11 and Wayland offer
 * "text/plain;charset=utf-8", which an exact `contain_mime_type(formats, "text/plain")`
 * misses and the deserializer for `G_TYPE_STRING` does not.
 */
static inline int vv_clipboard_has_text(GdkClipboard *clipboard) {
    return vv_clipboard_can_provide(clipboard, G_TYPE_STRING);
}

static inline int vv_clipboard_has_files(GdkClipboard *clipboard) {
    return vv_clipboard_can_provide(clipboard, GDK_TYPE_FILE_LIST)
        || vv_clipboard_can_provide(clipboard, G_TYPE_FILE);
}

/*
 * Whether it is holding a *list*. A read has to ask for the type the clipboard can
 * actually provide: an app that put a single G_TYPE_FILE on it answers "type not
 * contained" to a request for a list, and the paste would fail for a file that is
 * plainly there.
 */
static inline int vv_clipboard_has_file_list(GdkClipboard *clipboard) {
    return vv_clipboard_can_provide(clipboard, GDK_TYPE_FILE_LIST);
}

static inline int vv_clipboard_has_texture(GdkClipboard *clipboard) {
    return vv_clipboard_can_provide(clipboard, GDK_TYPE_TEXTURE);
}

static inline void vv_clipboard_read_files(GdkClipboard *clipboard,
                                           GAsyncReadyCallback callback,
                                           gpointer user_data) {
    gdk_clipboard_read_value_async(clipboard, GDK_TYPE_FILE_LIST, G_PRIORITY_DEFAULT,
                                   NULL, callback, user_data);
}

static inline void vv_clipboard_read_file(GdkClipboard *clipboard,
                                          GAsyncReadyCallback callback,
                                          gpointer user_data) {
    gdk_clipboard_read_value_async(clipboard, G_TYPE_FILE, G_PRIORITY_DEFAULT,
                                   NULL, callback, user_data);
}

static inline void vv_clipboard_read_texture(GdkClipboard *clipboard,
                                             GAsyncReadyCallback callback,
                                             gpointer user_data) {
    gdk_clipboard_read_value_async(clipboard, GDK_TYPE_TEXTURE, G_PRIORITY_DEFAULT,
                                   NULL, callback, user_data);
}

/*
 * NULL on failure, which includes "the clipboard changed while we were asking".
 * The GValue is transfer-none -- "the returned data is owned by the instance", says
 * gdk_clipboard_read_value_finish -- so it is read and left alone. Unsetting or freeing
 * it here would be a double free the next read walks into, not a leak fixed.
 */
static inline const GValue *vv_clipboard_read_finish(GObject *source, GAsyncResult *result) {
    return gdk_clipboard_read_value_finish(GDK_CLIPBOARD(source), result, NULL);
}

/* Keyvals are macros in gdk/gdkkeysyms.h, as above. */
static inline guint vv_key_v(void)         { return GDK_KEY_v; }
/* Caps Lock changes which keyval a key sends, so Ctrl-V has two spellings. */
static inline guint vv_key_capital_v(void) { return GDK_KEY_V; }

#endif /* VERVELLUM_CGTK_SHIM_H */
