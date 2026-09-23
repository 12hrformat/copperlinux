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
#include <sys/stat.h>
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

    DIR *d = opendir(path);
    if (!d) { perror("ls"); return 1; }

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
        } else {
            if (!first) printf("  ");
            printf("%s", e->d_name);
            first = 0;
        }
    }
    closedir(d);
    if (!longfmt) printf("\n");
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

extern char **environ;

int b_env(int argc, char **argv) {
    (void)argc; (void)argv;
    for (char **e = environ; *e; e++) puts(*e);
    return 0;
}