/* theme-install.c -- install inspected theme components into the user's data
 * directories, transactionally and without root.
 *
 * The important properties, in order:
 *
 *   1. Nothing is written into the final location until the whole selected
 *      set has been extracted and validated in a private staging directory
 *      on the same filesystem.
 *   2. Every path is normalised again here; inspection is not trusted as a
 *      security boundary.
 *   3. Regular files are opened with O_EXCL|O_NOFOLLOW.  Symlinks are created
 *      only after all regular files, so no later write can follow one.
 *   4. A replace is a rename of the old directory to a backup, a rename of
 *      the new one into place, and then deletion of the backup.  A failure
 *      restores every directory moved in the same operation.
 */
#include "theme.h"

#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define STAGING_DIR "copper-theme-installer"
#define MAX_INSTALL_FILE (512ULL * 1024ULL * 1024ULL)
#define MAX_INSTALL_TOTAL (8ULL * 1024ULL * 1024ULL * 1024ULL)

typedef struct {
    char *key;
    char *name;
    char *stage_path;
    char *final_path;
    char *backup_path;
    gboolean had_backup;
    gboolean moved;
    GHashTable *dest_seen;   /* dest-relative path -> source archive path */
} InstallTarget;

typedef struct {
    char *path;
    char *target;
} PendingLink;

static void pending_link_free(PendingLink *link)
{
    if (!link)
        return;
    g_free(link->path);
    g_free(link->target);
    g_free(link);
}

static void target_free(InstallTarget *target)
{
    if (!target)
        return;
    g_free(target->key);
    g_free(target->name);
    g_free(target->stage_path);
    g_free(target->final_path);
    g_free(target->backup_path);
    if (target->dest_seen)
        g_hash_table_destroy(target->dest_seen);
    g_free(target);
}

/* Create a directory only if every existing component along the way is a
 * real directory.  This is what keeps a pre-existing symlink in ~/.local or
 * ~/.local/share from redirecting an install somewhere else. */
static gboolean ensure_real_dir(const char *path, GError **error)
{
    char *absolute = g_canonicalize_filename(path, NULL);
    if (!absolute || !g_path_is_absolute(absolute)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "not an absolute path: %s", path);
        g_free(absolute);
        return FALSE;
    }

    gboolean ok = TRUE;
    char *current = g_strdup("/");
    char **parts = g_strsplit(absolute + 1, "/", -1);
    for (guint i = 0; parts[i] && ok; i++) {
        if (!*parts[i])
            continue;
        char *next = g_build_filename(current, parts[i], NULL);
        struct stat st;
        if (lstat(next, &st) == 0) {
            if (S_ISLNK(st.st_mode)) {
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_LOOP,
                            "refusing to install through a symbolic link: %s",
                            next);
                ok = FALSE;
            } else if (!S_ISDIR(st.st_mode)) {
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOTDIR,
                            "not a directory: %s", next);
                ok = FALSE;
            }
        } else if (errno == ENOENT) {
            if (mkdir(next, 0755) != 0 && errno != EEXIST) {
                g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                            "cannot create directory %s: %s", next,
                            g_strerror(errno));
                ok = FALSE;
            } else if (lstat(next, &st) == 0 && S_ISLNK(st.st_mode)) {
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_LOOP,
                            "refusing to install through a symbolic link: %s",
                            next);
                ok = FALSE;
            }
        } else {
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "cannot inspect %s: %s", next, g_strerror(errno));
            ok = FALSE;
        }
        g_free(current);
        current = next;
    }
    g_strfreev(parts);
    g_free(current);
    g_free(absolute);
    return ok;
}

/* Recursive removal that never follows a symlink. */
static void rm_rf(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0)
        return;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        unlink(path);
        return;
    }
    GDir *dir = g_dir_open(path, 0, NULL);
    if (dir) {
        const char *name;
        while ((name = g_dir_read_name(dir)) != NULL) {
            char *child = g_build_filename(path, name, NULL);
            rm_rf(child);
            g_free(child);
        }
        g_dir_close(dir);
    }
    rmdir(path);
}

static char *path_dirname_dup(const char *path)
{
    char *dir = g_path_get_dirname(path);
    if (strcmp(dir, ".") == 0)
        return dir;
    return dir;
}

static char *path_basename_dup(const char *path)
{
    return g_path_get_basename(path);
}

static gboolean path_has_prefix(const char *path, const char *root)
{
    if (!root || !*root)
        return TRUE;
    gsize n = strlen(root);
    return strncmp(path, root, n) == 0 && (path[n] == '\0' || path[n] == '/');
}

