/* theme.h -- the model shared by the archive inspector, the installer and the
 * GTK front end.
 *
 * Copper's desktop is XFCE on GTK 3, so this is a plain GTK 3 application,
 * not a browser wrapper.  The archive work is deliberately kept out of the
 * GUI: `copper-theme-installer --inspect` and `--install` exercise exactly the
 * same code the window does, which is what makes the security tests possible
 * without an X session.
 */
#ifndef COPPER_THEME_H
#define COPPER_THEME_H

#include <glib.h>

typedef enum {
    THEME_KIND_GTK = 0,
    THEME_KIND_XFWM4,
    THEME_KIND_ICONS,
    THEME_KIND_CURSORS,
    THEME_KIND_FONTS,
    THEME_KIND_COUNT
} ThemeKind;

typedef struct {
    ThemeKind kind;
    char *id;              /* stable: "<kind>:<source-root>" */
    char *name;            /* directory name under the data root */
    char *display_name;    /* Name= from metadata when there is one */
    char *source_root;     /* archive-relative directory, "" for the root */
    char *details;         /* human-readable component detail */
    char *warning;         /* non-fatal note, or NULL */
    gboolean valid;
    gboolean selected;
    gboolean conflict;     /* a theme with this name already exists */
    gboolean has_gtk2;
    gboolean has_gtk3;
    gboolean has_gtk4;
    guint file_count;
    guint64 total_bytes;
} ThemeComponent;

typedef struct {
    char *path;
    char *stem;
    guint64 archive_size;
    guint64 total_uncompressed;
    gboolean valid;
    char *error;
    GPtrArray *components;   /* ThemeComponent* */
    GPtrArray *warnings;     /* char* */
    GPtrArray *unsupported;  /* char* */
    guint skipped_scripts;
    guint safe_symlinks;
} ThemeInspection;

typedef struct {
    char *archive_path;
    GPtrArray *component_ids;  /* char*, empty means every valid component */
    gboolean replace;
    gboolean refresh_caches;
    gboolean apply;
    gboolean apply_gtk;
    gboolean apply_icons;
    gboolean apply_cursors;
    gboolean apply_xfwm4;
    volatile gint progress;    /* 0..100 */
    volatile gint cancel;
} ThemeInstallOptions;

typedef struct {
    GPtrArray *installed;   /* char* descriptions */
    GPtrArray *skipped;     /* char* descriptions */
    GPtrArray *warnings;    /* char* */
    gboolean changed_desktop;
} ThemeInstallResult;

/* theme-archive.c */
ThemeInspection *theme_inspect_archive(const char *path, GError **error);
void theme_inspection_free(ThemeInspection *inspection);
ThemeComponent *theme_component_by_id(ThemeInspection *inspection,
                                      const char *id);
ThemeComponent *theme_component_by_kind_name(ThemeInspection *inspection,
                                             ThemeKind kind,
                                             const char *name);
const char *theme_kind_id(ThemeKind kind);
const char *theme_kind_label(ThemeKind kind);
const char *theme_kind_data_dir(ThemeKind kind);  /* themes/icons/fonts */
char *theme_component_target_path(ThemeKind kind, const char *name);
gboolean theme_extract_preview(const char *archive_path,
                               const char *source_root,
                               const char *dest_path,
                               GError **error);

/* Internal helpers shared with the installer.  They are exported only so the
 * extraction pass can apply exactly the same path rules as inspection. */
char *theme_archive_normalise_path(const char *raw, GError **error);
char *theme_archive_normalise_link(const char *raw, GError **error);
gboolean theme_archive_is_font(const char *path);
gboolean theme_archive_font_magic(const guchar *head, gsize head_len);
gboolean theme_archive_looks_executable(const char *path, const guchar *head,
                                        gsize head_len);
gboolean theme_archive_component_includes(ThemeComponent *component,
                                          const char *relative_path);

/* theme-install.c */
gboolean theme_install(const ThemeInstallOptions *options,
                       ThemeInstallResult **result,
                       GError **error);
void theme_install_result_free(ThemeInstallResult *result);
gboolean theme_apply_component(ThemeKind kind, const char *name,
                               GError **error);
gboolean theme_open_settings(gboolean window_manager, GError **error);
char *theme_path_escape(const char *text);   /* for JSON output */

#endif
