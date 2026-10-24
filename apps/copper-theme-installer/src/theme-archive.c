/* theme-archive.c -- inspect a downloaded theme archive and identify the
 * components Copper can install.
 *
 * Everything here treats the archive as hostile input.  The rules are simple
 * and deliberately conservative:
 *
 *   - absolute paths, `..`, backslashes and control characters are fatal;
 *   - hard links, device nodes, FIFOs and sockets are fatal;
 *   - symlinks are accepted only when their target is relative and contains
 *     no `..` segment, and they are created after every regular file so no
 *     write can ever follow one;
 *   - duplicate destination names are fatal;
 *   - only ZIP and TAR (any compression libarchive was built with) are
 *     accepted.  7z, RAR and other formats are refused instead of silently
 *     relying on an optional backend.
 *
 * The same normalisation is used again during extraction.  Inspection is not
 * a security boundary: the installer re-checks every entry.
 */
#include "theme.h"

#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_ARCHIVE_BYTES      (1024ULL * 1024ULL * 1024ULL)
#define MAX_EXTRACTED_BYTES    (8ULL * 1024ULL * 1024ULL * 1024ULL)
#define MAX_FILE_BYTES         (512ULL * 1024ULL * 1024ULL)
#define MAX_ENTRIES            250000U
#define MAX_PATH_BYTES         4096U
#define MAX_METADATA_BYTES     (256U * 1024U)
#define MAX_COMPONENTS         128U
#define MAX_PREVIEW_BYTES      (8U * 1024U * 1024U)

typedef struct {
    char *path;          /* normalised, '/'-separated, no leading slash */
    char *link_target;   /* normalised symlink target, or NULL */
    gboolean is_dir;
    gboolean is_regular;
    gboolean is_symlink;
    guint64 size;
    guchar head[8];
    gsize head_len;
    char *metadata;      /* full content for small index.theme/themerc files */
    gsize metadata_len;
} ArchiveEntry;

static void archive_rec_free(ArchiveEntry *entry)
{
    if (!entry)
        return;
    g_free(entry->path);
    g_free(entry->link_target);
    g_free(entry->metadata);
    g_free(entry);
}

static void ptr_array_free_strings(GPtrArray *array)
{
    if (!array)
        return;
    g_ptr_array_set_free_func(array, g_free);
    g_ptr_array_free(array, TRUE);
}

static gboolean is_metadata_name(const char *path)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "index.theme") == 0 ||
           strcmp(base, "cursor.theme") == 0 ||
           strcmp(base, "themerc") == 0 ||
           strcmp(base, "gtk.css") == 0 ||
           strcmp(base, "gtkrc") == 0 ||
           strcmp(base, "index.desktop") == 0;
}

static gboolean has_control_chars(const char *text)
{
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p < 0x20 || *p == 0x7f)
            return TRUE;
    }
    return FALSE;
}

/* Paths in archives are `/`-separated.  A backslash is not a separator on
 * Linux, but accepting one would make a path look different to a reader that
 * does treat it as one, so it is refused rather than interpreted. */
char *theme_archive_normalise_path(const char *raw, GError **error)
{
    if (!raw || !*raw) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive contains an empty file name");
        return NULL;
    }
    if (strlen(raw) > MAX_PATH_BYTES) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NAMETOOLONG,
                    "archive path is longer than %u bytes", MAX_PATH_BYTES);
        return NULL;
    }
    if (!g_utf8_validate(raw, -1, NULL)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive contains a path that is not valid UTF-8");
        return NULL;
    }
    if (raw[0] == '/') {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                    "archive contains an absolute path: %s", raw);
        return NULL;
    }
    if (strchr(raw, '\\')) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive path contains a backslash: %s", raw);
        return NULL;
    }
    if (has_control_chars(raw)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive path contains a control character");
        return NULL;
    }

    char **parts = g_strsplit(raw, "/", -1);
    GString *out = g_string_new(NULL);
    gboolean bad = FALSE;

    for (guint i = 0; parts[i]; i++) {
        const char *part = parts[i];
        if (!*part || strcmp(part, ".") == 0)
            continue;
        if (strcmp(part, "..") == 0) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                        "archive path contains '..': %s", raw);
            bad = TRUE;
            break;
        }
        /* A Windows drive prefix in a POSIX archive is either a mistake or a
         * deliberate attempt to look like an absolute path.  Refuse it. */
        if (i == 0 && part[0] && part[1] == ':' &&
            g_ascii_isalpha(part[0])) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                        "archive contains a drive-qualified path: %s", raw);
            bad = TRUE;
            break;
        }
        if (out->len)
            g_string_append_c(out, '/');
        g_string_append(out, part);
    }
    g_strfreev(parts);

    if (bad) {
        g_string_free(out, TRUE);
        return NULL;
    }
    if (!out->len) {
        /* "." or "./" is how many tar writers spell the archive root.  It is
         * not a file to install; callers skip an empty result. */
        g_string_free(out, TRUE);
        return g_strdup("");
    }
    return g_string_free(out, FALSE);
}