static char *relative_to_root(const char *path, const char *root)
{
    if (!root || !*root)
        return g_strdup(path);
    if (!path_has_prefix(path, root))
        return NULL;
    if (path[strlen(root)] == '\0')
        return g_strdup("");
    return g_strdup(path + strlen(root) + 1);
}

static gboolean is_noise_path(const char *path)
{
    return g_str_has_prefix(path, "__MACOSX/") ||
           g_str_has_suffix(path, "/.DS_Store") ||
           strcmp(path, ".DS_Store") == 0;
}

static gboolean is_font_path(const char *path)
{
    return theme_archive_is_font(path);
}

static char *target_key(ThemeKind kind, const char *name)
{
    return g_strdup_printf("%s/%s", theme_kind_data_dir(kind), name);
}

static InstallTarget *target_get(GPtrArray *targets, const char *key)
{
    for (guint i = 0; i < targets->len; i++) {
        InstallTarget *t = g_ptr_array_index(targets, i);
        if (strcmp(t->key, key) == 0)
            return t;
    }
    return NULL;
}

static gboolean target_conflict_ok(InstallTarget *target, gboolean replace,
                                   GError **error)
{
    struct stat st;
    if (lstat(target->final_path, &st) != 0) {
        if (errno == ENOENT)
            return TRUE;
        g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                    "cannot inspect %s: %s", target->final_path,
                    g_strerror(errno));
        return FALSE;
    }
    if (S_ISLNK(st.st_mode)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_LOOP,
                    "refusing to replace a symbolic link: %s",
                    target->final_path);
        return FALSE;
    }
    if (!replace) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_EXIST,
                    "a theme named \"%s\" is already installed at %s; "
                    "choose Replace to overwrite it",
                    target->name, target->final_path);
        return FALSE;
    }
    return TRUE;
}

static gboolean write_all(int fd, const void *data, gsize len, GError **error)
{
    const guchar *p = data;
    gsize off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "write failed: %s", g_strerror(errno));
            return FALSE;
        }
        off += (gsize)n;
    }
    return TRUE;
}

static gboolean read_head(struct archive *a, guchar *head, gsize cap,
                          gsize *head_len, GError **error)
{
    gsize total = 0;
    while (total < cap) {
        la_ssize_t n = archive_read_data(a, head + total, cap - total);
        if (n == 0)
            break;
        if (n < 0) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                        "cannot read archive data: %s", archive_error_string(a));
            return FALSE;
        }
        total += (gsize)n;
    }
    *head_len = total;
    return TRUE;
}

static gboolean make_dest_dirs(const char *dest, GError **error)
{
    char *parent = path_dirname_dup(dest);
    gboolean ok = TRUE;
    if (strcmp(parent, ".") != 0) {
        if (g_mkdir_with_parents(parent, 0700) != 0 && errno != EEXIST) {
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "cannot create %s: %s", parent, g_strerror(errno));
            ok = FALSE;
        }
    }
    g_free(parent);
    return ok;
}

static gboolean commit_targets(GPtrArray *targets, const char *staging_root,
                               GError **error)
{
    for (guint i = 0; i < targets->len; i++) {
        InstallTarget *t = g_ptr_array_index(targets, i);
        char *parent = path_dirname_dup(t->final_path);
        if (!ensure_real_dir(parent, error)) {
            g_free(parent);
            goto rollback;
        }
        g_free(parent);

        struct stat st;
        if (lstat(t->final_path, &st) == 0) {
            if (S_ISLNK(st.st_mode)) {
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_LOOP,
                            "refusing to replace a symbolic link: %s",
                            t->final_path);
                goto rollback;
            }
            t->backup_path = g_strdup_printf("%s/backup-%u", staging_root, i);
            if (g_rename(t->final_path, t->backup_path) != 0) {
                g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                            "cannot move the old theme aside: %s",
                            g_strerror(errno));
                g_clear_pointer(&t->backup_path, g_free);
                goto rollback;
            }
            t->had_backup = TRUE;
        }
        if (g_rename(t->stage_path, t->final_path) != 0) {
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "cannot install %s: %s", t->final_path,
                        g_strerror(errno));
            if (t->had_backup) {
                g_rename(t->backup_path, t->final_path);
                g_clear_pointer(&t->backup_path, g_free);
                t->had_backup = FALSE;
            }
            goto rollback;
        }
        t->moved = TRUE;
    }
    return TRUE;

