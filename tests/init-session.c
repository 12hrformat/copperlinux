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

    /* ------------------------------------------------- the desktop marker */
    /* chose_hyprland() decides which launcher the boot hint names. It must be
       conservative: only the exact word "hyprland" selects Hyprland, and
       anything else -- missing file, empty file, a stray word, a half-written
       line -- means XFCE, the desktop that is always present. */
    {
        static const struct { const char *text; int want; } cases[] = {
            { "hyprland\n",   1 },
            { "hyprland",     1 },
            { "hyprland\r\n", 1 },
            { "xfce\n",       0 },
            { "\n",           0 },
            { "",             0 },
            { "hyprland2",    0 },
            { " Hyprland\n",  0 },   /* no trimming: exact word only */
            { "Hyprland\n",   0 },   /* case matters */
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            put(marker, cases[i].text);
            int got = chose_hyprland(marker);
            if (got == cases[i].want) {
                printf("ok   chose_hyprland(%s) -> %s\n",
                       cases[i].text[0] ? cases[i].text : "(empty)",
                       got ? "hyprland" : "xfce");
            } else {
                printf("FAIL chose_hyprland(%s) gave %d, wanted %d\n",
                       cases[i].text, got, cases[i].want);
                fails++;
            }
        }
        unlink(marker);
        if (chose_hyprland(marker) == 0) {
            printf("ok   a missing marker means XFCE\n");
        } else {
            printf("FAIL a missing marker means XFCE\n");
            fails++;
        }
    }

    /* ------------------------------------------------- the libudev records */
    /* Hyprland gets its keyboard and pointer from libinput, and libinput drops
       every device libudev calls uninitialized. With no udev daemon in the
       image nothing ever writes the record that clears that flag, so
       seed_udev_input_db writes it by hand. Point it at a fake
       /sys/class/input and check the one thing that matters: the file name and
       the I: line libudev reads. */
    {
        char base[] = "/tmp/copper-init-input-XXXXXX";
        char *dir = mkdtemp(base);
        if (!dir) {
            printf("FAIL mkdtemp: %s\n", strerror(errno));
            fails++;
        } else {
            char sysdir[256], dbdir[256], p[320];
            snprintf(sysdir, sizeof sysdir, "%s/input", dir);
            snprintf(dbdir, sizeof dbdir, "%s/data", dir);
            mkdir(sysdir, 0755);
            mkdir(dbdir, 0755);

            /* Two event nodes, and one that is not: the joystick node must be
               skipped, because libinput only ever looks at event*. */
            snprintf(p, sizeof p, "%s/event3", sysdir); mkdir(p, 0755);
            snprintf(p, sizeof p, "%s/event3/dev", sysdir); put(p, "13:67\n");
            snprintf(p, sizeof p, "%s/event4", sysdir); mkdir(p, 0755);
            snprintf(p, sizeof p, "%s/event4/dev", sysdir); put(p, "13:68\n");
            snprintf(p, sizeof p, "%s/js0", sysdir); mkdir(p, 0755);
            snprintf(p, sizeof p, "%s/js0/dev", sysdir); put(p, "13:0\n");

            int n = seed_udev_input_db(sysdir, dbdir);
            if (n == 2) {
                printf("ok   one record per event node, and only event nodes\n");
            } else {
                printf("FAIL wrote %d records, wanted 2\n", n);
                fails++;
            }

            char buf[256] = "";
            snprintf(p, sizeof p, "%s/c13:67", dbdir);
            FILE *f = fopen(p, "r");
            if (f) {
                size_t r = fread(buf, 1, sizeof buf - 1, f);
                buf[r] = '\0';
                fclose(f);
            }
            if (strstr(buf, "I:") == buf) {
                printf("ok   the record is named c<major>:<minor> and opens with I:\n");
            } else {
                printf("FAIL the record name or I: line is wrong (got '%s')\n", buf);
                fails++;
            }
            unlink(p);

            snprintf(p, sizeof p, "%s/c13:0", dbdir);
            if (access(p, F_OK) != 0) {
                printf("ok   a non-event node gets no record\n");
            } else {
                printf("FAIL a non-event node got a record\n");
                fails++;
            }

            snprintf(p, sizeof p, "%s/c13:68", dbdir); unlink(p);
            snprintf(p, sizeof p, "%s/event3/dev", sysdir); unlink(p);
            snprintf(p, sizeof p, "%s/event3", sysdir); rmdir(p);
            snprintf(p, sizeof p, "%s/event4/dev", sysdir); unlink(p);
            snprintf(p, sizeof p, "%s/event4", sysdir); rmdir(p);
            snprintf(p, sizeof p, "%s/js0/dev", sysdir); unlink(p);
            snprintf(p, sizeof p, "%s/js0", sysdir); rmdir(p);
            rmdir(dbdir);
            rmdir(sysdir);
            rmdir(dir);
        }
    }

    /* ------------------------------------------------------ power signals */
    /* The mapping the busybox halt/poweroff/reboot applets rely on. If these
       ever swap, `sudo reboot` powers the machine off instead of restarting
       it. power_how() is separate from the handler precisely so this can be
       checked without calling reboot(2) on the test machine (bug 18). */
    if (power_how(SIGTERM) == RB_AUTOBOOT) {
        printf("ok   SIGTERM maps to reboot\n");
    } else {
        printf("FAIL SIGTERM maps to reboot\n");
        fails++;
    }
    if (power_how(SIGUSR2) == RB_POWER_OFF) {
        printf("ok   SIGUSR2 maps to poweroff\n");
    } else {
        printf("FAIL SIGUSR2 maps to poweroff\n");
        fails++;
    }
    if (power_how(SIGUSR1) == RB_HALT_SYSTEM) {
        printf("ok   SIGUSR1 maps to halt\n");
    } else {
        printf("FAIL SIGUSR1 maps to halt\n");
        fails++;
    }
    /* Ctrl-Alt-Del arrives as SIGINT. Every other init reboots on it, and this
       one used to ignore it outright, which is how a wedged compositor left the
       keyboard with no escape at all. */
    if (power_how(SIGINT) == RB_AUTOBOOT) {
        printf("ok   SIGINT (ctrl-alt-del) maps to reboot\n");
    } else {
        printf("FAIL SIGINT (ctrl-alt-del) maps to reboot\n");
        fails++;
    }

    if (fails) {
        printf("%d check(s) failed\n", fails);
        return 1;
    }
    printf("session privileges: all good\n");
    return 0;
}