char *theme_archive_normalise_link(const char *target, GError **error)
{
    if (!target || !*target) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive contains a symlink with an empty target");
        return NULL;
    }
    if (target[0] == '/' || strchr(target, '\\') || has_control_chars(target)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                    "archive contains an unsafe symlink target: %s", target);
        return NULL;
    }
    if (strlen(target) > MAX_PATH_BYTES) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NAMETOOLONG,
                    "archive symlink target is longer than %u bytes",
                    MAX_PATH_BYTES);
        return NULL;
    }
    if (!g_utf8_validate(target, -1, NULL)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive contains a symlink target that is not valid UTF-8");
        return NULL;
    }
    char **parts = g_strsplit(target, "/", -1);
    GString *out = g_string_new(NULL);
    for (guint i = 0; parts[i]; i++) {
        if (!*parts[i] || strcmp(parts[i], ".") == 0)
            continue;
        if (strcmp(parts[i], "..") == 0) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                        "archive symlink target contains '..': %s", target);
            g_strfreev(parts);
            g_string_free(out, TRUE);
            return NULL;
        }
        if (out->len)
            g_string_append_c(out, '/');
        g_string_append(out, parts[i]);
    }
    g_strfreev(parts);
    if (!out->len) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                    "archive contains an empty symlink target");
        g_string_free(out, TRUE);
        return NULL;
    }
    return g_string_free(out, FALSE);
}

static gboolean read_entry_bytes(struct archive *a, ArchiveEntry *entry,
                                 gboolean want_metadata, GError **error)
{
    GByteArray *meta = want_metadata ? g_byte_array_new() : NULL;
    guchar buffer[16384];
    gsize total = 0;
    gboolean meta_complete = TRUE;

    /* Non-metadata files only need enough bytes to recognise an ELF shebang
     * or a font magic number.  Skipping the rest avoids decompressing a whole
     * icon set just to list it. */
    gsize read_limit = want_metadata ? G_MAXSIZE : sizeof entry->head;

    while (TRUE) {
        gsize chunk = sizeof buffer;
        if (!want_metadata && total + chunk > read_limit)
            chunk = read_limit - MIN(total, read_limit);
        if (chunk == 0) {
            archive_read_data_skip(a);
            break;
        }
        la_ssize_t n = archive_read_data(a, buffer, chunk);
        if (n == 0)
            break;
        if (n < 0) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                        "cannot read archive entry %s: %s", entry->path,
                        archive_error_string(a));
            if (meta)
                g_byte_array_free(meta, TRUE);
            return FALSE;
        }

        if (entry->head_len < sizeof entry->head) {
            gsize take = MIN((gsize)n, sizeof entry->head - entry->head_len);
            memcpy(entry->head + entry->head_len, buffer, take);
            entry->head_len += take;
        }

        if (meta) {
            if (total + (gsize)n > MAX_METADATA_BYTES) {
                /* Keep the head, not a truncated config file.  The component
                 * will be reported as malformed instead of being guessed at. */
                meta_complete = FALSE;
                g_byte_array_set_size(meta, 0);
            } else {
                g_byte_array_append(meta, buffer, (guint)n);
            }
        }
        total += (gsize)n;
        if (total > MAX_FILE_BYTES) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                        "archive entry %s is larger than the %llu MiB limit",
                        entry->path,
                        (unsigned long long)(MAX_FILE_BYTES / (1024ULL * 1024ULL)));
            if (meta)
                g_byte_array_free(meta, TRUE);
            return FALSE;
        }
    }

    if (meta && meta_complete && meta->len) {
        entry->metadata = g_malloc(meta->len + 1);
        memcpy(entry->metadata, meta->data, meta->len);
        entry->metadata[meta->len] = '\0';
        entry->metadata_len = meta->len;
    }
    if (meta)
        g_byte_array_free(meta, TRUE);
    return TRUE;
}

static gboolean archive_supports_format(struct archive *a, GError **error)
{
    int fmt = archive_format(a);
    if ((fmt & ARCHIVE_FORMAT_TAR) == ARCHIVE_FORMAT_TAR ||
        (fmt & ARCHIVE_FORMAT_ZIP) == ARCHIVE_FORMAT_ZIP)
        return TRUE;
    const char *name = archive_format_name(a);
    g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                "unsupported archive format%s%s; use ZIP, TAR, TAR.GZ, "
                "TAR.BZ2 or TAR.XZ",
                name ? ": " : "", name ? name : "");
    return FALSE;
}