rollback:
    for (gint i = (gint)targets->len - 1; i >= 0; i--) {
        InstallTarget *t = g_ptr_array_index(targets, (guint)i);
        if (!t->moved)
            continue;
        rm_rf(t->final_path);
        if (t->had_backup && t->backup_path)
            g_rename(t->backup_path, t->final_path);
    }
    return FALSE;
}

static void cleanup_targets(GPtrArray *targets)
{
    for (guint i = 0; i < targets->len; i++) {
        InstallTarget *t = g_ptr_array_index(targets, i);
        if (t->backup_path)
            rm_rf(t->backup_path);
    }
}

static gboolean run_command(const char *const *argv, gboolean optional,
                            GError **error, char **stderr_out)
{
    int status = 0;
    char *out = NULL, *err = NULL;
    GError *spawn_error = NULL;
    gboolean ok = g_spawn_sync(NULL, (char **)argv, NULL,
                               G_SPAWN_SEARCH_PATH, NULL, NULL,
                               &out, &err, &status, &spawn_error);
    if (!ok) {
        if (optional) {
            g_clear_error(&spawn_error);
            g_free(out);
            g_free(err);
            return TRUE;
        }
        g_propagate_error(error, spawn_error);
        g_free(out);
        g_free(err);
        return FALSE;
    }
    if (stderr_out) {
        *stderr_out = err;
    } else {
        g_free(err);
    }
    g_free(out);
    if (status != 0) {
        if (optional)
            return TRUE;
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                    "command failed with exit status %d: %s", status,
                    (stderr_out && *stderr_out) ? *stderr_out : "no details");
        return FALSE;
    }
    return TRUE;
}

static gboolean refresh_icon_cache(const char *theme_dir, GPtrArray *warnings)
{
    if (!g_find_program_in_path("gtk-update-icon-cache"))
        return TRUE;
    const char *argv[] = { "gtk-update-icon-cache", "-f", "-t", theme_dir, NULL };
    GError *error = NULL;
    char *err = NULL;
    gboolean ok = g_spawn_sync(NULL, (char **)argv, NULL, G_SPAWN_SEARCH_PATH,
                               NULL, NULL, NULL, &err, NULL, &error);
    if (!ok) {
        g_ptr_array_add(warnings,
                        g_strdup_printf("could not update the icon cache: %s",
                                        error->message));
        g_clear_error(&error);
        g_free(err);
        return FALSE;
    }
    g_free(err);
    return TRUE;
}

static gboolean refresh_font_cache(GPtrArray *warnings)
{
    if (!g_find_program_in_path("fc-cache"))
        return TRUE;
    const char *argv[] = { "fc-cache", "-f", NULL };
    GError *error = NULL;
    char *err = NULL;
    gboolean ok = g_spawn_sync(NULL, (char **)argv, NULL, G_SPAWN_SEARCH_PATH,
                               NULL, NULL, NULL, &err, NULL, &error);
    if (!ok) {
        g_ptr_array_add(warnings,
                        g_strdup_printf("could not refresh the font cache: %s",
                                        error->message));
        g_clear_error(&error);
        g_free(err);
        return FALSE;
    }
    g_free(err);
    return TRUE;
}

static gboolean component_supported_here(ThemeComponent *c, GError **error)
{
    if (!c->valid) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "\"%s\" cannot be installed: %s", c->display_name,
                    c->warning ? c->warning : "the component is incomplete");
        return FALSE;
    }
    return TRUE;
}

