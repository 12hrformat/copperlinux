/* gui.c -- the GTK 3 review window.
 *
 * The window never treats a theme as trusted just because it was inspected:
 * the install itself runs through theme_install(), the same code path the
 * command line uses.  Nothing is applied to the desktop unless the user ticks
 * the apply box, and the checkboxes are the component selection from the
 * inspection.
 */
#include "theme.h"
#include "gui.h"

#include <gtk/gtk.h>
#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>

typedef struct App App;

typedef struct {
    ThemeComponent *component;
    GtkWidget *check;
} ComponentToggle;

typedef struct {
    App *app;
    ThemeInstallOptions options;
    GPtrArray *ids;
    ThemeInstallResult *result;
    GError *error;
    gboolean ok;
} InstallJob;

struct App {
    GtkWidget *window;
    GtkWidget *stack;
    GtkWidget *archive_label;
    GtkWidget *preview;
    GtkWidget *components_box;
    GtkWidget *warnings_box;
    GtkWidget *replace_check;
    GtkWidget *apply_check;
    GtkWidget *install_button;
    GtkWidget *open_button;
    GtkWidget *progress;
    GtkWidget *status;
    ThemeInspection *inspection;
    GPtrArray *toggles;          /* ComponentToggle* */
    char *preview_path;
    InstallJob *job;
    guint progress_source;
    gboolean busy;
};

/* Defined in main.c for the version string in --version. */
#ifndef COPPER_THEME_INSTALLER_VERSION
#define COPPER_THEME_INSTALLER_VERSION "0.1.0"
#endif

static void job_free(InstallJob *job);

/* ------------------------------------------------------------------------- */
/* Small widget helpers                                                      */

static void box_clear(GtkWidget *box)
{
    GList *children = gtk_container_get_children(GTK_CONTAINER(box));
    for (GList *l = children; l; l = l->next)
        gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(children);
}

static GtkWidget *label_new(const char *text, gboolean dim)
{
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    if (dim) {
        GtkStyleContext *ctx = gtk_widget_get_style_context(label);
        gtk_style_context_add_class(ctx, "dim-label");
    }
    return label;
}

static GtkWidget *markup_label(const char *markup)
{
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    return label;
}

static void show_error(App *app, const char *title, const char *detail)
{
    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(app->window), GTK_DIALOG_MODAL,
        GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE, "%s", title);
    if (detail && *detail)
        gtk_message_dialog_format_secondary_text(
            GTK_MESSAGE_DIALOG(dialog), "%s", detail);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static char *format_bytes(guint64 bytes)
{
    if (bytes >= 1024ULL * 1024ULL * 1024ULL)
        return g_strdup_printf("%.1f GiB", (double)bytes / (1024.0 * 1024 * 1024));
    if (bytes >= 1024ULL * 1024ULL)
        return g_strdup_printf("%.1f MiB", (double)bytes / (1024.0 * 1024));
    if (bytes >= 1024ULL)
        return g_strdup_printf("%.1f KiB", (double)bytes / 1024.0);
    return g_strdup_printf("%" G_GUINT64_FORMAT " B", bytes);
}

/* ------------------------------------------------------------------------- */
/* Preview image                                                             */

static void clear_preview(App *app)
{
    if (app->preview_path) {
        g_unlink(app->preview_path);
        g_free(app->preview_path);
        app->preview_path = NULL;
    }
    gtk_image_clear(GTK_IMAGE(app->preview));
}

static void load_preview(App *app)
{
    clear_preview(app);
    if (!app->inspection)
        return;

    for (guint i = 0; i < app->inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(app->inspection->components, i);
        if (!c->valid)
            continue;
        char *tmpl = g_build_filename(g_get_tmp_dir(),
                                      "copper-theme-preview-XXXXXX.png", NULL);
        int fd = g_mkstemp(tmpl);
        if (fd < 0) {
            g_free(tmpl);
            continue;
        }
        close(fd);
        g_unlink(tmpl);
        GError *error = NULL;
        if (theme_extract_preview(app->inspection->path, c->source_root,
                                  tmpl, &error)) {
            GError *pix_error = NULL;
            GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file_at_scale(
                tmpl, 280, 180, TRUE, &pix_error);
            if (pixbuf) {
                gtk_image_set_from_pixbuf(GTK_IMAGE(app->preview), pixbuf);
                g_object_unref(pixbuf);
                app->preview_path = tmpl;
                g_clear_error(&error);
                g_clear_error(&pix_error);
                return;
            }
            g_clear_error(&pix_error);
            g_unlink(tmpl);
        }
        g_clear_error(&error);
        g_free(tmpl);
    }
}