static gboolean read_archive_entries(const char *path, GPtrArray *entries,
                                     guint64 *archive_size,
                                     guint64 *total_uncompressed,
                                     guint *safe_symlinks,
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

    if (archive_read_open_filename(a, path, 65536) != ARCHIVE_OK) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                    "cannot open archive: %s", archive_error_string(a));
        archive_read_free(a);
        return FALSE;
    }

    GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal,
                                             g_free, NULL);
    gboolean ok = FALSE;
    guint count = 0;
    guint64 bytes = 0;
    guint links = 0;
    gboolean saw_header = FALSE;

    while (TRUE) {
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
        if (!archive_supports_format(a, error))
            goto out;

        count++;
        if (count > MAX_ENTRIES) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                        "archive has more than %u entries", MAX_ENTRIES);
            goto out;
        }

        const char *raw = archive_entry_pathname_utf8(ae);
        if (!raw)
            raw = archive_entry_pathname(ae);
        char *normalised = theme_archive_normalise_path(raw, error);
        if (!normalised)
            goto out;
        if (!*normalised) {
            /* The archive-root marker ("." / "./") is not a file. */
            g_free(normalised);
            archive_read_data_skip(a);
            continue;
        }

        if (g_hash_table_contains(seen, normalised)) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_EXIST,
                        "archive contains duplicate entries: %s", normalised);
            g_free(normalised);
            goto out;
        }
        g_hash_table_add(seen, g_strdup(normalised));

        ArchiveEntry *entry = g_new0(ArchiveEntry, 1);
        entry->path = normalised;

        mode_t mode = archive_entry_filetype(ae);
        guint64 size = archive_entry_size_is_set(ae)
                           ? (guint64)archive_entry_size(ae) : 0;
        if (size > MAX_FILE_BYTES) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                        "archive entry %s is larger than the %llu MiB limit",
                        entry->path,
                        (unsigned long long)(MAX_FILE_BYTES / (1024ULL * 1024ULL)));
            archive_rec_free(entry);
            goto out;
        }
        entry->size = size;
        if (bytes > MAX_EXTRACTED_BYTES - MIN(size, MAX_EXTRACTED_BYTES)) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                        "archive expands to more than %llu GiB",
                        (unsigned long long)(MAX_EXTRACTED_BYTES /
                                             (1024ULL * 1024ULL * 1024ULL)));
            archive_rec_free(entry);
            goto out;
        }
        bytes += size;

        if (archive_entry_hardlink(ae) != NULL) {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                        "archive contains a hard link: %s", entry->path);
            archive_rec_free(entry);
            goto out;
        }

        if (mode == 0 || S_ISREG(mode)) {
            entry->is_regular = TRUE;
            gboolean want_meta = is_metadata_name(entry->path);
            if (!read_entry_bytes(a, entry, want_meta, error)) {
                archive_rec_free(entry);
                goto out;
            }
        } else if (S_ISDIR(mode)) {
            entry->is_dir = TRUE;
            archive_read_data_skip(a);
        } else if (S_ISLNK(mode)) {
            entry->is_symlink = TRUE;
            const char *target = archive_entry_symlink_utf8(ae);
            if (!target)
                target = archive_entry_symlink(ae);
            entry->link_target = theme_archive_normalise_link(target, error);
            if (!entry->link_target) {
                archive_rec_free(entry);
                goto out;
            }
            links++;
            archive_read_data_skip(a);
        } else {
            g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                        "archive contains an unsupported entry type: %s",
                        entry->path);
            archive_rec_free(entry);
            goto out;
        }

        g_ptr_array_add(entries, entry);
    }

    if (!saw_header) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "archive is empty or contains no readable entries");
        goto out;
    }

    if (archive_size) {
        GStatBuf st;
        if (g_stat(path, &st) == 0)
            *archive_size = (guint64)st.st_size;
    }
    if (total_uncompressed)
        *total_uncompressed = bytes;
    if (safe_symlinks)
        *safe_symlinks = links;
    ok = TRUE;

out:
    g_hash_table_destroy(seen);
    archive_read_free(a);
    return ok;
}

static ArchiveEntry *entry_by_path(GHashTable *by_path, const char *path)
{
    return path ? g_hash_table_lookup(by_path, path) : NULL;
}

static char *path_dirname(const char *path)
{
    char *dir = g_path_get_dirname(path);
    if (strcmp(dir, ".") == 0 || strcmp(dir, "/") == 0) {
        g_free(dir);
        return g_strdup("");
    }
    return dir;
}

static char *path_basename(const char *path)
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

static char *path_relative_to(const char *path, const char *root)
{
    if (!root || !*root)
        return g_strdup(path);
    if (!path_has_prefix(path, root))
        return NULL;
    if (path[strlen(root)] == '\0')
        return g_strdup("");
    return g_strdup(path + strlen(root) + 1);
}

static gboolean rel_starts(const char *rel, const char *prefix)
{
    return strncmp(rel, prefix, strlen(prefix)) == 0;
}

gboolean theme_archive_is_font(const char *path)
{
    static const char *exts[] = {
        ".ttf", ".otf", ".ttc", ".otc", ".pfa", ".pfb", ".pcf", ".pcf.gz",
        NULL
    };
    char *lower = g_ascii_strdown(path, -1);
    gboolean yes = FALSE;
    for (guint i = 0; exts[i]; i++) {
        if (g_str_has_suffix(lower, exts[i])) {
            yes = TRUE;
            break;
        }
    }
    g_free(lower);
    return yes;
}

gboolean theme_archive_font_magic(const guchar *h, gsize n)
{
    if (!h || n < 4)
        return FALSE;
    /* TrueType / OpenType / collections. */
    if (n >= 4 && ((h[0] == 0x00 && h[1] == 0x01 && h[2] == 0x00 && h[3] == 0x00) ||
                   (memcmp(h, "OTTO", 4) == 0) ||
                   (memcmp(h, "true", 4) == 0) ||
                   (memcmp(h, "ttcf", 4) == 0)))
        return TRUE;
    /* Type 1. */
    if (n >= 4 && h[0] == 0x80 && h[1] == 0x01)
        return TRUE;
    if (n >= 10 && memcmp(h, "%!PS", 4) == 0)
        return TRUE;
    /* PCF, little and big endian spellings. */
    if (n >= 4 && ((h[0] == 0x01 && h[1] == 'f' && h[2] == 'c' && h[3] == 'p') ||
                   (h[0] == 'p' && h[1] == 'c' && h[2] == 'f')))
        return TRUE;
    /* A gzipped PCF is decompressed by fontconfig; its gzip header is enough. */
    if (n >= 2 && h[0] == 0x1f && h[1] == 0x8b)
        return TRUE;
    return FALSE;
}

gboolean theme_archive_looks_executable(const char *path, const guchar *head,
                                        gsize head_len)
{
    if (!path)
        return FALSE;
    char *lower = g_ascii_strdown(path, -1);
    static const char *exts[] = {
        ".sh", ".bash", ".zsh", ".py", ".pl", ".rb", ".lua", ".exe",
        ".bat", ".cmd", ".ps1", ".jar", ".appimage", NULL
    };
    gboolean yes = FALSE;
    for (guint i = 0; exts[i]; i++) {
        if (g_str_has_suffix(lower, exts[i])) {
            yes = TRUE;
            break;
        }
    }
    g_free(lower);
    if (yes)
        return TRUE;
    if (head && head_len >= 2 && head[0] == '#' && head[1] == '!')
        return TRUE;
    if (head && head_len >= 4 && memcmp(head, "\x7f" "ELF", 4) == 0)
        return TRUE;
    return FALSE;
}

