/*
 * copper-sh — builtins: ls, pwd, cd, cat, echo and friends.
 * Nothing fancy, just the stuff a first boot really needs.
 */

#define _XOPEN_SOURCE 700   /* nftw / S_ISLNK / S_ISSOCK / environ are XSI */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <time.h>
#include <pwd.h>
#include <grp.h>
#include <utime.h>
#include <ftw.h>
#include <limits.h>
#include <regex.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>

#include "builtins.h"

static char prev_dir[PATH_MAX] = "";   /* remembered by "cd -" */

/* ---------------------------------------------------------------- */

int b_pwd(int argc, char **argv) {
    (void)argv;
    if (argc > 1) { fprintf(stderr, "pwd: too many args\n"); return 1; }
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) { perror("pwd"); return 1; }
    puts(cwd);
    return 0;
}

int b_cd(int argc, char **argv) {
    char cur[PATH_MAX];
    if (!getcwd(cur, sizeof cur)) { perror("cd"); return 1; }
    if (argc > 2) { fprintf(stderr, "cd: too many args\n"); return 1; }

    const char *dest;
    if (argc == 1 || !strcmp(argv[1], "~")) {
        dest = getenv("HOME");
        if (!dest) dest = "/";
    } else if (!strcmp(argv[1], "-")) {
        if (!prev_dir[0]) { fprintf(stderr, "cd: no previous directory yet\n"); return 1; }
        dest = prev_dir;
        puts(dest);                      /* show where you ended up, like bash */
    } else {
        dest = argv[1];
    }

    if (chdir(dest) != 0) { perror("cd"); return 1; }
    strncpy(prev_dir, cur, sizeof prev_dir - 1);
    prev_dir[sizeof prev_dir - 1] = '\0';
    return 0;
}

/* ---------------------------------------------------------------- */

static void modestr(mode_t m, char out[11]) {
    const char rwx[] = "rwxrwxrwx";
    out[0] = S_ISDIR(m) ? 'd' : S_ISLNK(m) ? 'l' : S_ISCHR(m) ? 'c'
           : S_ISBLK(m) ? 'b' : S_ISFIFO(m) ? 'p' : S_ISSOCK(m) ? 's' : '-';
    for (int i = 0; i < 9; i++)
        out[1 + i] = (m & (1u << (8 - i))) ? rwx[i] : '-';
    if (m & S_ISUID) out[3] = out[3] == 'x' ? 's' : 'S';
    if (m & S_ISGID) out[6] = out[6] == 'x' ? 's' : 'S';
    if (m & S_ISVTX) out[9] = out[9] == 'x' ? 't' : 'T';
    out[10] = '\0';
}

int b_ls(int argc, char **argv) {
    int hidden = 0, longfmt = 0;
    const char *path = ".";

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1]) {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 'a')      hidden = 1;
                else if (*f == 'l') longfmt = 1;
                else { fprintf(stderr, "ls: unknown option -%c\n", *f); return 1; }
            }
        } else {
            path = argv[i];
        }
    }

    /* a plain file argument: print it, not its contents */
    struct stat st0;
    if (stat(path, &st0) == 0 && !S_ISDIR(st0.st_mode)) {
        if (longfmt) {
            char m[11];
            modestr(st0.st_mode, m);
            struct passwd *pw = getpwuid(st0.st_uid);
            struct group *gr = getgrgid(st0.st_gid);
            char tbuf[32] = "";
            struct tm *tm = localtime(&st0.st_mtime);
            if (tm) strftime(tbuf, sizeof tbuf, "%b %d %H:%M", tm);
            const char *base = strrchr(path, '/');
            printf("%s %3lu %-8s %-8s %8ld %s %s\n",
                   m, (unsigned long)st0.st_nlink,
                   pw ? pw->pw_name : "?", gr ? gr->gr_name : "?",
                   (long)st0.st_size, tbuf, base ? base + 1 : path);
        } else {
            printf("%s\n", path);
        }
        return 0;
    }

    DIR *d = opendir(path);
    if (!d) { perror("ls"); return 1; }

    /* to a pipe or file, list one per line like the real thing */
    int one_line = !isatty(fileno(stdout));

    struct dirent *e;
    int first = 1;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (e->d_name[0] == '.' && !hidden) continue;

        if (longfmt) {
            char full[PATH_MAX];
            snprintf(full, sizeof full, "%s/%s", path, e->d_name);
            struct stat st;
            if (stat(full, &st)) { perror("ls"); continue; }
            char m[11];
            modestr(st.st_mode, m);
            struct passwd *pw = getpwuid(st.st_uid);
            struct group *gr = getgrgid(st.st_gid);
            char tbuf[32] = "";
            struct tm *tm = localtime(&st.st_mtime);
            if (tm) strftime(tbuf, sizeof tbuf, "%b %d %H:%M", tm);
            printf("%s %3lu %-8s %-8s %8ld %s %s\n",
                   m, (unsigned long)st.st_nlink,
                   pw ? pw->pw_name : "?", gr ? gr->gr_name : "?",
                   (long)st.st_size, tbuf, e->d_name);
        } else if (one_line) {
            puts(e->d_name);
        } else {
            if (!first) printf("  ");
            printf("%s", e->d_name);
            first = 0;
        }
    }
    closedir(d);
    if (!longfmt && !one_line) printf("\n");
    return 0;
}

