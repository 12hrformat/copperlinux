/*
 * copper-sh — the Copper Linux shell, v0.1.0-dev
 *
 * A tiny POSIX shell. Mostly builtins so it works even before a
 * full coreutils exists on the system.
 *
 * Supports: pipes (|) and < > >> redirection.
 * Line editing: arrow keys, backspace, history navigation.
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
#include <fcntl.h>
#include <limits.h>
#include <errno.h>
#include <termios.h>
#include <sys/wait.h>

#include "builtins.h"

#define HIST_MAX 64
#define EDIT_BUF_SIZE 4096

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
    { "head",    b_head,    "first lines: head [-n N] [file...]" },
    { "tail",    b_tail,    "last lines: tail [-n N] [file...]" },
    { "wc",      b_wc,      "count lines/words/bytes: wc [-lwc] [file...]" },
    { "grep",    b_grep,    "search text: grep [-inv] PATTERN [file...]" },
    { "tee",     b_tee,     "copy stdin to files and stdout: tee [-a] file..." },
    { "sleep",   b_sleep,   "wait N seconds" },
    { "true",    b_true,    "do nothing, exit 0" },
    { "false",   b_false,   "do nothing, exit 1" },
    { "clear",   b_clear,   "clear the screen" },
    { "whoami",  b_whoami,  "print your username" },
    { "id",      b_id,      "print uid/gid info" },
    { "hostname", b_hostname, "print the machine's hostname" },
    { "uname",   b_uname,   "print system info" },
    { "date",    b_date,    "print the date and time" },
    { "basename", b_basename, "strip dirs/suffix from a path" },
    { "dirname", b_dirname,  "print the directory part of a path" },
    { "mkdir",   b_mkdir,   "make a directory" },
    { "rmdir",   b_rmdir,   "remove an empty directory" },
    { "touch",   b_touch,   "create or update a file" },
    { "rm",      b_rm,      "remove files: rm [-r] [file...]" },
    { "cp",      b_cp,      "copy a file: cp SRC DST" },
    { "mv",      b_mv,      "move or rename a file: mv SRC DST" },
    { "ln",      b_ln,      "make links: ln [-s] TARGET LINK" },
    { "chmod",   b_chmod,   "change mode: chmod OCTAL FILE" },
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
/*  line editor                                                       */

static char edit_buf[EDIT_BUF_SIZE];
static int edit_len = 0;
static int edit_pos = 0;
static int hist_idx = -1;              /* -1 = editing, 0+ = browsing */
static char saved_line[EDIT_BUF_SIZE]; /* line being edited before history */
static struct termios orig_termios;
static int raw_mode = 0;

static void disable_raw_mode(void) {
    if (raw_mode)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
    raw_mode = 0;
}

static int enable_raw_mode(void) {
    if (!isatty(STDIN_FILENO)) return 0;
    if (tcgetattr(STDIN_FILENO, &orig_termios) == -1) return -1;
    raw_mode = 1;
    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    return tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
}

static void refresh_line(const char *prompt) {
    /* \r\033[K: go to col 0, clear line. Print prompt+buf, then
       reposition cursor at prompt_len + edit_pos. */
    char seq[EDIT_BUF_SIZE + 128];
    int n = snprintf(seq, sizeof seq, "\r\033[K%s%s\r\033[%dC",
                     prompt, edit_buf,
                     (int)(strlen(prompt) + edit_pos));
    if (n > 0)
        write(STDOUT_FILENO, seq, (size_t)n);
}

static void edit_insert(char c) {
    if (edit_len >= EDIT_BUF_SIZE - 1) return;
    memmove(edit_buf + edit_pos + 1, edit_buf + edit_pos,
            (size_t)(edit_len - edit_pos));
    edit_buf[edit_pos] = c;
    edit_len++;
    edit_pos++;
    edit_buf[edit_len] = '\0';
}

static void edit_backspace(void) {
    if (edit_pos == 0) return;
    memmove(edit_buf + edit_pos - 1, edit_buf + edit_pos,
            (size_t)(edit_len - edit_pos));
    edit_pos--;
    edit_len--;
    edit_buf[edit_len] = '\0';
}

static void edit_delete(void) {
    if (edit_pos >= edit_len) return;
    memmove(edit_buf + edit_pos, edit_buf + edit_pos + 1,
            (size_t)(edit_len - edit_pos - 1));
    edit_len--;
    edit_buf[edit_len] = '\0';
}