static char *sanitise_name(const char *input)
{
    if (!input)
        return NULL;
    GString *out = g_string_new(NULL);
    for (const char *p = input; *p && out->len < 120; p++) {
        unsigned char c = (unsigned char)*p;
        if (g_ascii_isalnum(c) || c == '-' || c == '_' || c == '.' ||
            c == ' ' || c == '+' || c == '(' || c == ')' || c == '[' ||
            c == ']') {
            g_string_append_c(out, (char)c);
        } else {
            g_string_append_c(out, '_');
        }
    }
    /* No hidden directories, no "." or "..", and trim spaces. */
    while (out->len && (out->str[0] == '.' || out->str[0] == ' ')) {
        g_string_erase(out, 0, 1);
    }
    while (out->len && out->str[out->len - 1] == ' ')
        g_string_truncate(out, out->len - 1);
    if (!out->len || strcmp(out->str, ".") == 0 ||
        strcmp(out->str, "..") == 0) {
        g_string_assign(out, "theme");
    }
    return g_string_free(out, FALSE);
}

static char *strip_archive_suffixes(const char *path)
{
    char *base = g_path_get_basename(path);
    char *lower = g_ascii_strdown(base, -1);
    static const char *suffixes[] = {
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lz", ".tar.zst", ".tar.lzma",
        ".tgz", ".tbz", ".tbz2", ".txz", ".zip", ".tar", ".7z", ".rar", NULL
    };
    for (guint i = 0; suffixes[i]; i++) {
        gsize n = strlen(suffixes[i]);
        if (strlen(lower) > n && g_str_has_suffix(lower, suffixes[i])) {
            base[strlen(base) - n] = '\0';
            break;
        }
    }
    g_free(lower);
    char *clean = sanitise_name(base);
    g_free(base);
    return clean;
}

static gboolean content_has_group(const char *content, const char *group)
{
    if (!content)
        return FALSE;
    char **lines = g_strsplit(content, "\n", -1);
    gboolean in = FALSE, found = FALSE;
    for (guint i = 0; lines[i]; i++) {
        char *line = g_strstrip(lines[i]);
        if (!*line || *line == '#' || *line == ';')
            continue;
        if (*line == '[' && line[strlen(line) - 1] == ']') {
            in = strncmp(line + 1, group, strlen(group)) == 0 &&
                 line[strlen(group) + 1] == ']';
            if (in)
                found = TRUE;
        }
    }
    g_strfreev(lines);
    return found;
}

static char *content_get(const char *content, const char *group,
                         const char *key)
{
    if (!content)
        return NULL;
    char **lines = g_strsplit(content, "\n", -1);
    gboolean in = FALSE;
    char *result = NULL;
    gsize keylen = strlen(key);
    for (guint i = 0; lines[i]; i++) {
        char *line = g_strstrip(lines[i]);
        if (!*line || *line == '#' || *line == ';')
            continue;
        if (*line == '[' && line[strlen(line) - 1] == ']') {
            in = strncmp(line + 1, group, strlen(group)) == 0 &&
                 line[strlen(group) + 1] == ']';
            continue;
        }
        if (!in || strncmp(line, key, keylen) != 0)
            continue;
        char *p = line + keylen;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '=') {
            p++;
            while (*p == ' ' || *p == '\t')
                p++;
            result = g_strdup(p);
            break;
        }
    }
    g_strfreev(lines);
    return result;
}

static GPtrArray *build_dirs(GPtrArray *entries)
{
    GPtrArray *dirs = g_ptr_array_new_with_free_func(g_free);
    GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal,
                                             g_free, NULL);
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        char *dir = e->is_dir ? g_strdup(e->path) : path_dirname(e->path);
        while (dir && *dir) {
            if (g_hash_table_contains(seen, dir))
                break;
            g_hash_table_add(seen, g_strdup(dir));
            g_ptr_array_add(dirs, g_strdup(dir));
            char *parent = path_dirname(dir);
            g_free(dir);
            dir = parent;
        }
        g_free(dir);
    }
    g_hash_table_destroy(seen);
    return dirs;
}

static char *component_id(ThemeKind kind, const char *root)
{
    return g_strdup_printf("%s:%s", theme_kind_id(kind), root ? root : "");
}

static ThemeComponent *component_get(GPtrArray *components,
                                     GHashTable *by_id,
                                     ThemeKind kind, const char *root,
                                     const char *stem)
{
    char *id = component_id(kind, root);
    ThemeComponent *c = g_hash_table_lookup(by_id, id);
    if (c) {
        g_free(id);
        return c;
    }
    if (components->len >= MAX_COMPONENTS) {
        g_free(id);
        return NULL;
    }
    c = g_new0(ThemeComponent, 1);
    c->kind = kind;
    c->id = id;
    c->source_root = g_strdup(root ? root : "");
    c->valid = TRUE;
    c->selected = TRUE;
    char *base = *c->source_root ? path_basename(c->source_root)
                                 : g_strdup(stem ? stem : "theme");
    c->name = sanitise_name(base);
    g_free(base);
    c->display_name = g_strdup(c->name);
    g_ptr_array_add(components, c);
    g_hash_table_insert(by_id, g_strdup(c->id), c);
    return c;
}