static gboolean install_extract(const char *archive_path,
                                GPtrArray *selected, GPtrArray *targets,
                                ThemeInstallOptions *options,
                                ThemeInstallResult *result,
                                GError **error)
{
    struct archive *a = archive_read_new();
    if (!a) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOMEM,
                    "cannot allocate an archive reader");
        return FALSE;
    }
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_zip(a);
    if (archive_read_open_filename(a, archive_path, 65536) != ARCHIVE_OK) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                    "cannot open archive: %s", archive_error_string(a));
        archive_read_free(a);
        return FALSE;
    }

    GHashTable *seen_paths = g_hash_table_new_full(g_str_hash, g_str_equal,
                                                   g_free, NULL);
    GPtrArray *pending_links = g_ptr_array_new_with_free_func(
        (GDestroyNotify)pending_link_free);
    guint total = 0;
    for (guint i = 0; i < selected->len; i++) {
        ThemeComponent *c = g_ptr_array_index(selected, i);
        total += MAX(c->file_count, 1U);
    }
    guint done = 0;
    guint skipped_fonts = 0;
    guint64 extracted_bytes = 0;
    gboolean ok = FALSE;
    gboolean saw_header = FALSE;

    while (TRUE) {
        if (g_atomic_int_get(&options->cancel)) {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED,
                        "installation cancelled");
            goto out;
        }
        struct archive_entry *ae = NULL;
        int r = archive_read_next_header(a, &ae);
        if (r == ARCHIVE_EOF)
            break;
        if (r != ARCHIVE_OK && r != ARCHIVE_WARN) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                        "malformed archive: %s", archive_error_string(a));
            goto out;
        }
        saw_header = TRUE;
        int fmt = archive_format(a);
        if ((fmt & ARCHIVE_FORMAT_TAR) != ARCHIVE_FORMAT_TAR &&
            (fmt & ARCHIVE_FORMAT_ZIP) != ARCHIVE_FORMAT_ZIP) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                        "unsupported archive format: %s",
                        archive_format_name(a) ? archive_format_name(a) : "unknown");
            goto out;
        }

        const char *raw = archive_entry_pathname_utf8(ae);
        if (!raw)
            raw = archive_entry_pathname(ae);
        GError *path_error = NULL;
        char *path = theme_archive_normalise_path(raw, &path_error);
        if (!path) {
            g_propagate_error(error, path_error);
            goto out;
        }
        if (!*path) {
            g_free(path);
            archive_read_data_skip(a);
            continue;
        }
        if (g_hash_table_contains(seen_paths, path)) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_EXIST,
                        "archive contains duplicate entries: %s", path);
            g_free(path);
            goto out;
        }
        g_hash_table_add(seen_paths, g_strdup(path));

        if (archive_entry_hardlink(ae) != NULL) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                        "archive contains a hard link: %s", path);
            g_free(path);
            goto out;
        }

        mode_t mode = archive_entry_filetype(ae);
        guint64 size = archive_entry_size_is_set(ae)
                           ? (guint64)archive_entry_size(ae) : 0;
        if (size > MAX_INSTALL_FILE) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                        "archive entry %s is too large", path);
            g_free(path);
            goto out;
        }

        if (S_ISDIR(mode)) {
            archive_read_data_skip(a);
            g_free(path);
            continue;
        }
        if (!S_ISREG(mode) && !S_ISLNK(mode) && mode != 0) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                        "archive contains an unsupported entry type: %s", path);
            g_free(path);
            goto out;
        }
        if (S_ISLNK(mode)) {
            const char *t = archive_entry_symlink_utf8(ae);
            if (!t)
                t = archive_entry_symlink(ae);
            GError *link_error = NULL;
            char *target = theme_archive_normalise_link(t, &link_error);
            if (!target) {
                g_propagate_error(error, link_error);
                g_free(path);
                goto out;
            }
            /* The link is materialised after all regular files. */
            for (guint i = 0; i < selected->len; i++) {
                ThemeComponent *c = g_ptr_array_index(selected, i);
                char *rel = relative_to_root(path, c->source_root);
                if (!rel || !*rel ||
                    !theme_archive_component_includes(c, rel) ||
                    is_noise_path(path)) {
                    g_free(rel);
                    continue;
                }
                char *key = target_key(c->kind, c->name);
                InstallTarget *tgt = target_get(targets, key);
                g_free(key);
                if (!tgt) {
                    g_free(rel);
                    continue;
                }
                char *source = g_strdup(path);
                char *old = g_hash_table_lookup(tgt->dest_seen, rel);
                if (old) {
                    if (strcmp(old, source) != 0) {
                        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_EXIST,
                                    "two archive entries map to the same destination: %s",
                                    rel);
                        g_free(source);
                        g_free(rel);
                        g_free(target);
                        g_free(path);
                        goto out;
                    }
                    g_free(source);
                    g_free(rel);
                    continue;
                }
                g_hash_table_insert(tgt->dest_seen, g_strdup(rel), source);
                char *dest = g_build_filename(tgt->stage_path, rel, NULL);
                if (!make_dest_dirs(dest, error)) {
                    g_free(dest);
                    g_free(rel);
                    g_free(target);
                    g_free(path);
                    goto out;
                }
                PendingLink *link = g_new0(PendingLink, 1);
                link->path = dest;
                link->target = g_strdup(target);
                g_ptr_array_add(pending_links, link);
                g_free(rel);
            }
            g_free(target);
            archive_read_data_skip(a);
            g_free(path);
            continue;
        }

        guchar head[8];
        gsize head_len = 0;
        if (!read_head(a, head, sizeof head, &head_len, error)) {
            g_free(path);
            goto out;
        }
        gboolean executable = theme_archive_looks_executable(path, head,
                                                             head_len);

        /* Collect every destination this entry feeds.  A file can belong to
         * both a GTK and an XFWM4 component in the same theme directory, but
         * it is only written once. */
        GPtrArray *destinations = g_ptr_array_new_with_free_func(g_free);
        for (guint i = 0; i < selected->len; i++) {
            ThemeComponent *c = g_ptr_array_index(selected, i);
            char *rel = relative_to_root(path, c->source_root);
            if (!rel || !*rel || is_noise_path(path) ||
                !theme_archive_component_includes(c, rel)) {
                g_free(rel);
                continue;
            }
            if (executable) {
                g_free(rel);
                continue;
            }
            if (c->kind == THEME_KIND_FONTS &&
                (!is_font_path(path) ||
                 !theme_archive_font_magic(head, head_len))) {
                skipped_fonts++;
                g_free(rel);
                continue;
            }
            char *key = target_key(c->kind, c->name);
            InstallTarget *tgt = target_get(targets, key);
            g_free(key);
            if (!tgt) {
                g_free(rel);
                continue;
            }
            char *dest_rel = NULL;
            if (c->kind == THEME_KIND_FONTS) {
                char *base = path_basename_dup(path);
                dest_rel = base;
            } else {
                dest_rel = g_strdup(rel);
            }
            g_free(rel);
            if (!dest_rel || !*dest_rel) {
                g_free(dest_rel);
                continue;
            }
            char *source = g_strdup(path);
            char *old = g_hash_table_lookup(tgt->dest_seen, dest_rel);
            if (old) {
                if (strcmp(old, source) != 0) {
                    g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_EXIST,
                                "two archive entries map to the same destination: %s",
                                dest_rel);
                    g_free(source);
                    g_free(dest_rel);
                    g_ptr_array_free(destinations, TRUE);
                    g_free(path);
                    goto out;
                }
                g_free(source);
                g_free(dest_rel);
                continue;
            }
            g_hash_table_insert(tgt->dest_seen, g_strdup(dest_rel), source);
            char *dest = g_build_filename(tgt->stage_path, dest_rel, NULL);
            g_free(dest_rel);
            if (!make_dest_dirs(dest, error)) {
                g_free(dest);
                g_ptr_array_free(destinations, TRUE);
                g_free(path);
                goto out;
            }
            g_ptr_array_add(destinations, dest);
        }

        if (destinations->len == 0) {
            g_ptr_array_free(destinations, TRUE);
            archive_read_data_skip(a);
            g_free(path);
            done++;
            g_atomic_int_set(&options->progress,
                             total ? (gint)((done * 100) / total) : 100);
            continue;
        }

        int *fds = g_new0(int, destinations->len);
        for (guint i = 0; i < destinations->len; i++) {
            const char *dest = g_ptr_array_index(destinations, i);
            fds[i] = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                                   O_CLOEXEC, 0600);
            if (fds[i] < 0) {
                g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                            "cannot create %s: %s", dest, g_strerror(errno));
                for (guint j = 0; j < i; j++)
                    close(fds[j]);
                g_free(fds);
                g_ptr_array_free(destinations, TRUE);
                g_free(path);
                goto out;
            }
        }
        gboolean write_ok = TRUE;
        /* The head bytes were already consumed from the archive. */
        for (guint i = 0; i < destinations->len; i++) {
            if (!write_all(fds[i], head, head_len, error)) {
                write_ok = FALSE;
                break;
            }
        }
        if (write_ok) {
            guchar buf[32768];
            while (TRUE) {
                la_ssize_t n = archive_read_data(a, buf, sizeof buf);
                if (n == 0)
                    break;
                if (n < 0) {
                    g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                                "cannot read %s: %s", path,
                                archive_error_string(a));
                    write_ok = FALSE;
                    break;
                }
                if (extracted_bytes + (guint64)n > MAX_INSTALL_TOTAL) {
                    g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                                "archive expands beyond the installation limit");
                    write_ok = FALSE;
                    break;
                }
                extracted_bytes += (guint64)n;
                for (guint i = 0; i < destinations->len && write_ok; i++) {
                    if (!write_all(fds[i], buf, (gsize)n, error))
                        write_ok = FALSE;
                }
                if (!write_ok)
                    break;
            }
        }
        for (guint i = 0; i < destinations->len; i++) {
            if (fds[i] >= 0) {
                fchmod(fds[i], 0644);
                close(fds[i]);
            }
        }
        g_free(fds);
        if (!write_ok) {
            g_ptr_array_free(destinations, TRUE);
            g_free(path);
            goto out;
        }
        g_ptr_array_free(destinations, TRUE);
        g_free(path);
        done++;
        g_atomic_int_set(&options->progress,
                         total ? (gint)((done * 100) / total) : 100);
    }

    if (!saw_header) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "archive is empty");
        goto out;
    }

    /* Symlinks last.  Their targets are relative and contain no `..`, so
     * creating them cannot redirect any write that has already happened. */
    for (guint i = 0; i < pending_links->len; i++) {
        PendingLink *link = g_ptr_array_index(pending_links, i);
        if (symlink(link->target, link->path) != 0) {
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "cannot create symlink %s: %s", link->path,
                        g_strerror(errno));
            goto out;
        }
    }

    if (skipped_fonts > 0)
        g_ptr_array_add(result->skipped,
                        g_strdup_printf("%u file%s with a font extension did not contain valid font data",
                                        skipped_fonts,
                                        skipped_fonts == 1 ? "" : "s"));
    g_atomic_int_set(&options->progress, 100);
    ok = TRUE;