static void edit_move_left(void) {
    if (edit_pos > 0) edit_pos--;
}

static void edit_move_right(void) {
    if (edit_pos < edit_len) edit_pos++;
}

static void edit_move_home(void) { edit_pos = 0; }
static void edit_move_end(void)  { edit_pos = edit_len; }

static void edit_hist_prev(void) {
    if (hist_idx < hist_n - 1) {
        if (hist_idx == -1)
            snprintf(saved_line, sizeof saved_line, "%s", edit_buf);
        hist_idx++;
        snprintf(edit_buf, sizeof edit_buf, "%s",
                 hist[hist_n - 1 - hist_idx]);
        edit_len = (int)strlen(edit_buf);
        edit_pos = edit_len;
    }
}

static void edit_hist_next(void) {
    if (hist_idx >= 0) {
        hist_idx--;
        if (hist_idx == -1)
            snprintf(edit_buf, sizeof edit_buf, "%s", saved_line);
        else
            snprintf(edit_buf, sizeof edit_buf, "%s",
                     hist[hist_n - 1 - hist_idx]);
        edit_len = (int)strlen(edit_buf);
        edit_pos = edit_len;
    }
}

/*
 * Read a line with full editing. Returns 1 if a line was read,
 * 0 on EOF (Ctrl-D on empty line, or read error).
 * Falls back to getline() when stdin is not a tty.
 */
static int read_line_edited(char *buf, size_t cap, const char *prompt) {
    if (!raw_mode) {
        printf("%s", prompt);
        fflush(stdout);
        char *line = NULL;
        size_t n = 0;
        ssize_t len = getline(&line, &n, stdin);
        if (len < 0) { free(line); return 0; }
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        snprintf(buf, cap, "%s", line);
        free(line);
        return 1;
    }

    edit_len = 0;
    edit_pos = 0;
    edit_buf[0] = '\0';
    hist_idx = -1;
    saved_line[0] = '\0';

    refresh_line(prompt);

    for (;;) {
        char c;
        ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            if (edit_len == 0) { printf("\n"); return 0; }
            continue;
        }

        if (c == '\r' || c == '\n') {
            printf("\n");
            break;
        } else if (c == 4) {                   /* Ctrl-D */
            if (edit_len == 0) { printf("\n"); return 0; }
            edit_delete();
        } else if (c == 127 || c == 8) {       /* Backspace */
            edit_backspace();
        } else if (c == 27) {                  /* Escape sequence */
            char seq[2];
            if (read(STDIN_FILENO, &seq[0], 1) != 1) { refresh_line(prompt); continue; }
            if (read(STDIN_FILENO, &seq[1], 1) != 1) { refresh_line(prompt); continue; }
            if (seq[0] == '[') {
                if (seq[1] == 'A')      edit_hist_prev();
                else if (seq[1] == 'B') edit_hist_next();
                else if (seq[1] == 'C') edit_move_right();
                else if (seq[1] == 'D') edit_move_left();
                else if (seq[1] == 'H') edit_move_home();
                else if (seq[1] == 'F') edit_move_end();
                else if (seq[1] == '3') {
                    char t;
                    if (read(STDIN_FILENO, &t, 1) == 1 && t == '~')
                        edit_delete();
                }
            }
        } else if (c >= 32 && c < 127) {       /* printable ASCII */
            edit_insert(c);
        }
        /* other control chars ignored */

        refresh_line(prompt);
    }

    snprintf(buf, cap, "%s", edit_buf);
    return 1;
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

/* ---------------------------------------------------------------- */
/*  one command segment in a pipeline                                 */

struct cmdseg {
    char **argv;     /* owned copy, NULL-terminated */
    char *in;        /* < file name, or NULL */
    char *out;       /* > / >> file name, or NULL */
    int append;
};

static int count_argv(char **av) {
    int n = 0;
    while (av[n]) n++;
    return n;
}

static void free_cmds(struct cmdseg *cmds, int n) {
    for (int i = 0; i < n; i++) free(cmds[i].argv);
    free(cmds);
}

