/* Unit test for the session-account logic in iso/src-init/copper-init.c.
 *
 * Why this exists
 * ---------------
 * On a real Copper boot the shell ran as uid 0 while HOME said
 * /home/<user>, and Firefox refused to start on exactly that mismatch:
 *
 *     Running Firefox as root in a regular user's session is not supported.
 *
 * The fix reads the wizard's login name out of /etc/copper-firstboot.done and
 * drops the tty child to that account. A C function that reads a file and a C
 * function that calls setuid are both easy to get subtly wrong, and there is
 * no way to boot the whole ISO in CI. So the two functions are compiled here
 * on their own -- copper-init.c is #included, main and all, with main renamed
 * out of the way -- and the drop is exercised in a forked child, which is
 * where it actually happens.
 *
 * The account used is whatever this machine already has (nobody, or daemon, or
 * bin): the test never creates one, so running it does not touch the host's
 * account database. Run as root, because setuid to somebody else requires it.
 *
 * tests/init-session.sh compiles and runs this.
 */

#define main copper_init_main
#include "copper-init.c"
#undef main

static int fails;

static void ok(const char *what) { printf("ok   %s\n", what); }
static void bad(const char *what) { printf("FAIL %s\n", what); fails++; }

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(text, f);
    fclose(f);
}

int main(void) {
    /* An account that certainly exists, so the test never touches the account
       database. The wizard's own user cannot be used: it only exists after a
       wizard run and that is what we are avoiding. */
    static const char *cands[] = { "nobody", "daemon", "bin", NULL };
    struct passwd *pw = NULL;
    const char *name = NULL;
    for (int i = 0; cands[i]; i++) {
        pw = getpwnam(cands[i]);
        if (pw) { name = cands[i]; break; }
    }
    if (!pw) {
        printf("FAIL none of nobody/daemon/bin exists on this machine\n");
        return 1;
    }

    char marker[] = "/tmp/copper-init-marker-XXXXXX";
    int fd = mkstemp(marker);
    if (fd < 0) {
        printf("FAIL mkstemp: %s\n", strerror(errno));
        return 1;
    }
    dprintf(fd, "%s\nIgnored Display Name\n", name);
    close(fd);

    /* ------------------------------------------------- the marker read */
    struct session s;
    if (session_from_marker(marker, &s)) {
        printf("ok   session_from_marker accepts the marker\n");
    } else {
        printf("FAIL session_from_marker accepts the marker\n");
        fails++;
    }
    if (s.ok && strcmp(s.name, name) == 0) {
        printf("ok   it reads the login name from the first line\n");
    } else {
        printf("FAIL it reads the login name from the first line (got '%s')\n",
               s.name);
        fails++;
    }
    if (s.uid == pw->pw_uid && s.gid == pw->pw_gid) {
        printf("ok   it resolves uid/gid through getpwnam\n");
    } else {
        printf("FAIL it resolves uid/gid through getpwnam\n");
        fails++;
    }
    if (strcmp(s.home, pw->pw_dir) == 0) {
        printf("ok   it takes the home directory from the account\n");
    } else {
        printf("FAIL it takes the home directory from the account (got '%s')\n",
               s.home);
        fails++;
    }
    unlink(marker);

    /* ------------------------------------------- the two root sessions */
    struct session n;
    if (!session_from_marker(marker, &n)) {
        printf("ok   no marker -> no session user (first boot stays root)\n");
    } else {
        printf("FAIL no marker -> no session user (first boot stays root)\n");
        fails++;
    }

    fd = open(marker, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        printf("FAIL open marker: %s\n", strerror(errno));
        return 1;
    }
    dprintf(fd, "copper-no-such-account-xyz\n");
    close(fd);
    if (!session_from_marker(marker, &n)) {
        printf("ok   a marker naming a missing account stays root\n");
    } else {
        printf("FAIL a marker naming a missing account stays root\n");
        fails++;
    }
    unlink(marker);

    /* -------------------------------------------------- the actual drop */
    if (s.ok) {
        pid_t pid = fork();
        if (pid == 0) {
            drop_to_session(&s);
            if (getuid() != s.uid || geteuid() != s.uid)        _exit(11);
            if (getgid() != s.gid || getegid() != s.gid)        _exit(12);
            const char *h = getenv("HOME");
            if (!h || strcmp(h, s.home) != 0)                   _exit(13);
            const char *u = getenv("USER");
            if (!u || strcmp(u, name) != 0)                     _exit(14);
            const char *l = getenv("LOGNAME");
            if (!l || strcmp(l, name) != 0)                     _exit(15);
            _exit(0);
        }
        int st = 0;
        if (pid > 0) waitpid(pid, &st, 0);
        if (pid > 0 && WIFEXITED(st) && WEXITSTATUS(st) == 0) {
            printf("ok   drop_to_session lands the child on the session user\n");
        } else {
            printf("FAIL drop_to_session lands the child on the session user "
                   "(exit %d)\n", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
            fails++;
        }
    }

    if (fails) {
        printf("%d check(s) failed\n", fails);
        return 1;
    }
    printf("session privileges: all good\n");
    return 0;
}