/* ---------------------------------------------------------------- */

int b_cat(int argc, char **argv) {
    if (argc == 1) {                     /* cat with no args = echo stdin */
        char buf[4096];
        ssize_t n;
        while ((n = read(0, buf, sizeof buf)) > 0) write(1, buf, (size_t)n);
        return 0;
    }
    int rc = 0;
    for (int i = 1; i < argc; i++) {
        int fd = open(argv[i], O_RDONLY);
        if (fd < 0) { perror(argv[i]); rc = 1; continue; }
        char buf[4096];
        ssize_t n;
        while ((n = read(fd, buf, sizeof buf)) > 0) write(1, buf, (size_t)n);
        close(fd);
    }
    return rc;
}

int b_echo(int argc, char **argv) {
    int nl = 1, i = 1;
    if (i < argc && !strcmp(argv[i], "-n")) { nl = 0; i++; }
    int wrote = 0;
    for (; i < argc; i++) {
        if (wrote) putchar(' ');
        fputs(argv[i], stdout);
        wrote = 1;
    }
    if (nl) putchar('\n');
    return 0;
}

int b_clear(int argc, char **argv) {
    (void)argc; (void)argv;
    fputs("\033[H\033[2J", stdout);      /* ANSI clear */
    return 0;
}

int b_whoami(int argc, char **argv) {
    (void)argc; (void)argv;
    struct passwd *pw = getpwuid(getuid());
    puts(pw ? pw->pw_name : "unknown");
    return 0;
}

int b_uname(int argc, char **argv) {
    (void)argc; (void)argv;
    struct utsname u;
    if (uname(&u) != 0) { perror("uname"); return 1; }
    printf("%s %s %s %s %s\n", u.sysname, u.nodename, u.release, u.version, u.machine);
    return 0;
}

int b_date(int argc, char **argv) {
    (void)argc; (void)argv;
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    if (!tm) { perror("date"); return 1; }
    char buf[64];
    strftime(buf, sizeof buf, "%a %b %d %H:%M:%S %Z %Y", tm);
    puts(buf);
    return 0;
}

/* ---------------------------------------------------------------- */

int b_mkdir(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "mkdir: usage: mkdir DIR...\n"); return 1; }
    int rc = 0;
    for (int i = 1; i < argc; i++)
        if (mkdir(argv[i], 0755)) { perror(argv[i]); rc = 1; }
    return rc;
}

int b_rmdir(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "rmdir: usage: rmdir DIR...\n"); return 1; }
    int rc = 0;
    for (int i = 1; i < argc; i++)
        if (rmdir(argv[i])) { perror(argv[i]); rc = 1; }
    return rc;
}

int b_touch(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "touch: usage: touch FILE...\n"); return 1; }
    int rc = 0;
    for (int i = 1; i < argc; i++) {
        int fd = open(argv[i], O_CREAT | O_WRONLY, 0666);
        if (fd < 0) { perror(argv[i]); rc = 1; continue; }
        close(fd);
        if (utime(argv[i], NULL)) { perror(argv[i]); rc = 1; }
    }
    return rc;
}

static int rm_cb(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
    (void)st; (void)flag; (void)ftw;
    return remove(path);
}

