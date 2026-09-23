/*
 * copper-sh — the Copper Linux shell, v0.1.0-dev
 *
 * A tiny POSIX shell. Mostly builtins so it works even before a
 * full coreutils exists on the system.
 *
 * Build:  make
 * Run:    ./copper-sh
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <limits.h>
#include <sys/wait.h>

#include "builtins.h"

#define HIST_MAX 64

static char *hist[HIST_MAX];
static int   hist_n  = 0;

static const struct builtin btable[] = {
    { "help",    b_help,    "show this list" },
    { "exit",    b_exit,    "leave the shell (or ctrl-d)" },
    { "quit",    b_exit,    "same as exit" },
    { "pwd",     b_pwd,     "print working directory" },
    { "cd",      b_cd,      "change directory: cd, cd ~, cd -, cd .." },
    { "ls",      b_ls,      "list files: ls [-a] [-l] [path]" },
    { "cat",     b_cat,     "print files: cat [file...]" },
    { "echo",    b_echo,    "print text: echo [-n] [text...]" },
    { "clear",   b_clear,   "clear the screen" },
    { "whoami",  b_whoami,  "print your username" },
    { "uname",   b_uname,   "print system info" },
    { "date",    b_date,    "print the date and time" },
    { "mkdir",   b_mkdir,   "make a directory" },
    { "rmdir",   b_rmdir,   "remove an empty directory" },
    { "touch",   b_touch,   "create or update a file" },
    { "rm",      b_rm,      "remove files: rm [-r] [file...]" },
    { "cp",      b_cp,      "copy a file: cp SRC DST" },
    { "mv",      b_mv,      "move or rename a file: mv SRC DST" },
    { "history", b_history, "show this session's command history" },
    { "type",    b_type,    "is a command builtin or external?" },
    { "which",   b_which,   "show where a command lives on PATH" },
    { "env",     b_env,     "print the environment" },
    { NULL, NULL, NULL },
};

const struct builtin *builtin_lookup(const char *name) {
    for (const struct builtin *b = btable; b->name; b++)
        if (!strcmp(name, b->name)) return b;
    return NULL;
}

/* ---------------------------------------------------------------- */

static void banner(void) {
    puts("");
    puts("        ___           Copper Linux v0.1.0-dev");
    puts("       /   \\          Shell:  copper-sh");
    puts("      | C L |         Status: in development");
    puts("       \\___/          Type \"help\" for the builtins");
    puts("      /     \\");
    puts("     /       \\        (yeah it's a real shell)");
    puts("    /_________\\");
    puts("");
}

/* cwd for the prompt, replacing $HOME with ~ */
static char *short_pwd(char *buf, size_t n) {
    if (!getcwd(buf, n)) { snprintf(buf, n, "?"); return buf; }
    const char *home = getenv("HOME");
    if (home) {
        size_t hl = strlen(home);
        if (!strncmp(buf, home, hl) && (buf[hl] == '/' || buf[hl] == '\0')) {
            char tmp[PATH_MAX];
            snprintf(tmp, sizeof tmp, "~%s", buf + hl);
            snprintf(buf, n, "%s", tmp);
        }
    }
    return buf;
}

/*
 * Split a line into argv. Handles single/double quotes and
 * backslash-escapes (enough for echo "hello world" to work).
 * Modifies the input line in place.
 */
static char **tokenize_line(char *line, int *count) {
    static char *argv[256];
    int n = 0, inw = 0;
    char *dst = line;

    for (char *src = line;; src++) {
        char c = *src;
        if (!c) break;
        if (c == ' ' || c == '\t') {
            if (inw) { *dst++ = '\0'; inw = 0; }
            continue;
        }
        if (c == '#') break;             /* comment to end of line */
        if (!inw) { argv[n++] = dst; inw = 1; }
        if (c == '\\' && src[1]) { *dst++ = src[1]; src++; continue; }
        if (c == '\'' || c == '"') {     /* strip quotes */
            for (src++; *src && *src != c; src++) *dst++ = *src;
            continue;
        }
        *dst++ = c;
    }
    if (inw) *dst++ = '\0';
    argv[n] = NULL;
    *count = n;
    return argv;
}

static void run_external(char **argv) {
    pid_t pid = fork();
    if (pid < 0) { perror("copper-sh: fork"); return; }
    if (pid == 0) {
        signal(SIGINT, SIG_DFL);
        execvp(argv[0], argv);
        fprintf(stderr, "copper-sh: %s: command not found\n", argv[0]);
        _exit(127);
    }
    int st;
    waitpid(pid, &st, 0);
}

int b_help(int argc, char **argv) {
    (void)argc; (void)argv;
    puts("copper-sh builtins:");
    for (const struct builtin *b = btable; b->name; b++)
        printf("  %-11s %s\n", b->name, b->desc);
    puts("");
    puts("anything else runs as an external command (uname, vi, top...)");
    return 0;
}

int b_exit(int argc, char **argv) {
    (void)argc; (void)argv;
    puts("bye");
    return 0;
}

int b_history(int argc, char **argv) {
    (void)argc; (void)argv;
    for (int i = 0; i < hist_n; i++)
        printf("%4d  %s\n", i + 1, hist[i]);
    return 0;
}

/* ---------------------------------------------------------------- */

int main(void) {
    char *line = NULL;
    size_t cap = 0;

    signal(SIGINT, SIG_IGN);             /* ctrl-c must not kill the shell */
    banner();

    while (1) {
        char cwd[PATH_MAX];
        printf("copper@copper:%s$ ", short_pwd(cwd, sizeof cwd));
        fflush(stdout);

        ssize_t len = getline(&line, &cap, stdin);
        if (len < 0) { putchar('\n'); break; }      /* ctrl-d = exit */

        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';

        int argc;
        char **argv = tokenize_line(line, &argc);
        if (argc == 0) continue;

        /* session history */
        if (hist_n < HIST_MAX) {
            hist[hist_n++] = strdup(line);
        } else {
            free(hist[0]);
            memmove(hist, hist + 1, (HIST_MAX - 1) * sizeof(*hist));
            hist[HIST_MAX - 1] = strdup(line);
        }

        const struct builtin *b = builtin_lookup(argv[0]);
        int bye = 0;
        if (b) {
            b->fn(argc, argv);
            if (!strcmp(argv[0], "exit") || !strcmp(argv[0], "quit")) bye = 1;
        } else {
            run_external(argc, argv);
        }
        if (bye) break;
    }

    for (int i = 0; i < hist_n; i++) free(hist[i]);
    free(line);
    return 0;
}