out:
    g_ptr_array_free(pending_links, TRUE);
    g_hash_table_destroy(seen_paths);
    archive_read_free(a);
    return ok;
}

gboolean theme_install(const ThemeInstallOptions *options,
                       ThemeInstallResult **result_out,
                       GError **error)
{
    g_return_val_if_fail(options != NULL, FALSE);
    g_return_val_if_fail(result_out != NULL, FALSE);

    ThemeInstallResult *result = g_new0(ThemeInstallResult, 1);
    result->installed = g_ptr_array_new_with_free_func(g_free);
    result->skipped = g_ptr_array_new_with_free_func(g_free);
    result->warnings = g_ptr_array_new_with_free_func(g_free);
    *result_out = result;

    if (!options->archive_path)
        return FALSE;
    if (g_getenv("SUDO_USER") && geteuid() == 0) {
        g_ptr_array_add(result->warnings,
                        g_strdup("Theme Installer is running as root. Run it as your normal user so the theme lands in your own home directory."));
    }

    GError *inspect_error = NULL;
    ThemeInspection *inspection = theme_inspect_archive(options->archive_path,
                                                        &inspect_error);
    if (!inspection) {
        g_propagate_error(error, inspect_error);
        return FALSE;
    }
    if (!inspection->valid && inspection->components->len == 0) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL, "%s",
                    inspection->error ? inspection->error
                                      : "the archive is not a usable theme");
        theme_inspection_free(inspection);
        return FALSE;
    }

    GPtrArray *selected = g_ptr_array_new();
    for (guint i = 0; i < inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(inspection->components, i);
        gboolean wanted = options->component_ids->len == 0;
        for (guint j = 0; j < options->component_ids->len; j++) {
            const char *id = g_ptr_array_index(options->component_ids, j);
            if (strcmp(id, c->id) == 0) {
                wanted = TRUE;
                break;
            }
        }
        if (!wanted)
            continue;
        if (!c->valid) {
            if (options->component_ids->len > 0) {
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                            "%s cannot be installed: %s", c->display_name,
                            c->warning ? c->warning : "incomplete component");
                g_ptr_array_free(selected, TRUE);
                theme_inspection_free(inspection);
                return FALSE;
            }
            g_ptr_array_add(result->skipped,
                            g_strdup_printf("%s \"%s\" is incomplete and was skipped",
                                            theme_kind_label(c->kind),
                                            c->display_name));
            continue;
        }
        g_ptr_array_add(selected, c);
    }
    if (selected->len == 0) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "no installable theme components were selected");
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }

    const char *data_dir = g_get_user_data_dir();
    if (!data_dir || !g_path_is_absolute(data_dir)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "XDG data directory is not an absolute path");
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }
    if (!ensure_real_dir(data_dir, error)) {
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }

    char *staging_base = g_build_filename(data_dir, STAGING_DIR, NULL);
    if (!ensure_real_dir(staging_base, error)) {
        g_free(staging_base);
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }

    char *lock_path = g_build_filename(staging_base, "lock", NULL);
    int lock_fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                       0600);
    g_free(lock_path);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX) != 0) {
        g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                    "cannot lock the theme staging directory: %s",
                    g_strerror(errno));
        if (lock_fd >= 0)
            close(lock_fd);
        g_free(staging_base);
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }

    char *staging_root = g_build_filename(staging_base, "tmp-XXXXXX", NULL);
    if (!g_mkdtemp(staging_root)) {
        g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                    "cannot create a staging directory: %s", g_strerror(errno));
        g_free(staging_root);
        close(lock_fd);
        flock(lock_fd, LOCK_UN);
        g_free(staging_base);
        g_ptr_array_free(selected, TRUE);
        theme_inspection_free(inspection);
        return FALSE;
    }

    GPtrArray *targets = g_ptr_array_new_with_free_func(
        (GDestroyNotify)target_free);
    gboolean ok = TRUE;
    GError *install_error = NULL;

    for (guint i = 0; i < selected->len && ok; i++) {
        ThemeComponent *c = g_ptr_array_index(selected, i);
        if (!component_supported_here(c, &install_error)) {
            ok = FALSE;
            break;
        }
        char *key = target_key(c->kind, c->name);
        InstallTarget *target = target_get(targets, key);
        if (!target) {
            target = g_new0(InstallTarget, 1);
            target->key = g_strdup(key);
            target->name = g_strdup(c->name);
            target->dest_seen = g_hash_table_new_full(g_str_hash, g_str_equal,
                                                      g_free, g_free);
            char *sub = g_strdup_printf("%s/%s", theme_kind_data_dir(c->kind),
                                        c->name);
            target->stage_path = g_build_filename(staging_root, sub, NULL);
            g_free(sub);
            target->final_path = theme_component_target_path(c->kind, c->name);
            if (!target_conflict_ok(target, options->replace, &install_error)) {
                target_free(target);
                g_free(key);
                ok = FALSE;
                break;
            }
            if (g_mkdir_with_parents(target->stage_path, 0700) != 0 &&
                errno != EEXIST) {
                g_set_error(&install_error, G_FILE_ERROR,
                            g_file_error_from_errno(errno),
                            "cannot create staging directory %s: %s",
                            target->stage_path, g_strerror(errno));
                target_free(target);
                g_free(key);
                ok = FALSE;
                break;
            }
            g_ptr_array_add(targets, target);
        }
        g_free(key);
    }

    if (ok && options->component_ids->len > 0) {
        for (guint j = 0; j < options->component_ids->len; j++) {
            const char *id = g_ptr_array_index(options->component_ids, j);
            if (!theme_component_by_id(inspection, id)) {
                g_set_error(&install_error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                            "the archive changed and no longer contains the selected component: %s",
                            id);
                ok = FALSE;
                break;
            }
        }
    }

    if (ok) {
        g_atomic_int_set(&options->progress, 0);
        ok = install_extract(options->archive_path, selected, targets,
                             (ThemeInstallOptions *)options,
                             result, &install_error);
    }

    if (ok && targets->len > 0) {
        ok = commit_targets(targets, staging_root, &install_error);
    }

    if (ok) {
        for (guint i = 0; i < targets->len; i++) {
            InstallTarget *t = g_ptr_array_index(targets, i);
            g_ptr_array_add(result->installed,
                            g_strdup_printf("%s in %s", t->name, t->final_path));
            if (options->refresh_caches) {
                if (t->key[0] == 'i' && g_str_has_prefix(t->key, "icons/"))
                    refresh_icon_cache(t->final_path, result->warnings);
                if (g_str_has_prefix(t->key, "fonts/"))
                    refresh_font_cache(result->warnings);
            }
        }
        for (guint i = 0; i < inspection->unsupported->len; i++)
            g_ptr_array_add(result->skipped,
                            g_strdup_printf("%s (not supported)",
                                            (char *)g_ptr_array_index(inspection->unsupported, i)));
        for (guint i = 0; i < inspection->warnings->len; i++)
            g_ptr_array_add(result->warnings,
                            g_strdup((char *)g_ptr_array_index(inspection->warnings, i)));
    } else {
        g_propagate_error(error, install_error);
    }

    if (!ok) {
        /* Remove anything partially written into the staging tree.  The
         * final directories were either never touched or rolled back by
         * commit_targets(). */
        rm_rf(staging_root);
    } else {
        cleanup_targets(targets);
        rm_rf(staging_root);
    }

    if (options->apply && ok) {
        for (guint i = 0; i < targets->len; i++) {
            InstallTarget *t = g_ptr_array_index(targets, i);
            gboolean apply = FALSE;
            if (g_str_has_prefix(t->key, "themes/")) {
                for (guint j = 0; j < selected->len; j++) {
                    ThemeComponent *c = g_ptr_array_index(selected, j);
                    if (strcmp(c->name, t->name) == 0) {
                        if (c->kind == THEME_KIND_GTK && options->apply_gtk)
                            apply = TRUE;
                        if (c->kind == THEME_KIND_XFWM4 && options->apply_xfwm4)
                            apply = TRUE;
                    }
                }
            } else if (g_str_has_prefix(t->key, "icons/")) {
                for (guint j = 0; j < selected->len; j++) {
                    ThemeComponent *c = g_ptr_array_index(selected, j);
                    if (strcmp(c->name, t->name) == 0) {
                        if (c->kind == THEME_KIND_ICONS && options->apply_icons)
                            apply = TRUE;
                        if (c->kind == THEME_KIND_CURSORS && options->apply_cursors)
                            apply = TRUE;
                    }
                }
            }
            if (!apply)
                continue;
            for (guint j = 0; j < selected->len; j++) {
                ThemeComponent *c = g_ptr_array_index(selected, j);
                if (strcmp(c->name, t->name) != 0)
                    continue;
                if ((c->kind == THEME_KIND_GTK && !options->apply_gtk) ||
                    (c->kind == THEME_KIND_XFWM4 && !options->apply_xfwm4) ||
                    (c->kind == THEME_KIND_ICONS && !options->apply_icons) ||
                    (c->kind == THEME_KIND_CURSORS && !options->apply_cursors))
                    continue;
                GError *apply_error = NULL;
                if (!theme_apply_component(c->kind, c->name, &apply_error)) {
                    g_ptr_array_add(result->warnings,
                                    g_strdup_printf("the theme was installed but could not be applied: %s",
                                                    apply_error->message));
                    g_clear_error(&apply_error);
                } else {
                    result->changed_desktop = TRUE;
                }
            }
        }
    }

    g_ptr_array_free(targets, TRUE);
    g_ptr_array_free(selected, TRUE);
    theme_inspection_free(inspection);
    rm_rf(staging_root);
    g_free(staging_root);
    close(lock_fd);
    g_free(staging_base);
    return ok;
}