int b_rm(int argc, char **argv) {
    int recursive = 0, i = 1;
    if (i < argc && argv[i][0] == '-' && strchr(argv[i], 'r')) {
        recursive = 1;
        i++;
    }
    if (i >= argc) {
        fprintf(stderr, "rm: usage: rm [-r] FILE...\n");
        return 1;
    }
    int rc = 0;
    for (; i < argc; i++) {
        if (recursive) {
            if (nftw(argv[i], rm_cb, 16, FTW_DEPTH | FTW_PHYS)) { perror(argv[i]); rc = 1; }
        } else if (unlink(argv[i])) {
            perror(argv[i]);
            rc = 1;
        }
    }
    return rc;
}

/* ---------------------------------------------------------------- */

static int copyfile(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) { perror(src); return 1; }
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (out < 0) { perror(dst); close(in); return 1; }
    char buf[8192];
    ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0) write(out, buf, (size_t)n);
    close(in);
    close(out);
    return 0;
}

int b_cp(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "cp: usage: cp SRC DST\n"); return 1; }
    return copyfile(argv[1], argv[2]);
}

int b_mv(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "mv: usage: mv SRC DST\n"); return 1; }
    if (rename(argv[1], argv[2]) == 0) return 0;
    if (errno == EXDEV) {                /* different filesystems: copy+delete */
        if (copyfile(argv[1], argv[2]) == 0) { unlink(argv[1]); return 0; }
    }
    perror("mv");
    return 1;
}

/* ---------------------------------------------------------------- */

static char *find_in_path(const char *cmd) {
    if (strchr(cmd, '/')) {
        return access(cmd, X_OK) == 0 ? strdup(cmd) : NULL;
    }
    const char *path = getenv("PATH");
    if (!path) return NULL;
    char *copy = strdup(path);
    char *save = NULL;
    for (char *dir = strtok_r(copy, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
        char full[PATH_MAX];
        snprintf(full, sizeof full, "%s/%s", dir, cmd);
        if (access(full, X_OK) == 0) {
            char *r = strdup(full);
            free(copy);
            return r;
        }
    }
    free(copy);
    return NULL;
}

int b_type(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "type: usage: type CMD\n"); return 1; }
    const struct builtin *b = builtin_lookup(argv[1]);
    if (b) {
        printf("%s is a copper-sh builtin (%s)\n", argv[1], b->desc);
        return 0;
    }
    char *p = find_in_path(argv[1]);
    if (p) {
        printf("%s is %s\n", argv[1], p);
        free(p);
        return 0;
    }
    fprintf(stderr, "type: %s: not found\n", argv[1]);
    return 1;
}

int b_which(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "which: usage: which CMD\n"); return 1; }
    char *p = find_in_path(argv[1]);
    if (!p) { fprintf(stderr, "which: %s: not found in PATH\n", argv[1]); return 1; }
    puts(p);
    free(p);
    return 0;
}

/* ---------------------------------------------------------------- */
/*  head / tail / wc / grep / tee                                     */

static void print_head(FILE *in, int n) {
    char *line = NULL;
    size_t cap = 0;
    while (n-- > 0) {
        ssize_t len = getline(&line, &cap, in);
        if (len < 0) break;
        fwrite(line, 1, (size_t)len, stdout);
    }
    free(line);
}

int b_head(int argc, char **argv) {
    int n = 10, i = 1;
    if (i < argc && !strcmp(argv[i], "-n")) {
        i++;
        if (i >= argc) { fprintf(stderr, "head: -n needs a number\n"); return 1; }
        n = atoi(argv[i++]);
    }
    if (n < 0) n = 0;
    if (i >= argc) { print_head(stdin, n); return 0; }
    int rc = 0;
    for (; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) { perror(argv[i]); rc = 1; continue; }
        print_head(f, n);
        fclose(f);
    }
    return rc;
}

/* rolling buffer holding the last n lines */
static void print_tail(FILE *in, int n) {
    if (n <= 0) return;
    char **ring = calloc((size_t)n, sizeof(char *));
    if (!ring) { perror("tail"); return; }
    int idx = 0, total = 0;
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    while ((len = getline(&line, &cap, in)) >= 0) {
        char *copy = strdup(line);
        if (!copy) break;
        free(ring[idx]);
        ring[idx] = copy;
        idx = (idx + 1) % n;
        total++;
    }
    free(line);
    int shown = total < n ? total : n;
    int start = total < n ? 0 : idx;
    for (int k = 0; k < shown; k++)
        fputs(ring[(start + k) % n], stdout);
    for (int k = 0; k < n; k++) free(ring[k]);
    free(ring);
}