gboolean theme_archive_component_includes(ThemeComponent *c, const char *rel)
{
    if (!rel || !*rel)
        return FALSE;
    switch (c->kind) {
    case THEME_KIND_GTK:
        return rel_starts(rel, "gtk-2.0/") || rel_starts(rel, "gtk-3.0/") ||
               strcmp(rel, "gtk.css") == 0 ||
               strcmp(rel, "index.theme") == 0 ||
               strcmp(rel, "thumbnail.png") == 0 ||
               strcmp(rel, "preview.png") == 0 ||
               rel_starts(rel, "assets/") || rel_starts(rel, "common/") ||
               rel_starts(rel, "gtk-common/");
    case THEME_KIND_XFWM4:
        return rel_starts(rel, "xfwm4/") || strcmp(rel, "index.theme") == 0;
    case THEME_KIND_ICONS:
        if (rel_starts(rel, "cursors/") || rel_starts(rel, "gtk-2.0/") ||
            rel_starts(rel, "gtk-3.0/") || rel_starts(rel, "gtk-4.0/") ||
            rel_starts(rel, "xfwm4/") || theme_archive_is_font(rel))
            return FALSE;
        return TRUE;
    case THEME_KIND_CURSORS:
        return rel_starts(rel, "cursors/") || strcmp(rel, "index.theme") == 0 ||
               strcmp(rel, "cursor.theme") == 0;
    case THEME_KIND_FONTS:
        return theme_archive_is_font(rel);
    default:
        return FALSE;
    }
}

static void set_component_warning(ThemeComponent *c, const char *text)
{
    if (!c || c->warning)
        return;
    c->warning = g_strdup(text);
}

static void add_unsupported(GHashTable *set, GPtrArray *list, const char *label)
{
    if (g_hash_table_contains(set, label))
        return;
    g_hash_table_add(set, g_strdup(label));
    g_ptr_array_add(list, g_strdup(label));
}

static ThemeInspection *inspection_new(void)
{
    ThemeInspection *i = g_new0(ThemeInspection, 1);
    i->components = g_ptr_array_new_with_free_func(NULL);
    i->warnings = g_ptr_array_new_with_free_func(g_free);
    i->unsupported = g_ptr_array_new_with_free_func(g_free);
    return i;
}

void theme_inspection_free(ThemeInspection *inspection)
{
    if (!inspection)
        return;
    g_free(inspection->path);
    g_free(inspection->stem);
    g_free(inspection->error);
    if (inspection->components) {
        for (guint i = 0; i < inspection->components->len; i++) {
            ThemeComponent *c = g_ptr_array_index(inspection->components, i);
            g_free(c->id);
            g_free(c->name);
            g_free(c->display_name);
            g_free(c->source_root);
            g_free(c->details);
            g_free(c->warning);
            g_free(c);
        }
        g_ptr_array_free(inspection->components, TRUE);
    }
    ptr_array_free_strings(inspection->warnings);
    ptr_array_free_strings(inspection->unsupported);
    g_free(inspection);
}

ThemeComponent *theme_component_by_id(ThemeInspection *inspection, const char *id)
{
    if (!inspection || !id)
        return NULL;
    for (guint i = 0; i < inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(inspection->components, i);
        if (strcmp(c->id, id) == 0)
            return c;
    }
    return NULL;
}

ThemeComponent *theme_component_by_kind_name(ThemeInspection *inspection,
                                             ThemeKind kind, const char *name)
{
    if (!inspection || !name)
        return NULL;
    for (guint i = 0; i < inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(inspection->components, i);
        if (c->kind == kind && strcmp(c->name, name) == 0)
            return c;
    }
    return NULL;
}

const char *theme_kind_id(ThemeKind kind)
{
    switch (kind) {
    case THEME_KIND_GTK: return "gtk";
    case THEME_KIND_XFWM4: return "xfwm4";
    case THEME_KIND_ICONS: return "icons";
    case THEME_KIND_CURSORS: return "cursors";
    case THEME_KIND_FONTS: return "fonts";
    default: return "unknown";
    }
}

const char *theme_kind_label(ThemeKind kind)
{
    switch (kind) {
    case THEME_KIND_GTK: return "GTK theme";
    case THEME_KIND_XFWM4: return "XFWM4 window decorations";
    case THEME_KIND_ICONS: return "Icon theme";
    case THEME_KIND_CURSORS: return "Cursor theme";
    case THEME_KIND_FONTS: return "Fonts";
    default: return "Theme component";
    }
}

const char *theme_kind_data_dir(ThemeKind kind)
{
    switch (kind) {
    case THEME_KIND_GTK:
    case THEME_KIND_XFWM4: return "themes";
    case THEME_KIND_ICONS:
    case THEME_KIND_CURSORS: return "icons";
    case THEME_KIND_FONTS: return "fonts";
    default: return "themes";
    }
}

char *theme_component_target_path(ThemeKind kind, const char *name)
{
    const char *data = g_get_user_data_dir();
    if (!data || !*data)
        data = "/tmp";
    return g_build_filename(data, theme_kind_data_dir(kind), name, NULL);
}

char *theme_path_escape(const char *text)
{
    if (!text)
        return g_strdup("");
    GString *out = g_string_new(NULL);
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        switch (*p) {
        case '\\': g_string_append(out, "\\\\"); break;
        case '"': g_string_append(out, "\\\""); break;
        case '\n': g_string_append(out, "\\n"); break;
        case '\r': g_string_append(out, "\\r"); break;
        case '\t': g_string_append(out, "\\t"); break;
        default:
            if (*p < 0x20)
                g_string_append_printf(out, "\\u%04x", *p);
            else
                g_string_append_c(out, (char)*p);
        }
    }
    return g_string_free(out, FALSE);
}

static void finalise_component(GPtrArray *entries, ThemeComponent *c,
                               const char *stem)
{
    (void)stem;
    guint count = 0;
    guint64 bytes = 0;
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        if (!e->is_regular && !e->is_symlink)
            continue;
        char *rel = path_relative_to(e->path, c->source_root);
        if (!rel)
            continue;
        if (theme_archive_component_includes(c, rel)) {
            count++;
            bytes += e->size;
        }
        g_free(rel);
    }
    c->file_count = count;
    c->total_bytes = bytes;
}