void theme_install_result_free(ThemeInstallResult *result)
{
    if (!result)
        return;
    if (result->installed) {
        g_ptr_array_set_free_func(result->installed, g_free);
        g_ptr_array_free(result->installed, TRUE);
    }
    if (result->skipped) {
        g_ptr_array_set_free_func(result->skipped, g_free);
        g_ptr_array_free(result->skipped, TRUE);
    }
    if (result->warnings) {
        g_ptr_array_set_free_func(result->warnings, g_free);
        g_ptr_array_free(result->warnings, TRUE);
    }
    g_free(result);
}

gboolean theme_apply_component(ThemeKind kind, const char *name, GError **error)
{
    if (!name || !*name) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "no theme name to apply");
        return FALSE;
    }
    if (!g_find_program_in_path("xfconf-query")) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "xfconf-query is not installed, so the theme cannot be "
                    "applied automatically; open XFCE Appearance settings");
        return FALSE;
    }
    if (!g_getenv("DBUS_SESSION_BUS_ADDRESS") && !g_getenv("DISPLAY") &&
        !g_getenv("WAYLAND_DISPLAY")) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                    "no XFCE desktop session was detected; open the settings "
                    "panel and choose the theme there");
        return FALSE;
    }

    const char *channel = NULL, *property = NULL;
    switch (kind) {
    case THEME_KIND_GTK:
        channel = "xsettings";
        property = "/Net/ThemeName";
        break;
    case THEME_KIND_XFWM4:
        channel = "xfwm4";
        property = "/general/theme";
        break;
    case THEME_KIND_ICONS:
        channel = "xsettings";
        property = "/Net/IconThemeName";
        break;
    case THEME_KIND_CURSORS:
        channel = "xsettings";
        property = "/Net/CursorThemeName";
        break;
    default:
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "fonts and unknown components are not applied through xfconf");
        return FALSE;
    }

    const char *argv[] = {
        "xfconf-query", "-c", channel, "-p", property, "-n",
        "-t", "string", "-s", name, NULL
    };
    char *err = NULL;
    if (!run_command(argv, FALSE, error, &err)) {
        if (err && error && *error) {
            char *msg = g_strdup_printf("%s (%s)", (*error)->message,
                                        g_strstrip(err));
            g_clear_error(error);
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_FAILED, "%s", msg);
            g_free(msg);
        }
        g_free(err);
        return FALSE;
    }
    g_free(err);
    return TRUE;
}

gboolean theme_open_settings(gboolean window_manager, GError **error)
{
    const char *program = window_manager ? "xfwm4-settings"
                                         : "xfce4-appearance-settings";
    if (!g_find_program_in_path(program))
        program = "xfce4-settings-manager";
    if (!g_find_program_in_path(program)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "the XFCE settings application is not installed");
        return FALSE;
    }
    const char *argv[] = { program, NULL };
    return g_spawn_async(NULL, (char **)argv, NULL, G_SPAWN_SEARCH_PATH,
                         NULL, NULL, NULL, error);
}