/* Turn tokenized argv into segments, catching pipes and redirects. */
static int parse_line(char **argv, int n, struct cmdseg **out, int *nsegs) {
    int pipes = 0;
    for (int i = 0; i < n; i++)
        if (!strcmp(argv[i], "|")) pipes++;

    struct cmdseg *cmds = calloc((size_t)(pipes + 1), sizeof(*cmds));
    if (!cmds) { perror("malloc"); return -1; }

    int cur = 0;
    char **tokens = NULL;
    int tn = 0, tc = 0;

    for (int i = 0; i < n; i++) {
        const char *t = argv[i];
        if (!strcmp(t, "|")) {
            if (tn == 0) {
                fprintf(stderr, "copper-sh: no command before '|'\n");
                free_cmds(cmds, cur + 1);
                return -1;
            }
            cmds[cur].argv = malloc((size_t)(tn + 1) * sizeof(char *));
            if (!cmds[cur].argv) { perror("malloc"); free_cmds(cmds, cur + 1); return -1; }
            memcpy(cmds[cur].argv, tokens, (size_t)tn * sizeof(char *));
            cmds[cur].argv[tn] = NULL;
            free(tokens);
            tokens = NULL;
            tn = tc = 0;
            cur++;
        } else if (!strcmp(t, "<")) {
            if (i + 1 >= n) { fprintf(stderr, "copper-sh: file name missing after '<'\n"); free_cmds(cmds, cur + 1); return -1; }
            if (cmds[cur].in) { fprintf(stderr, "copper-sh: only one '<' per command\n"); free_cmds(cmds, cur + 1); return -1; }
            cmds[cur].in = argv[++i];
        } else if (!strcmp(t, ">") || !strcmp(t, ">>")) {
            if (i + 1 >= n) { fprintf(stderr, "copper-sh: file name missing after '%s'\n", t); free_cmds(cmds, cur + 1); return -1; }
            if (cmds[cur].out) { fprintf(stderr, "copper-sh: only one '>' per command\n"); free_cmds(cmds, cur + 1); return -1; }
            cmds[cur].out = argv[++i];
            cmds[cur].append = (t[1] == '>');
        } else {
            if (tn == tc) {
                tc = tc ? tc * 2 : 8;
                char **nt = realloc(tokens, (size_t)tc * sizeof(char *));
                if (!nt) { fprintf(stderr, "malloc: out of memory\n"); free_cmds(cmds, cur + 1); return -1; }
                tokens = nt;
            }
            tokens[tn++] = argv[i];
        }
    }

    cmds[cur].argv = malloc((size_t)(tn + 1) * sizeof(char *));
    if (!cmds[cur].argv) { perror("malloc"); free_cmds(cmds, cur + 1); return -1; }
    if (tn > 0) memcpy(cmds[cur].argv, tokens, (size_t)tn * sizeof(char *));
    cmds[cur].argv[tn] = NULL;
    free(tokens);

    *out = cmds;
    *nsegs = cur + 1;
    return 0;
}

