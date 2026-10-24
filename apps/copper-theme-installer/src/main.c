/* main.c -- command line front end for copper-theme-installer.
 *
 * Two modes share the same library code as the window:
 *
 *   copper-theme-installer ARCHIVE
 *   copper-theme-installer --inspect ARCHIVE
 *   copper-theme-installer --install ARCHIVE [options]
 *
 * --inspect and --install exist so the archive rules and the installer can be
 * tested without an X or Wayland session.  They also make the application
 * scriptable, which is useful when a download manager hands over a file.
 */
#include "theme.h"
#include "gui.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>

#define EXIT_USAGE 2

static void print_usage(FILE *out)
{
    fprintf(out,
        "Usage:\n"
        "  copper-theme-installer ARCHIVE\n"
        "  copper-theme-installer --inspect ARCHIVE\n"
        "  copper-theme-installer --install ARCHIVE [options]\n"
        "\n"
        "Options for --install:\n"
        "  --component ID      install only this component (repeatable)\n"
        "  --replace           replace themes with the same directory name\n"
        "  --apply             apply the installed theme to this desktop\n"
        "  --apply-gtk         apply the GTK theme only\n"
        "  --apply-icons       apply the icon theme only\n"
        "  --apply-cursors     apply the cursor theme only\n"
        "  --apply-xfwm4       apply the window decorations only\n"
        "  --no-cache          do not refresh icon and font caches\n"
        "  --json              print machine-readable JSON (default)\n"
        "\n"
        "With no mode, ARCHIVE opens the graphical review window.\n"
        "The exit status is 0 on success, 1 on failure and 2 on bad usage.\n");
}

static void print_json_string(const char *value)
{
    char *escaped = theme_path_escape(value ? value : "");
    fputs("\"", stdout);
    fputs(escaped, stdout);
    fputs("\"", stdout);
    g_free(escaped);
}

static gboolean inspect_json(const char *path, int *exit_status)
{
    GError *error = NULL;
    ThemeInspection *inspection = theme_inspect_archive(path, &error);
    if (!inspection) {
        fprintf(stderr, "copper-theme-installer: %s\n",
                error ? error->message : "cannot inspect archive");
        g_clear_error(&error);
        *exit_status = 1;
        return FALSE;
    }

    printf("{\n  \"valid\": %s,\n", inspection->valid ? "true" : "false");
    printf("  \"path\": "); print_json_string(inspection->path); printf(",\n");
    printf("  \"stem\": "); print_json_string(inspection->stem); printf(",\n");
    printf("  \"error\": "); print_json_string(inspection->error); printf(",\n");
    printf("  \"archive_size\": %" G_GUINT64_FORMAT ",\n",
           inspection->archive_size);
    printf("  \"total_uncompressed\": %" G_GUINT64_FORMAT ",\n",
           inspection->total_uncompressed);
    printf("  \"skipped_scripts\": %u,\n", inspection->skipped_scripts);
    printf("  \"safe_symlinks\": %u,\n", inspection->safe_symlinks);

    printf("  \"components\": [");
    for (guint i = 0; i < inspection->components->len; i++) {
        ThemeComponent *c = g_ptr_array_index(inspection->components, i);
        printf("%s\n    {", i == 0 ? "" : ",");
        printf("\"id\": "); print_json_string(c->id);
        printf(", \"kind\": "); print_json_string(theme_kind_id(c->kind));
        printf(", \"name\": "); print_json_string(c->name);
        printf(", \"display_name\": "); print_json_string(c->display_name);
        printf(", \"source_root\": "); print_json_string(c->source_root);
        printf(", \"details\": "); print_json_string(c->details);
        printf(", \"warning\": "); print_json_string(c->warning);
        printf(", \"valid\": %s", c->valid ? "true" : "false");
        printf(", \"selected\": %s", c->selected ? "true" : "false");
        printf(", \"conflict\": %s", c->conflict ? "true" : "false");
        printf(", \"has_gtk2\": %s", c->has_gtk2 ? "true" : "false");
        printf(", \"has_gtk3\": %s", c->has_gtk3 ? "true" : "false");
        printf(", \"has_gtk4\": %s", c->has_gtk4 ? "true" : "false");
        printf(", \"file_count\": %u", c->file_count);
        printf(", \"total_bytes\": %" G_GUINT64_FORMAT, c->total_bytes);
        printf("}");
    }
    printf("%s],\n", inspection->components->len ? "\n  " : "");

    printf("  \"warnings\": [");
    for (guint i = 0; i < inspection->warnings->len; i++) {
        if (i)
            printf(", ");
        print_json_string(g_ptr_array_index(inspection->warnings, i));
    }
    printf("],\n  \"unsupported\": [");
    for (guint i = 0; i < inspection->unsupported->len; i++) {
        if (i)
            printf(", ");
        print_json_string(g_ptr_array_index(inspection->unsupported, i));
    }
    printf("]\n}\n");

    *exit_status = inspection->valid ? 0 : 3;
    gboolean valid = inspection->valid;
    theme_inspection_free(inspection);
    return valid;
}