/* ------------------------------------------------------------------------- */
/* Review screen                                                             */

static void set_busy(App *app, gboolean busy)
{
    app->busy = busy;
    gtk_widget_set_sensitive(app->install_button, !busy);
    gtk_widget_set_sensitive(app->open_button, !busy);
    gtk_widget_set_sensitive(app->replace_check, !busy && app->inspection &&
                             app->inspection->valid);
    gtk_widget_set_sensitive(app->apply_check, !busy);
    gtk_widget_set_sensitive(app->components_box, !busy);
    if (!busy) {
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(app->progress), 0.0);
        gtk_progress_bar_set_text(GTK_PROGRESS_BAR(app->progress), NULL);
    }
}

static const char *kind_display(ThemeKind kind)
{
    switch (kind) {
    case THEME_KIND_GTK: return "GTK";
    case THEME_KIND_XFWM4: return "Window decorations";
    case THEME_KIND_ICONS: return "Icons";
    case THEME_KIND_CURSORS: return "Cursors";
    case THEME_KIND_FONTS: return "Fonts";
    default: return "Component";
    }
}

static void populate_review(App *app)
{
    box_clear(app->components_box);
    box_clear(app->warnings_box);
    g_ptr_array_set_size(app->toggles, 0);

    ThemeInspection *inspection = app->inspection;
    if (!inspection) {
        gtk_label_set_text(GTK_LABEL(app->archive_label),
                           "Choose a theme archive (ZIP, TAR, TAR.GZ, TAR.BZ2 or TAR.XZ).");
        gtk_widget_set_sensitive(app->install_button, FALSE);
        gtk_widget_set_sensitive(app->apply_check, FALSE);
        gtk_stack_set_visible_child_name(GTK_STACK(app->stack), "review");
        clear_preview(app);
        return;
    }

    char *size = format_bytes(inspection->archive_size);
    char *summary = g_strdup_printf("%s  -  %s",
                                    inspection->path ? inspection->path : "",
                                    size);
    gtk_label_set_text(GTK_LABEL(app->archive_label), summary);
    g_free(summary);
    g_free(size);

    guint valid_count = 0;
    guint conflicts = 0;
    gboolean any_apply = FALSE;
    for (guint i = 0; i < inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(inspection->components, i);
        if (c->valid)
            valid_count++;
        if (c->valid && c->conflict)
            conflicts++;
        if (c->valid && c->kind != THEME_KIND_FONTS)
            any_apply = TRUE;

        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        gtk_widget_set_margin_bottom(row, 8);

        char *title = g_markup_printf_escaped("<b>%s</b>", c->display_name);
        GtkWidget *check = gtk_check_button_new();
        GtkWidget *check_label = markup_label(title);
        g_free(title);
        gtk_container_add(GTK_CONTAINER(check), check_label);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(check),
                                     c->valid && c->selected);
        gtk_widget_set_sensitive(check, c->valid);
        gtk_box_pack_start(GTK_BOX(row), check, FALSE, FALSE, 0);

        char *bytes = format_bytes(c->total_bytes);
        char *detail = g_strdup_printf("%s - %s - %u file%s, %s",
                                       kind_display(c->kind),
                                       c->details ? c->details : "",
                                       c->file_count,
                                       c->file_count == 1 ? "" : "s",
                                       bytes);
        g_free(bytes);
        GtkWidget *detail_label = label_new(detail, TRUE);
        gtk_widget_set_margin_start(detail_label, 28);
        gtk_box_pack_start(GTK_BOX(row), detail_label, FALSE, FALSE, 0);
        g_free(detail);

        if (!c->valid && c->warning) {
            char *text = g_markup_printf_escaped("<span foreground=\"#b00020\">%s</span>",
                                                  c->warning);
            GtkWidget *warn = markup_label(text);
            g_free(text);
            gtk_widget_set_margin_start(warn, 28);
            gtk_box_pack_start(GTK_BOX(row), warn, FALSE, FALSE, 0);
        } else if (c->warning) {
            GtkWidget *warn = label_new(c->warning, TRUE);
            gtk_widget_set_margin_start(warn, 28);
            gtk_box_pack_start(GTK_BOX(row), warn, FALSE, FALSE, 0);
        }
        if (c->valid && c->conflict) {
            GtkWidget *note = label_new(
                "Already installed. Tick \"Replace existing themes\" to overwrite it.",
                TRUE);
            gtk_widget_set_margin_start(note, 28);
            gtk_box_pack_start(GTK_BOX(row), note, FALSE, FALSE, 0);
        }

        gtk_box_pack_start(GTK_BOX(app->components_box), row, FALSE, FALSE, 0);
        gtk_widget_show_all(row);

        ComponentToggle *toggle = g_new0(ComponentToggle, 1);
        toggle->component = c;
        toggle->check = check;
        g_ptr_array_add(app->toggles, toggle);
    }

    if (inspection->components->len == 0) {
        GtkWidget *empty = label_new(
            "This archive does not contain a theme Copper can install.", FALSE);
        gtk_box_pack_start(GTK_BOX(app->components_box), empty, FALSE, FALSE, 0);
        gtk_widget_show(empty);
    }

    /* Warnings: inspection notes plus unsupported components. */
    guint notes = inspection->warnings->len + inspection->unsupported->len;
    if (notes > 0) {
        GtkWidget *heading = markup_label("<b>Notes</b>");
        gtk_box_pack_start(GTK_BOX(app->warnings_box), heading, FALSE, FALSE, 0);
        gtk_widget_show(heading);
    }
    for (guint i = 0; i < inspection->warnings->len; i++) {
        GtkWidget *label = label_new(g_ptr_array_index(inspection->warnings, i),
                                     TRUE);
        gtk_box_pack_start(GTK_BOX(app->warnings_box), label, FALSE, FALSE, 0);
        gtk_widget_show(label);
    }
    for (guint i = 0; i < inspection->unsupported->len; i++) {
        char *text = g_strdup_printf("Not installed: %s",
                                     (char *)g_ptr_array_index(
                                         inspection->unsupported, i));
        GtkWidget *label = label_new(text, TRUE);
        g_free(text);
        gtk_box_pack_start(GTK_BOX(app->warnings_box), label, FALSE, FALSE, 0);
        gtk_widget_show(label);
    }

    gtk_widget_set_sensitive(app->replace_check, conflicts > 0);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(app->replace_check), FALSE);
    gtk_widget_set_sensitive(app->apply_check, any_apply);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(app->apply_check), FALSE);
    gtk_widget_set_sensitive(app->install_button, valid_count > 0);
    gtk_stack_set_visible_child_name(GTK_STACK(app->stack), "review");
    load_preview(app);
}