static void build_details(ThemeComponent *c)
{
    GString *s = g_string_new(NULL);
    switch (c->kind) {
    case THEME_KIND_GTK:
        if (c->has_gtk2 && c->has_gtk3)
            g_string_append(s, "GTK 2 and GTK 3");
        else if (c->has_gtk3)
            g_string_append(s, "GTK 3");
        else if (c->has_gtk2)
            g_string_append(s, "GTK 2 (legacy)");
        else
            g_string_append(s, "GTK files");
        if (c->has_gtk4)
            g_string_append(s, " - GTK 4 part is not installed");
        break;
    case THEME_KIND_XFWM4:
        g_string_append(s, "XFWM4 window decorations");
        break;
    case THEME_KIND_ICONS:
        g_string_append_printf(s, "Icon theme \"%s\"", c->display_name);
        break;
    case THEME_KIND_CURSORS:
        g_string_append(s, "Xcursor pointer theme");
        break;
    case THEME_KIND_FONTS:
        g_string_append_printf(s, "%u font file%s", c->file_count,
                               c->file_count == 1 ? "" : "s");
        break;
    default:
        break;
    }
    g_free(c->details);
    c->details = g_string_free(s, FALSE);
}

ThemeInspection *theme_inspect_archive(const char *path, GError **error)
{
    ThemeInspection *inspection = inspection_new();
    GStatBuf st;
    if (!path || g_stat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "theme archive does not exist or is not a regular file: %s",
                    path ? path : "(none)");
        inspection->valid = FALSE;
        inspection->error = g_strdup("archive is not a readable regular file");
        return inspection;
    }
    if ((guint64)st.st_size > MAX_ARCHIVE_BYTES) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                    "archive is larger than the %llu MiB limit",
                    (unsigned long long)(MAX_ARCHIVE_BYTES / (1024ULL * 1024ULL)));
        inspection->valid = FALSE;
        inspection->error = g_strdup("archive is too large");
        return inspection;
    }

    inspection->path = g_strdup(path);
    inspection->stem = strip_archive_suffixes(path);

    GPtrArray *entries = g_ptr_array_new_with_free_func(
        (GDestroyNotify)archive_rec_free);
    guint64 archived = 0, uncompressed = 0;
    guint symlinks = 0;
    GError *read_error = NULL;
    if (!read_archive_entries(path, entries, &archived, &uncompressed,
                              &symlinks, &read_error)) {
        inspection->valid = FALSE;
        inspection->error = g_strdup(read_error->message);
        g_propagate_error(error, read_error);
        g_ptr_array_free(entries, TRUE);
        return inspection;
    }
    inspection->archive_size = archived;
    inspection->total_uncompressed = uncompressed;
    inspection->safe_symlinks = symlinks;

    GHashTable *by_path = g_hash_table_new(g_str_hash, g_str_equal);
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        g_hash_table_insert(by_path, e->path, e);
    }
    GPtrArray *dirs = build_dirs(entries);
    GHashTable *dir_set = g_hash_table_new(g_str_hash, g_str_equal);
    for (guint i = 0; i < dirs->len; i++)
        g_hash_table_add(dir_set, g_ptr_array_index(dirs, i));

    GPtrArray *components = inspection->components;
    GHashTable *by_id = g_hash_table_new_full(g_str_hash, g_str_equal,
                                              g_free, NULL);
    GHashTable *unsupported_set = g_hash_table_new_full(g_str_hash,
                                                        g_str_equal,
                                                        g_free, NULL);
    guint skipped_scripts = 0;
    guint invalid_fonts = 0;
    guint fonts = 0;

    /* GTK and XFWM4 markers first.  A theme directory is the parent of the
     * gtk-3.0 / gtk-2.0 / xfwm4 directory, which is what makes nested archive
     * layouts and flat ones behave the same way. */
    for (guint i = 0; i < dirs->len; i++) {
        const char *dir = g_ptr_array_index(dirs, i);
        char *base = path_basename(dir);
        char *root = path_dirname(dir);
        if (strcmp(base, "gtk-3.0") == 0) {
            ThemeComponent *c = component_get(components, by_id,
                                              THEME_KIND_GTK, root,
                                              inspection->stem);
            if (c) {
                c->has_gtk3 = TRUE;
                char *css = g_build_filename(dir, "gtk.css", NULL);
                ArchiveEntry *entry = entry_by_path(by_path, css);
                if (!entry || !entry->is_regular || entry->size == 0)
                    set_component_warning(c,
                        "gtk-3.0 exists but gtk-3.0/gtk.css is missing or empty");
                g_free(css);
            }
        } else if (strcmp(base, "gtk-2.0") == 0) {
            ThemeComponent *c = component_get(components, by_id,
                                              THEME_KIND_GTK, root,
                                              inspection->stem);
            if (c) {
                c->has_gtk2 = TRUE;
                char *rc = g_build_filename(dir, "gtkrc", NULL);
                ArchiveEntry *entry = entry_by_path(by_path, rc);
                if (!entry || !entry->is_regular || entry->size == 0)
                    set_component_warning(c,
                        "gtk-2.0 exists but gtk-2.0/gtkrc is missing or empty");
                g_free(rc);
            }
        } else if (strcmp(base, "gtk-4.0") == 0) {
            add_unsupported(unsupported_set, inspection->unsupported,
                            "GTK 4 theme files (GTK 4 and libadwaita do not follow GTK 3 themes)");
        } else if (strcmp(base, "xfwm4") == 0) {
            char *themerc = g_build_filename(dir, "themerc", NULL);
            ArchiveEntry *entry = entry_by_path(by_path, themerc);
            if (entry && entry->is_regular && entry->size > 0) {
                component_get(components, by_id, THEME_KIND_XFWM4, root,
                              inspection->stem);
            } else {
                g_ptr_array_add(inspection->warnings,
                                g_strdup_printf("ignored %s: no themerc file",
                                                dir));
            }
            g_free(themerc);
        } else if (strcmp(base, "gnome-shell") == 0 ||
                   strcmp(base, "metacity-1") == 0 ||
                   strcmp(base, "cinnamon") == 0 ||
                   strcmp(base, "plank") == 0 ||
                   strcmp(base, "aurorae") == 0 ||
                   strcmp(base, "openbox-3") == 0 ||
                   strcmp(base, "icewm") == 0 ||
                   strcmp(base, "fluxbox") == 0) {
            char *label = g_strdup_printf("%s themes", base);
            add_unsupported(unsupported_set, inspection->unsupported, label);
            g_free(label);
        }
        g_free(base);
        g_free(root);
    }

    /* Icon and cursor themes are identified by their metadata, and a cursor
     * theme is further identified by a cursors/ directory. */
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        if (!e->is_regular)
            continue;
        char *base = path_basename(e->path);
        gboolean is_index = strcmp(base, "index.theme") == 0;
        gboolean is_cursor_theme = strcmp(base, "cursor.theme") == 0;
        g_free(base);
        if (!is_index && !is_cursor_theme)
            continue;

        char *root = path_dirname(e->path);
        char *cursors = g_build_filename(root, "cursors", NULL);
        gboolean has_cursors_dir = g_hash_table_contains(dir_set, cursors);
        guint cursor_files = 0, icon_files = 0;
        for (guint j = 0; j < entries->len; j++) {
            ArchiveEntry *x = g_ptr_array_index(entries, j);
            char *rel = path_relative_to(x->path, root);
            if (!rel)
                continue;
            if (rel_starts(rel, "cursors/") && (x->is_regular || x->is_symlink))
                cursor_files++;
            else if (x->is_regular && strcmp(rel, "index.theme") != 0 &&
                     strcmp(rel, "cursor.theme") != 0 &&
                     !theme_archive_is_font(rel))
                icon_files++;
            g_free(rel);
        }

        gboolean icon_group = content_has_group(e->metadata, "Icon Theme");
        if (is_cursor_theme || (has_cursors_dir && cursor_files > 0)) {
            ThemeComponent *c = component_get(components, by_id,
                                              THEME_KIND_CURSORS, root,
                                              inspection->stem);
            if (c) {
                c->file_count = cursor_files;
                if (!is_index && !is_cursor_theme)
                    set_component_warning(c, "cursor theme has no metadata");
                if (!icon_group && is_index && !is_cursor_theme)
                    set_component_warning(c,
                        "index.theme does not contain an [Icon Theme] section");
            }
        }
        if (is_index && icon_group && icon_files > 0 && cursor_files == 0) {
            ThemeComponent *c = component_get(components, by_id,
                                              THEME_KIND_ICONS, root,
                                              inspection->stem);
            if (c) {
                char *name = content_get(e->metadata, "Icon Theme", "Name");
                if (name && *name) {
                    g_free(c->display_name);
                    c->display_name = name;
                } else {
                    g_free(name);
                    c->valid = FALSE;
                    set_component_warning(c,
                        "icon theme index.theme has no Name entry");
                }
                char *inherits = content_get(e->metadata, "Icon Theme",
                                             "Inherits");
                if (!inherits || !*inherits)
                    set_component_warning(c,
                        "icon theme does not declare Inherits; GTK will fall back to hicolor");
                g_free(inherits);
            }
        }
        g_free(cursors);
        g_free(root);
    }

    /* Fonts are their own component.  Every candidate is checked by magic as
     * well as extension: a .ttf that is actually an ELF or a script is not a
     * font and is never installed as one. */
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        if (!e->is_regular || !theme_archive_is_font(e->path))
            continue;
        if (theme_archive_font_magic(e->head, e->head_len))
            fonts++;
        else
            invalid_fonts++;
    }
    if (fonts > 0) {
        ThemeComponent *c = component_get(components, by_id, THEME_KIND_FONTS,
                                          "", inspection->stem);
        if (c)
            c->file_count = fonts;
    }
    if (invalid_fonts > 0) {
        g_ptr_array_add(inspection->warnings,
                        g_strdup_printf("ignored %u file%s with a font extension but invalid font data",
                                        invalid_fonts, invalid_fonts == 1 ? "" : "s"));
    }

    /* Only scripts/executables are counted here; they are never run and are
     * skipped during extraction. */
    for (guint i = 0; i < entries->len; i++) {
        ArchiveEntry *e = g_ptr_array_index(entries, i);
        if (theme_archive_looks_executable(e->path, e->head, e->head_len))
            skipped_scripts++;
    }
    inspection->skipped_scripts = skipped_scripts;
    if (skipped_scripts > 0)
        g_ptr_array_add(inspection->warnings,
                        g_strdup_printf("%u script%s or executable%s found and will not be run",
                                        skipped_scripts,
                                        skipped_scripts == 1 ? "" : "s",
                                        skipped_scripts == 1 ? "" : "s"));

    /* Compute counts, details and conflicts now so the GUI can show the
     * review screen without another archive pass. */
    for (guint i = 0; i < components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(components, i);
        finalise_component(entries, c, inspection->stem);
        if (c->file_count == 0)
            c->valid = FALSE;
        if (c->kind == THEME_KIND_GTK && c->valid) {
            /* A GTK theme is useful only if at least one real entry point
             * exists.  The marker loop already warns when one is missing. */
            if (!c->has_gtk2 && !c->has_gtk3)
                c->valid = FALSE;
        }
        if (c->kind == THEME_KIND_XFWM4 && c->file_count == 0)
            c->valid = FALSE;
        if (c->kind == THEME_KIND_FONTS && fonts == 0)
            c->valid = FALSE;
        build_details(c);
        char *target = theme_component_target_path(c->kind, c->name);
        GStatBuf tst;
        c->conflict = lstat(target, &tst) == 0;
        g_free(target);
        if (c->warning)
            g_ptr_array_add(inspection->warnings,
                            g_strdup_printf("%s: %s", c->display_name,
                                            c->warning));
    }

    if (components->len == 0) {
        inspection->valid = FALSE;
        inspection->error = g_strdup("no recognized theme components were found "
                                     "in this archive");
    } else {
        gboolean any_valid = FALSE;
        for (guint i = 0; i < components->len; i++) {
            ThemeComponent *c = g_ptr_array_index(components, i);
            if (c->valid)
                any_valid = TRUE;
        }
        inspection->valid = any_valid;
        if (!any_valid)
            inspection->error = g_strdup("the archive contains theme files but "
                                         "none of them form a complete component");
    }

    if (inspection->safe_symlinks > 0)
        g_ptr_array_add(inspection->warnings,
                        g_strdup_printf("%u internal symlink%s will be installed without following them",
                                        inspection->safe_symlinks,
                                        inspection->safe_symlinks == 1 ? "" : "s"));
    if (inspection->unsupported->len > 0)
        g_ptr_array_add(inspection->warnings,
                        g_strdup("some files belong to desktop components Copper does not install; they are listed above and were not used"));

    g_hash_table_destroy(by_id);
    g_hash_table_destroy(unsupported_set);
    g_hash_table_destroy(dir_set);
    g_ptr_array_free(dirs, TRUE);
    g_hash_table_destroy(by_path);
    g_ptr_array_free(entries, TRUE);
    return inspection;
}