int b_tail(int argc, char **argv) {
    int n = 10, i = 1;
    if (i < argc && !strcmp(argv[i], "-n")) {
        i++;
        if (i >= argc) { fprintf(stderr, "tail: -n needs a number\n"); return 1; }
        n = atoi(argv[i++]);
    }
    if (n < 0) n = 0;
    if (i >= argc) { print_tail(stdin, n); return 0; }
    int rc = 0;
    for (; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) { perror(argv[i]); rc = 1; continue; }
        print_tail(f, n);
        fclose(f);
    }
    return rc;
}

static void wc_count(FILE *in, long *lines, long *words, long *bytes) {
    int prevws = 1, c;
    while ((c = fgetc(in)) != EOF) {
        (*bytes)++;
        if (c == '\n') (*lines)++;
        int ws = (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f');
        if (ws) prevws = 1;
        else { if (prevws) (*words)++; prevws = 0; }
    }
}

static void wc_print(long l, long w, long b, int lf, int wf, int cf, const char *name) {
    if (lf) printf("%7ld ", l);
    if (wf) printf("%7ld ", w);
    if (cf) printf("%7ld ", b);
    if (name) printf("%s", name);
    printf("\n");
}

int b_wc(int argc, char **argv) {
    int lf = 0, wf = 0, cf = 0, i = 1;
    while (i < argc && argv[i][0] == '-' && argv[i][1]) {
        for (const char *f = argv[i] + 1; *f; f++) {
            if (*f == 'l') lf = 1;
            else if (*f == 'w') wf = 1;
            else if (*f == 'c') cf = 1;
            else { fprintf(stderr, "wc: unknown option -%c\n", *f); return 1; }
        }
        i++;
    }
    if (!lf && !wf && !cf) lf = wf = cf = 1;

    if (i >= argc) {
        long l = 0, w = 0, b = 0;
        wc_count(stdin, &l, &w, &b);
        wc_print(l, w, b, lf, wf, cf, NULL);
        return 0;
    }
    int rc = 0, multi = argc - i > 1;
    long tl = 0, tw = 0, tb = 0;
    for (; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) { perror(argv[i]); rc = 1; continue; }
        long l = 0, w = 0, b = 0;
        wc_count(f, &l, &w, &b);
        fclose(f);
        wc_print(l, w, b, lf, wf, cf, argv[i]);
        tl += l; tw += w; tb += b;
    }
    if (multi && !rc) wc_print(tl, tw, tb, lf, wf, cf, "total");
    return rc;
}

static int grep_feed(FILE *in, regex_t *re, int invert, int with_line, const char *name, int show_name) {
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    int ln = 0, hits = 0;
    while ((len = getline(&line, &cap, in)) >= 0) {
        ln++;
        int m = regexec(re, line, 0, NULL, 0) == 0;
        if (m != invert) {
            if (show_name) printf("%s:", name);
            if (with_line) printf("%d:", ln);
            fwrite(line, 1, (size_t)len, stdout);
            hits++;
        }
    }
    free(line);
    return hits;
}

int b_grep(int argc, char **argv) {
    int invert = 0, with_line = 0, icase = 0, i = 1;
    while (i < argc && argv[i][0] == '-' && argv[i][1]) {
        for (const char *f = argv[i] + 1; *f; f++) {
            if (*f == 'i') icase = 1;
            else if (*f == 'n') with_line = 1;
            else if (*f == 'v') invert = 1;
            else { fprintf(stderr, "grep: unknown option -%c\n", *f); return 2; }
        }
        i++;
    }
    if (i >= argc) { fprintf(stderr, "grep: usage: grep [-inv] PATTERN [FILE...]\n"); return 2; }
    const char *pat = argv[i++];
    regex_t re;
    int flags = REG_EXTENDED | (icase ? REG_ICASE : 0);
    if (regcomp(&re, pat, flags)) { fprintf(stderr, "grep: bad pattern\n"); return 2; }

    int rc = 0, hits = 0;
    if (i >= argc) {
        hits = grep_feed(stdin, &re, invert, with_line, "-", 0);
    } else {
        int multi = argc - i > 1;
        for (; i < argc; i++) {
            FILE *f = fopen(argv[i], "r");
            if (!f) { perror(argv[i]); rc = 1; continue; }
            hits += grep_feed(f, &re, invert, with_line, argv[i], multi);
            fclose(f);
        }
    }
    regfree(&re);
    return rc ? rc : (hits ? 0 : 1);
}