static void load_archive(App *app, const char *path)
{
    GError *error = NULL;
    ThemeInspection *inspection = theme_inspect_archive(path, &error);
    if (app->inspection)
        theme_inspection_free(app->inspection);
    app->inspection = inspection;

    if (!inspection) {
        populate_review(app);
        show_error(app, "The archive could not be opened",
                   error ? error->message : "Unknown error");
        g_clear_error(&error);
        return;
    }
    if (!inspection->valid && inspection->components->len == 0) {
        populate_review(app);
        show_error(app, "This is not a theme Copper can install",
                   inspection->error ? inspection->error
                                     : "No theme components were found.");
        return;
    }
    populate_review(app);
}

/* ------------------------------------------------------------------------- */
/* Installation                                                              */

static gboolean progress_tick(gpointer data)
{
    App *app = data;
    if (!app->job) {
        app->progress_source = 0;
        return G_SOURCE_REMOVE;
    }
    gint value = g_atomic_int_get(&app->job->options.progress);
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(app->progress),
                                  CLAMP(value, 0, 100) / 100.0);
    return G_SOURCE_CONTINUE;
}

static void append_lines(GString *text, const char *heading, GPtrArray *lines)
{
    if (!lines || lines->len == 0)
        return;
    g_string_append_printf(text, "%s\n", heading);
    for (guint i = 0; i < lines->len; i++)
        g_string_append_printf(text, "  - %s\n",
                               (char *)g_ptr_array_index(lines, i));
}

static void open_settings(GtkWindow *parent, gboolean window_manager)
{
    GError *error = NULL;
    if (!theme_open_settings(window_manager, &error)) {
        GtkWidget *dialog = gtk_message_dialog_new(
            parent, GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_CLOSE,
            "The settings window could not be opened");
        gtk_message_dialog_format_secondary_text(
            GTK_MESSAGE_DIALOG(dialog), "%s",
            error ? error->message : "Unknown error");
        gtk_dialog_run(GTK_DIALOG(dialog));
        gtk_widget_destroy(dialog);
        g_clear_error(&error);
    }
}