static void print_install_result(ThemeInstallResult *result, gboolean ok)
{
    printf("{\n  \"ok\": %s,\n  \"changed_desktop\": %s,\n",
           ok ? "true" : "false",
           result->changed_desktop ? "true" : "false");
    printf("  \"installed\": [");
    for (guint i = 0; i < result->installed->len; i++) {
        if (i)
            printf(", ");
        print_json_string(g_ptr_array_index(result->installed, i));
    }
    printf("],\n  \"skipped\": [");
    for (guint i = 0; i < result->skipped->len; i++) {
        if (i)
            printf(", ");
        print_json_string(g_ptr_array_index(result->skipped, i));
    }
    printf("],\n  \"warnings\": [");
    for (guint i = 0; i < result->warnings->len; i++) {
        if (i)
            printf(", ");
        print_json_string(g_ptr_array_index(result->warnings, i));
    }
    printf("]\n}\n");
}

static int run_inspect(int argc, char **argv)
{
    const char *archive = NULL;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--inspect") == 0)
            continue;
        if (!archive)
            archive = argv[i];
        else {
            fprintf(stderr, "copper-theme-installer: --inspect takes one archive\n");
            return EXIT_USAGE;
        }
    }
    if (!archive) {
        print_usage(stderr);
        return EXIT_USAGE;
    }
    int status = 1;
    inspect_json(archive, &status);
    return status;
}

static int run_install(int argc, char **argv)
{
    ThemeInstallOptions options = { 0 };
    options.refresh_caches = TRUE;
    options.component_ids = g_ptr_array_new_with_free_func(g_free);

    const char *archive = NULL;
    for (int i = 2; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--install") == 0)
            continue;
        if (strcmp(arg, "--component") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "copper-theme-installer: --component needs an ID\n");
                g_ptr_array_free(options.component_ids, TRUE);
                return EXIT_USAGE;
            }
            g_ptr_array_add(options.component_ids, g_strdup(argv[i]));
        } else if (strcmp(arg, "--replace") == 0) {
            options.replace = TRUE;
        } else if (strcmp(arg, "--apply") == 0) {
            options.apply = TRUE;
            options.apply_gtk = TRUE;
            options.apply_icons = TRUE;
            options.apply_cursors = TRUE;
            options.apply_xfwm4 = TRUE;
        } else if (strcmp(arg, "--apply-gtk") == 0) {
            options.apply = TRUE;
            options.apply_gtk = TRUE;
        } else if (strcmp(arg, "--apply-icons") == 0) {
            options.apply = TRUE;
            options.apply_icons = TRUE;
        } else if (strcmp(arg, "--apply-cursors") == 0) {
            options.apply = TRUE;
            options.apply_cursors = TRUE;
        } else if (strcmp(arg, "--apply-xfwm4") == 0) {
            options.apply = TRUE;
            options.apply_xfwm4 = TRUE;
        } else if (strcmp(arg, "--no-cache") == 0) {
            options.refresh_caches = FALSE;
        } else if (strcmp(arg, "--json") == 0) {
            /* JSON is the only format; accepted for script readability. */
        } else if (arg[0] == '-') {
            fprintf(stderr, "copper-theme-installer: unknown option %s\n", arg);
            g_ptr_array_free(options.component_ids, TRUE);
            return EXIT_USAGE;
        } else if (!archive) {
            archive = arg;
        } else {
            fprintf(stderr, "copper-theme-installer: --install takes one archive\n");
            g_ptr_array_free(options.component_ids, TRUE);
            return EXIT_USAGE;
        }
    }
    if (!archive) {
        print_usage(stderr);
        g_ptr_array_free(options.component_ids, TRUE);
        return EXIT_USAGE;
    }
    options.archive_path = (char *)archive;

    GError *error = NULL;
    ThemeInstallResult *result = NULL;
    gboolean ok = theme_install(&options, &result, &error);
    if (!ok && (!result || result->installed->len == 0)) {
        fprintf(stderr, "copper-theme-installer: %s\n",
                error ? error->message : "installation failed");
    }
    if (result)
        print_install_result(result, ok);
    g_clear_error(&error);
    theme_install_result_free(result);
    g_ptr_array_free(options.component_ids, TRUE);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc > 1) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            print_usage(stdout);
            return 0;
        }
        if (strcmp(argv[1], "--version") == 0) {
            printf("copper-theme-installer %s\n", COPPER_THEME_INSTALLER_VERSION);
            return 0;
        }
        if (strcmp(argv[1], "--inspect") == 0)
            return run_inspect(argc, argv);
        if (strcmp(argv[1], "--install") == 0)
            return run_install(argc, argv);
        if (argv[1][0] == '-') {
            fprintf(stderr, "copper-theme-installer: unknown option %s\n", argv[1]);
            print_usage(stderr);
            return EXIT_USAGE;
        }
        return gui_run(argv[1]);
    }
    return gui_run(NULL);
}