/* Run one command (builtin or external) in the current process. */
static int run_one(char **av) {
    const struct builtin *b = builtin_lookup(av[0]);
    if (b) return b->fn(count_argv(av), av);
    execvp(av[0], av);
    fprintf(stderr, "copper-sh: %s: command not found\n", av[0]);
    return 127;
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

static int status_of(int st) {
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return 128 + (WTERMSIG(st) & 0x7f);
}

/* Run the parsed line: plain commands in-process, pipelines via fork. */
static int run_segments(struct cmdseg *cmds, int n) {
    /* plain single command: keep it in-process so cd/history work */
    if (n == 1 && !cmds[0].in && !cmds[0].out) {
        const struct builtin *b = builtin_lookup(cmds[0].argv[0]);
        if (b) return b->fn(count_argv(cmds[0].argv), cmds[0].argv);
        run_external(cmds[0].argv);
        return 0;
    }

    int (*pipesd)[2] = NULL;
    if (n > 1) {
        pipesd = malloc((size_t)(n - 1) * sizeof(*pipesd));
        if (!pipesd) { perror("malloc"); return 1; }
        for (int k = 0; k < n - 1; k++)
            if (pipe(pipesd[k])) { perror("copper-sh: pipe"); free(pipesd); return 1; }
    }

    if (n < 1) { free(pipesd); return 0; }

    pid_t *pids = calloc((size_t)n, sizeof(pid_t));
    if (!pids) { perror("malloc"); free(pipesd); return 1; }

    for (int s = 0; s < n; s++) {
        pid_t pid = fork();
        if (pid < 0) { perror("copper-sh: fork"); break; }
        if (pid == 0) {
            int src = s > 0 ? pipesd[s - 1][0] : 0;
            int dst = s + 1 < n ? pipesd[s][1] : 1;

            if (cmds[s].in) {
                int fd = open(cmds[s].in, O_RDONLY);
                if (fd < 0) { perror(cmds[s].in); _exit(1); }
                src = fd;
            }
            if (s + 1 == n && cmds[s].out) {
                int flags = O_WRONLY | O_CREAT | (cmds[s].append ? O_APPEND : O_TRUNC);
                int fd = open(cmds[s].out, flags, 0666);
                if (fd < 0) { perror(cmds[s].out); _exit(1); }
                dst = fd;
            }

            /* close every pipe end we didn't keep as our stdio */
            if (pipesd)
                for (int k = 0; k < n - 1; k++) {
                    if (pipesd[k][0] != src) close(pipesd[k][0]);
                    if (pipesd[k][1] != dst) close(pipesd[k][1]);
                }
            fflush(NULL);              /* flush any inherited stdout ahead of us */
            if (src != 0) {
                dup2(src, 0);
                freopen(NULL, "r", stdin);   /* drop the parent's stdio read-ahead */
            }
            if (dst != 1) dup2(dst, 1);
            if (src > 1) close(src);
            if (dst > 1) close(dst);

            signal(SIGINT, SIG_DFL);
            int rc = run_one(cmds[s].argv);
            fflush(NULL);              /* _exit skips stdio flush */
            _exit(rc);
        }
        pids[s] = pid;
    }

    if (pipesd) {
        for (int k = 0; k < n - 1; k++) {
            close(pipesd[k][0]);
            close(pipesd[k][1]);
        }
        free(pipesd);
    }

    int last = 0;
    for (int s = 0; s < n; s++) {
        if (pids[s] > 0) {
            int st = 0;
            waitpid(pids[s], &st, 0);
            if (s == n - 1) last = status_of(st);
        }
    }
    free(pids);
    return last;
}

/* ---------------------------------------------------------------- */

int b_help(int argc, char **argv) {
    (void)argc; (void)argv;
    puts("copper-sh builtins:");
    for (const struct builtin *b = btable; b->name; b++)
        printf("  %-10s %s\n", b->name, b->desc);
    puts("");
    puts("pipes (|) and redirects (<, >, >>) work too.");
    puts("anything else runs as an external command (vi, top...)");
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
    signal(SIGINT, SIG_IGN);             /* ctrl-c must not kill the shell */
    banner();

    if (enable_raw_mode() == 0)
        atexit(disable_raw_mode);

    while (1) {
        char cwd[PATH_MAX];
        char prompt[PATH_MAX + 64];
        snprintf(prompt, sizeof prompt, "copper@copper:%s$ ",
                 short_pwd(cwd, sizeof cwd));

        char *line = malloc(EDIT_BUF_SIZE);
        if (!line) { perror("malloc"); break; }

        if (!read_line_edited(line, EDIT_BUF_SIZE, prompt)) {
            free(line);
            break;
        }

        /* session history (the raw line, like any other shell) */
        if (line[0]) {
            if (hist_n < HIST_MAX) {
                hist[hist_n++] = strdup(line);
            } else {
                free(hist[0]);
                memmove(hist, hist + 1, (HIST_MAX - 1) * sizeof(*hist));
                hist[HIST_MAX - 1] = strdup(line);
            }
        }

        int argc;
        char **argv = tokenize_line(line, &argc);
        if (argc == 0) { free(line); continue; }

        struct cmdseg *cmds = NULL;
        int nsegs = 0;
        if (parse_line(argv, argc, &cmds, &nsegs) != 0) { free(line); continue; }

        int bye = 0;
        if (nsegs == 1 && !cmds[0].in && !cmds[0].out &&
            (!strcmp(cmds[0].argv[0], "exit") || !strcmp(cmds[0].argv[0], "quit")))
            bye = 1;

        run_segments(cmds, nsegs);
        free_cmds(cmds, nsegs);

        if (bye) { free(line); break; }
        free(line);
    }

    for (int i = 0; i < hist_n; i++) free(hist[i]);
    return 0;
}