static gboolean finish_install(gpointer data)
{
    App *app = data;
    InstallJob *job = app->job;
    app->job = NULL;
    if (app->progress_source) {
        g_source_remove(app->progress_source);
        app->progress_source = 0;
    }
    set_busy(app, FALSE);
    gtk_statusbar_pop(GTK_STATUSBAR(app->status),
                      gtk_statusbar_get_context_id(GTK_STATUSBAR(app->status),
                                                   "install"));

    if (!job)
        return G_SOURCE_REMOVE;

    if (job->ok) {
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(app->progress), 1.0);
        GString *text = g_string_new(NULL);
        append_lines(text, "Installed:", job->result->installed);
        append_lines(text, "Skipped:", job->result->skipped);
        append_lines(text, "Notes:", job->result->warnings);
        if (job->options.apply && job->result->changed_desktop)
            g_string_append(text, "\nThe desktop was updated at your request.\n");
        else if (job->options.apply)
            g_string_append(text, "\nThe theme was installed but no desktop "
                                  "setting could be changed.\n");
        else
            g_string_append(text, "\nThe desktop was not changed. Use the "
                                  "settings button to choose the theme.\n");

        GtkWidget *dialog = gtk_message_dialog_new(
            GTK_WINDOW(app->window), GTK_DIALOG_MODAL, GTK_MESSAGE_INFO,
            GTK_BUTTONS_NONE, "Theme installed");
        gtk_message_dialog_format_secondary_text(
            GTK_MESSAGE_DIALOG(dialog), "%s", text->str);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "Appearance Settings", 1);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "Window Settings", 2);
        gtk_dialog_add_button(GTK_DIALOG(dialog), "Close", GTK_RESPONSE_CLOSE);
        gint response = gtk_dialog_run(GTK_DIALOG(dialog));
        gtk_widget_destroy(dialog);
        g_string_free(text, TRUE);

        if (response == 1)
            open_settings(GTK_WINDOW(app->window), FALSE);
        else if (response == 2)
            open_settings(GTK_WINDOW(app->window), TRUE);
    } else {
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(app->progress), 0.0);
        const char *message = job->error ? job->error->message
                                         : "The theme could not be installed.";
        GString *text = g_string_new(message);
        if (job->result)
            append_lines(text, "\nNotes:", job->result->warnings);
        show_error(app, "The theme was not installed", text->str);
        g_string_free(text, TRUE);
    }

    job_free(job);
    return G_SOURCE_REMOVE;
}

static gpointer install_thread(gpointer data)
{
    InstallJob *job = data;
    job->ok = theme_install(&job->options, &job->result, &job->error);
    g_idle_add(finish_install, job->app);
    return NULL;
}

static void on_install_clicked(GtkButton *button, gpointer data)
{
    (void)button;
    App *app = data;
    if (app->busy || !app->inspection)
        return;

    GPtrArray *ids = g_ptr_array_new_with_free_func(g_free);
    for (guint i = 0; i < app->toggles->len; i++) {
        ComponentToggle *toggle = g_ptr_array_index(app->toggles, i);
        if (toggle->component->valid &&
            gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(toggle->check)))
            g_ptr_array_add(ids, g_strdup(toggle->component->id));
    }
    if (ids->len == 0) {
        show_error(app, "Nothing selected",
                   "Tick at least one component to install.");
        g_ptr_array_free(ids, TRUE);
        return;
    }

    InstallJob *job = g_new0(InstallJob, 1);
    job->app = app;
    job->ids = ids;
    job->options.archive_path = g_strdup(app->inspection->path);
    job->options.component_ids = ids;
    job->options.replace = gtk_toggle_button_get_active(
        GTK_TOGGLE_BUTTON(app->replace_check));
    job->options.refresh_caches = TRUE;
    job->options.apply = gtk_toggle_button_get_active(
        GTK_TOGGLE_BUTTON(app->apply_check));
    /* Applying is an all-or-nothing user decision from this window; each
     * installed kind is then applied through xfconf. */
    job->options.apply_gtk = job->options.apply;
    job->options.apply_icons = job->options.apply;
    job->options.apply_cursors = job->options.apply;
    job->options.apply_xfwm4 = job->options.apply;

    app->job = job;
    set_busy(app, TRUE);
    gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(app->progress), TRUE);
    gtk_progress_bar_set_text(GTK_PROGRESS_BAR(app->progress),
                              "Installing...");
    gtk_statusbar_push(GTK_STATUSBAR(app->status),
                       gtk_statusbar_get_context_id(GTK_STATUSBAR(app->status),
                                                    "install"),
                       "Installing theme components. Nothing is run from the archive.");
    app->progress_source = g_timeout_add(100, progress_tick, app);
    GThread *thread = g_thread_new("theme-install", install_thread, job);
    g_thread_unref(thread);
}