/* Extract one preview image to dest_path for the review screen.  It obeys the
 * same path rules as the installer and writes with O_NOFOLLOW|O_EXCL. */
gboolean theme_extract_preview(const char *archive_path, const char *source_root,
                               const char *dest_path, GError **error)
{
    struct archive *a = archive_read_new();
    if (!a)
        return FALSE;
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_zip(a);
    if (archive_read_open_filename(a, archive_path, 65536) != ARCHIVE_OK) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                    "cannot open archive: %s", archive_error_string(a));
        archive_read_free(a);
        return FALSE;
    }

    static const char *names[] = {
        "preview.png", "preview.jpg", "preview.jpeg", "screenshot.png",
        "thumbnail.png", "thumbnail.jpg", "theme.png", "theme.jpg", NULL
    };
    gboolean found = FALSE;
    while (TRUE) {
        struct archive_entry *ae = NULL;
        int r = archive_read_next_header(a, &ae);
        if (r == ARCHIVE_EOF)
            break;
        if (r != ARCHIVE_OK && r != ARCHIVE_WARN)
            break;
        const char *raw = archive_entry_pathname_utf8(ae);
        if (!raw)
            raw = archive_entry_pathname(ae);
        GError *path_error = NULL;
        char *normalised = theme_archive_normalise_path(raw, &path_error);
        if (!normalised) {
            g_clear_error(&path_error);
            archive_read_data_skip(a);
            continue;
        }
        char *rel = path_relative_to(normalised, source_root);
        g_free(normalised);
        if (!rel) {
            archive_read_data_skip(a);
            continue;
        }
        char *base = path_basename(rel);
        gboolean wanted = FALSE;
        for (guint i = 0; names[i]; i++) {
            if (g_ascii_strcasecmp(base, names[i]) == 0) {
                wanted = TRUE;
                break;
            }
        }
        g_free(base);
        g_free(rel);
        if (!wanted) {
            archive_read_data_skip(a);
            continue;
        }
        mode_t mode = archive_entry_filetype(ae);
        guint64 size = archive_entry_size_is_set(ae)
                           ? (guint64)archive_entry_size(ae) : 0;
        if (!(mode == 0 || S_ISREG(mode)) || size == 0 ||
            size > MAX_PREVIEW_BYTES) {
            archive_read_data_skip(a);
            continue;
        }
        int fd = open(dest_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                                  O_CLOEXEC, 0600);
        if (fd < 0) {
            g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                        "cannot create preview file: %s", g_strerror(errno));
            archive_read_free(a);
            return FALSE;
        }
        guchar buf[16384];
        guint64 written = 0;
        while (TRUE) {
            la_ssize_t n = archive_read_data(a, buf, sizeof buf);
            if (n == 0)
                break;
            if (n < 0) {
                close(fd);
                unlink(dest_path);
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_IO,
                            "cannot read preview: %s", archive_error_string(a));
                archive_read_free(a);
                return FALSE;
            }
            if (written + (guint64)n > MAX_PREVIEW_BYTES) {
                close(fd);
                unlink(dest_path);
                g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOSPC,
                            "preview image is too large");
                archive_read_free(a);
                return FALSE;
            }
            gsize off = 0;
            while (off < (gsize)n) {
                ssize_t w = write(fd, buf + off, (gsize)n - off);
                if (w < 0) {
                    close(fd);
                    unlink(dest_path);
                    g_set_error(error, G_FILE_ERROR,
                                g_file_error_from_errno(errno),
                                "cannot write preview: %s", g_strerror(errno));
                    archive_read_free(a);
                    return FALSE;
                }
                off += (gsize)w;
            }
            written += (guint64)n;
        }
        close(fd);
        found = TRUE;
        break;
    }
    archive_read_free(a);
    if (!found)
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                    "archive has no preview image");
    return found;
}