int b_tee(int argc, char **argv) {
    int append = 0, i = 1;
    if (i < argc && !strcmp(argv[i], "-a")) { append = 1; i++; }
    int nf = argc - i;
    FILE **outs = NULL;
    if (nf > 0) {
        outs = calloc((size_t)nf, sizeof(FILE *));
        if (!outs) { perror("tee"); return 1; }
    }
    int rc = 0;
    for (int k = 0; k < nf; k++) {
        outs[k] = fopen(argv[i + k], append ? "a" : "w");
        if (!outs[k]) { perror(argv[i + k]); rc = 1; }
    }
    char buf[4096];
    size_t nr;
    while ((nr = fread(buf, 1, sizeof buf, stdin)) > 0) {
        fwrite(buf, 1, nr, stdout);
        for (int k = 0; k < nf; k++)
            if (outs[k]) fwrite(buf, 1, nr, outs[k]);
    }
    for (int k = 0; k < nf; k++) if (outs[k]) fclose(outs[k]);
    free(outs);
    return rc;
}

/* ---------------------------------------------------------------- */
/*  misc utils: sleep, true, false, id, hostname, path helpers        */

int b_sleep(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "sleep: usage: sleep SECONDS\n"); return 1; }
    unsigned sec = (unsigned)strtoul(argv[1], NULL, 10);
    (void)sleep(sec);
    return 0;
}

int b_true(int argc, char **argv)  { (void)argc; (void)argv; return 0; }
int b_false(int argc, char **argv) { (void)argc; (void)argv; return 1; }

int b_id(int argc, char **argv) {
    (void)argc; (void)argv;
    struct passwd *pw = getpwuid(getuid());
    struct group *gr = getgrgid(getgid());
    printf("uid=%lu(%s) gid=%lu(%s)",
           (unsigned long)getuid(), pw ? pw->pw_name : "?",
           (unsigned long)getgid(), gr ? gr->gr_name : "?");
    gid_t grps[32];
    int ng = getgroups(32, grps);
    if (ng > 0) {
        printf(" groups=");
        for (int k = 0; k < ng; k++) {
            struct group *g2 = getgrgid(grps[k]);
            printf("%s%s", k ? "," : "", g2 ? g2->gr_name : "?");
        }
    }
    printf("\n");
    return 0;
}

int b_hostname(int argc, char **argv) {
    (void)argc; (void)argv;
    char hn[256];
    if (gethostname(hn, sizeof hn)) { perror("hostname"); return 1; }
    hn[sizeof hn - 1] = '\0';
    puts(hn);
    return 0;
}

int b_basename(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fprintf(stderr, "basename: usage: basename PATH [SUFFIX]\n"); return 1; }
    const char *slash = strrchr(argv[1], '/');
    const char *base = slash ? slash + 1 : argv[1];
    char out[PATH_MAX];
    snprintf(out, sizeof out, "%s", base);
    if (argc == 3) {
        size_t bl = strlen(out), sl = strlen(argv[2]);
        if (sl && bl > sl && !strcmp(out + bl - sl, argv[2]))
            out[bl - sl] = '\0';
    }
    puts(out);
    return 0;
}

int b_dirname(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "dirname: usage: dirname PATH\n"); return 1; }
    char copy[PATH_MAX];
    snprintf(copy, sizeof copy, "%s", argv[1]);
    if (!strcmp(copy, "/")) { puts("/"); return 0; }
    char *slash = strrchr(copy, '/');
    if (!slash) { puts("."); return 0; }
    if (slash == copy) { puts("/"); return 0; }
    *slash = '\0';
    puts(copy);
    return 0;
}

int b_ln(int argc, char **argv) {
    int sym = 0, i = 1;
    if (i < argc && !strcmp(argv[i], "-s")) { sym = 1; i++; }
    if (argc - i != 2) { fprintf(stderr, "ln: usage: ln [-s] TARGET LINK\n"); return 1; }
    int rc = sym ? symlink(argv[i], argv[i + 1]) : link(argv[i], argv[i + 1]);
    if (rc) { perror("ln"); return 1; }
    return 0;
}

int b_chmod(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "chmod: usage: chmod MODE FILE\n"); return 1; }
    long mode = strtol(argv[1], NULL, 8);
    if (chmod(argv[2], (mode_t)mode)) { perror(argv[2]); return 1; }
    return 0;
}

/* ---------------------------------------------------------------- */

extern char **environ;

int b_env(int argc, char **argv) {
    (void)argc; (void)argv;
    for (char **e = environ; *e; e++) puts(*e);
    return 0;
}