/* ------------------------------------------------------------------------- */
/* File selection                                                            */

static void on_open_clicked(GtkButton *button, gpointer data)
{
    (void)button;
    App *app = data;
    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        "Open a theme archive", GTK_WINDOW(app->window),
        GTK_FILE_CHOOSER_ACTION_OPEN,
        "Cancel", GTK_RESPONSE_CANCEL,
        "Open", GTK_RESPONSE_ACCEPT, NULL);

    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Theme archives");
    static const char *patterns[] = {
        "*.zip", "*.tar", "*.tar.gz", "*.tgz", "*.tar.bz2", "*.tbz2",
        "*.tbz", "*.tar.xz", "*.txz", NULL
    };
    for (guint i = 0; patterns[i]; i++)
        gtk_file_filter_add_pattern(filter, patterns[i]);
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);

    GtkFileFilter *all = gtk_file_filter_new();
    gtk_file_filter_set_name(all, "All files");
    gtk_file_filter_add_pattern(all, "*");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), all);

    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        char *filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
        if (filename) {
            load_archive(app, filename);
            g_free(filename);
        }
    }
    gtk_widget_destroy(dialog);
}

static void on_drag_data(GtkWidget *widget, GdkDragContext *context, gint x,
                         gint y, GtkSelectionData *selection, guint info,
                         guint time, gpointer data)
{
    (void)widget; (void)x; (void)y; (void)info;
    App *app = data;
    if (app->busy) {
        gtk_drag_finish(context, FALSE, FALSE, time);
        return;
    }
    char **uris = gtk_selection_data_get_uris(selection);
    gboolean accepted = FALSE;
    if (uris && uris[0]) {
        char *path = g_filename_from_uri(uris[0], NULL, NULL);
        if (path) {
            load_archive(app, path);
            g_free(path);
            accepted = TRUE;
        }
    }
    g_strfreev(uris);
    gtk_drag_finish(context, accepted, FALSE, time);
}

/* ------------------------------------------------------------------------- */
/* Window lifecycle                                                          */

static gboolean on_delete_event(GtkWidget *widget, GdkEvent *event,
                                gpointer data)
{
    (void)widget; (void)event;
    App *app = data;
    if (app->busy) {
        show_error(app, "Installation in progress",
                   "Wait for the current theme to finish installing before "
                   "closing the window.");
        return TRUE;
    }
    return FALSE;
}

static void on_destroy(GtkWidget *widget, gpointer data)
{
    (void)widget;
    App *app = data;
    clear_preview(app);
}

static void app_free(App *app)
{
    if (!app)
        return;
    if (app->job) {
        g_atomic_int_set(&app->job->options.cancel, 1);
        job_free(app->job);
        app->job = NULL;
    }
    if (app->progress_source) {
        g_source_remove(app->progress_source);
        app->progress_source = 0;
    }
    g_ptr_array_free(app->toggles, TRUE);
    if (app->inspection)
        theme_inspection_free(app->inspection);
    g_free(app);
}

static void job_free(InstallJob *job)
{
    if (!job)
        return;
    g_free((char *)job->options.archive_path);
    if (job->result)
        theme_install_result_free(job->result);
    g_clear_error(&job->error);
    if (job->ids)
        g_ptr_array_free(job->ids, TRUE);
    g_free(job);
}

static void build_window(App *app)
{
    app->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(app->window), "Copper Theme Installer");
    gtk_window_set_default_size(GTK_WINDOW(app->window), 760, 680);
    gtk_window_set_position(GTK_WINDOW(app->window), GTK_WIN_POS_CENTER);
    g_signal_connect(app->window, "delete-event",
                     G_CALLBACK(on_delete_event), app);
    g_signal_connect(app->window, "destroy", G_CALLBACK(on_destroy), app);

    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(app->window), outer);

    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(header), 12);
    GtkWidget *title = markup_label("<big><b>Theme Installer</b></big>");
    gtk_box_pack_start(GTK_BOX(header), title, TRUE, TRUE, 0);
    app->open_button = gtk_button_new_with_label("Open Archive...");
    g_signal_connect(app->open_button, "clicked",
                     G_CALLBACK(on_open_clicked), app);
    gtk_box_pack_end(GTK_BOX(header), app->open_button, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(outer), header, FALSE, FALSE, 0);

    app->stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(app->stack),
                                  GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_box_pack_start(GTK_BOX(outer), app->stack, TRUE, TRUE, 0);

    /* Review page. */
    GtkWidget *review = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(review), 12);
    gtk_stack_add_named(GTK_STACK(app->stack), review, "review");

    app->archive_label = label_new("", TRUE);
    gtk_box_pack_start(GTK_BOX(review), app->archive_label, FALSE, FALSE, 0);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_box_pack_start(GTK_BOX(review), content, TRUE, TRUE, 0);

    GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_size_request(scroll, 420, 340);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_box_pack_start(GTK_BOX(content), scroll, TRUE, TRUE, 0);

    GtkWidget *scroll_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_container_set_border_width(GTK_CONTAINER(scroll_box), 4);
    gtk_container_add(GTK_CONTAINER(scroll), scroll_box);
    app->components_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_pack_start(GTK_BOX(scroll_box), app->components_box, FALSE, FALSE, 0);

    GtkWidget *side = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_pack_start(GTK_BOX(content), side, FALSE, FALSE, 0);

    app->preview = gtk_image_new();
    gtk_widget_set_size_request(app->preview, 280, 180);
    gtk_box_pack_start(GTK_BOX(side), app->preview, FALSE, FALSE, 0);

    app->replace_check = gtk_check_button_new_with_label(
        "Replace existing themes");
    gtk_box_pack_start(GTK_BOX(side), app->replace_check, FALSE, FALSE, 0);

    app->apply_check = gtk_check_button_new_with_label(
        "Apply to my desktop after installing");
    gtk_widget_set_tooltip_text(app->apply_check,
        "Changes the GTK, icon, cursor and window-manager theme in XFCE. "
        "Leave this off to install files only.");
    gtk_box_pack_start(GTK_BOX(side), app->apply_check, FALSE, FALSE, 0);

    app->warnings_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_box_pack_start(GTK_BOX(side), app->warnings_box, FALSE, FALSE, 0);

    app->install_button = gtk_button_new_with_label("Install Selected");
    gtk_widget_set_size_request(app->install_button, -1, 40);
    g_signal_connect(app->install_button, "clicked",
                     G_CALLBACK(on_install_clicked), app);
    gtk_box_pack_end(GTK_BOX(review), app->install_button, FALSE, FALSE, 0);

    app->progress = gtk_progress_bar_new();
    gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(app->progress), FALSE);
    gtk_box_pack_end(GTK_BOX(review), app->progress, FALSE, FALSE, 0);

    app->status = gtk_statusbar_new();
    gtk_box_pack_end(GTK_BOX(outer), app->status, FALSE, FALSE, 0);

    GtkTargetEntry targets[] = {
        { "text/uri-list", 0, 0 },
        { "text/plain", 0, 1 }
    };
    gtk_drag_dest_set(app->window, GTK_DEST_DEFAULT_ALL, targets, 2,
                      GDK_ACTION_COPY);
    g_signal_connect(app->window, "drag-data-received",
                     G_CALLBACK(on_drag_data), app);

    gtk_widget_show_all(app->window);
    app->busy = FALSE;
}

int gui_run(const char *archive_path)
{
    if (!g_getenv("DISPLAY") && !g_getenv("WAYLAND_DISPLAY")) {
        g_printerr("copper-theme-installer: no graphical display is available; "
                   "use --inspect or --install instead\n");
        return 1;
    }
    if (!gtk_init_check(NULL, NULL)) {
        g_printerr("copper-theme-installer: GTK could not connect to the "
                   "display; use --inspect or --install instead\n");
        return 1;
    }

    App *app = g_new0(App, 1);
    app->toggles = g_ptr_array_new_with_free_func(g_free);
    build_window(app);

    if (archive_path) {
        load_archive(app, archive_path);
    } else {
        populate_review(app);
        gtk_statusbar_push(GTK_STATUSBAR(app->status),
                           gtk_statusbar_get_context_id(
                               GTK_STATUSBAR(app->status), "hint"),
                           "Open a theme archive, or drop one on this window.");
    }

    gtk_main();
    app_free(app);
    return 0;
}
