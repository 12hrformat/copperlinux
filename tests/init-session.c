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
/* reboot(2) is faked for this whole translation unit, so the failure-path
 * test can make it FAIL: a real reboot(2) here would reboot (or halt) the
 * machine the test runs on. copper-init.c's #include <sys/reboot.h> therefore
 * declares fake_reboot instead of reboot, and its one call site -- the power
 * handler -- calls it. The mapping tests below still use the RB_* macros,
 * which the macro does not touch.
 * updated by farcrowx, bug 33, tests/init-session.c */
#define reboot fake_reboot
#include "copper-init.c"
#undef reboot
#undef main

static int fails;

/* Matches the declaration sys/reboot.h left behind via the macro above.
 * Always fails: EPERM is what reboot(2) answers when it refuses. */
static int fake_reboot_how = -1;
int fake_reboot(int how) { fake_reboot_how = how; errno = EPERM; return -1; }

static void ok(const char *what) { printf("ok   %s\n", what); }
static void bad(const char *what) { printf("FAIL %s\n", what); fails++; }

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(text, f);
    fclose(f);
}

/* Create a directory and every parent above it. */
static void mkpath(const char *path) {
    char tmp[320];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p != '\0'; p++) {
        if (*p != '/') continue;
        *p = '\0';
        (void)mkdir(tmp, 0755);
        *p = '/';
    }
    (void)mkdir(tmp, 0755);
}

/* Write `text` to `dir`/`rel`, making `dir` and any parent it needs first. */
static void put_in(const char *dir, const char *rel, const char *text) {
    char path[320];
    snprintf(path, sizeof path, "%s/%s", dir, rel);
    char *slash = strrchr(path, '/');
    if (slash) {
        *slash = '\0';
        mkpath(path);
        *slash = '/';
    }
    put(path, text);
}

/* Delete a file, or a tree under it, ignoring what is not there. The fixture
   is three directories deep and the test's job is the assertions, not a tidy
   /tmp. */
static void rmtree(const char *path) {
    DIR *d = opendir(path);
    if (!d) {
        (void)unlink(path);
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char child[320];
        snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        rmtree(child);
    }
    closedir(d);
    (void)rmdir(path);
}

/* One fake input device, laid out the way sysfs lays one out: a directory
   named inputN under `sysdir` carrying its capability attributes, and its
   event node underneath, with the device number the record is named for. `event`
   of NULL is a device that has no event node, which is also a case worth
   having. `caps` is an attribute/contents table ending in two NULLs. */
static void fake_device(const char *sysdir, const char *name, const char *event,
                        const char *dev, const char *(*caps)[2]) {
    char rel[192];
    for (int i = 0; caps[i][0] != NULL; i++) {
        snprintf(rel, sizeof rel, "%s/capabilities/%s", name, caps[i][0]);
        put_in(sysdir, rel, caps[i][1]);
    }
    if (event == NULL) return;
    snprintf(rel, sizeof rel, "%s/%s/dev", name, event);
    put_in(sysdir, rel, dev);
}

/* The contents of one record, or "" when there is no such record. */
static void record_text(const char *dbdir, const char *dev, char *buf, size_t bufsz) {
    char path[320];
    snprintf(path, sizeof path, "%s/c%s", dbdir, dev);
    buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    size_t r = fread(buf, 1, bufsz - 1, f);
    buf[r] = '\0';
    fclose(f);
}

/* Does that record name a device type? A type is the underscore in
   E:ID_INPUT_KEYBOARD=1 and its fellows; E:ID_INPUT=1 alone is the record
   libinput reads and then throws the device away from. */
static int record_names_type(const char *dbdir, const char *dev) {
    char buf[512];
    record_text(dbdir, dev, buf, sizeof buf);
    return strstr(buf, "E:ID_INPUT_") != NULL;
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
       /sys/class/input and a database directory that does not exist yet --
       making that directory is the function's job, because the version that
       left it to the caller wrote nothing at all -- and check the file name
       and the I: line libudev reads.

       The record has to name a device type as well. libinput reads udev's
       ID_INPUT_* tags and discards any device whose only tag is ID_INPUT, so a
       record that says no more than before leaves the session exactly as dead
       as no record at all. The fixtures below are the bitmaps the kernel
       prints for a keyboard and a mouse, most significant word first, and the
       assertions are that each record names what its device is. */
    {
        char base[] = "/tmp/copper-init-input-XXXXXX";
        char *dir = mkdtemp(base);
        if (!dir) {
            printf("FAIL mkdtemp: %s\n", strerror(errno));
            fails++;
        } else {
            char sysdir[256], dbdir[256], p[320], buf[512];
            snprintf(sysdir, sizeof sysdir, "%s/input", dir);
            snprintf(dbdir, sizeof dbdir, "%s/data", dir);
            mkpath(sysdir);
            /* dbdir is deliberately not created: making it is the seeder's
               job, and the first version left that to the caller, so every
               write failed with ENOENT while the boot log read like a machine
               with no input devices at all. */

            /* A full keyboard: EV_SYN, EV_KEY, EV_MSC, EV_LED and EV_REP, and
               the first 32 keys, so udev's keyboard test finds ESC, the
               numbers and Q to D. */
            static const char *keyboard[][2] = {
                { "ev",  "120013" },
                { "key", "fffffffffffffffe" },
                { NULL, NULL },
            };
            /* A mouse: SYN, KEY and REL; REL_X and REL_Y; and BTN_LEFT to
               BTN_MIDDLE, which are bits 16-18 of the fifth word -- the word
               at the front, because the kernel prints these most significant
               first. */
            static const char *mouse[][2] = {
                { "ev",  "7" },
                { "rel", "3" },
                { "key", "70000 0 0 0 0" },
                { NULL, NULL },
            };
            /* An input device that earns no type: EV_SYN and nothing else. It
               still gets a record -- libudev wants one per event node -- but no
               type in it, which is the shape that left the session with a
               pointer that did not move and a keyboard that typed nowhere. */
            static const char *no_type[][2] = {
                { "ev", "1" },
                { NULL, NULL },
            };

            fake_device(sysdir, "input3", "event3", "13:67\n", keyboard);
            fake_device(sysdir, "input4", "event4", "13:68\n", mouse);
            fake_device(sysdir, "input5", "event5", "13:69\n", no_type);
            /* Capabilities but no event node: the record would have nothing to
               be named for, so no record is written. */
            fake_device(sysdir, "input6", NULL, NULL, keyboard);
            /* A class entry that is not an input device at all. */
            put_in(sysdir, "js0/dev", "13:0\n");

            int typed = -1;
            int n = seed_udev_input_db(sysdir, dbdir, &typed);
            if (n == 3) {
                printf("ok   one record per event node, and only event nodes\n");
            } else {
                printf("FAIL wrote %d records, wanted 3\n", n);
                fails++;
            }
            if (typed == 2) {
                printf("ok   it counts the records that name a device type\n");
            } else {
                printf("FAIL counted %d typed records, wanted 2\n", typed);
                fails++;
            }

            record_text(dbdir, "13:67", buf, sizeof buf);
            if (strstr(buf, "I:") == buf) {
                printf("ok   the record is named c<major>:<minor> and opens with I:\n");
            } else {
                printf("FAIL the record name or I: line is wrong (got '%s')\n", buf);
                fails++;
            }
            if (strstr(buf, "E:ID_INPUT=1\n") && strstr(buf, "E:ID_INPUT_KEY=1\n")) {
                printf("ok   the keyboard's record calls it a key device\n");
            } else {
                printf("FAIL the keyboard's record has no ID_INPUT_KEY (got '%s')\n", buf);
                fails++;
            }
            if (strstr(buf, "E:ID_INPUT_KEYBOARD=1\n")) {
                printf("ok   the keyboard's record calls it a keyboard\n");
            } else {
                printf("FAIL the keyboard's record has no ID_INPUT_KEYBOARD "
                       "(got '%s')\n", buf);
                fails++;
            }

            if (record_names_type(dbdir, "13:68")) {
                printf("ok   the mouse's record names a type\n");
            } else {
                printf("FAIL the mouse's record names no type\n");
                fails++;
            }
            record_text(dbdir, "13:68", buf, sizeof buf);
            if (strstr(buf, "E:ID_INPUT_MOUSE=1\n")) {
                printf("ok   and the type is ID_INPUT_MOUSE\n");
            } else {
                printf("FAIL the mouse is not a mouse (got '%s')\n", buf);
                fails++;
            }

            record_text(dbdir, "13:69", buf, sizeof buf);
            if (buf[0] != '\0' && strstr(buf, "E:ID_INPUT=1\n") && !strstr(buf, "E:ID_INPUT_")) {
                printf("ok   a device with no type still gets its record\n");
            } else {
                printf("FAIL a typeless device's record is wrong (got '%s')\n", buf);
                fails++;
            }

            snprintf(p, sizeof p, "%s/c13:0", dbdir);
            if (access(p, F_OK) != 0) {
                printf("ok   a non-event node gets no record\n");
            } else {
                printf("FAIL a non-event node got a record\n");
                fails++;
            }

            rmtree(sysdir);
            rmtree(dbdir);
            rmtree(dir);
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
#ifdef SIGPWR
    /* The ACPI power button lands as SIGPWR, and power_how()'s comment has
       promised "halt" for it since bug 18 -- but nothing asserted it, so the
       mapping shipped untested. Same stakes as the others: a swapped signal
       powers the machine off when it should stop, or vice versa. */
    if (power_how(SIGPWR) == RB_HALT_SYSTEM) {
        printf("ok   SIGPWR (power button) maps to halt\n");
    } else {
        printf("FAIL SIGPWR (power button) maps to halt\n");
        fails++;
    }
#endif

    /* ------------------------------------------------- the failure path */
    /* reboot(2) refusing must not take PID 1 down with it: the handler used
       to _exit(0), the kernel panicked "Attempted to kill init", and the
       reason was never printed (bug 33). It has to report on stderr (which
       main() points at /dev/console) and return, having applied the signal's
       action (SIGTERM -> RB_AUTOBOOT, checked through fake_reboot_how --
       which also proves the real reboot(2) was never reached: this test
       cannot power off the machine it runs on). */
    {
        int pfd[2];
        if (pipe(pfd) != 0) {
            printf("FAIL pipe: %s\n", strerror(errno));
            fails++;
        } else {
            pid_t pid = fork();
            if (pid == 0) {
                dup2(pfd[1], STDERR_FILENO);
                close(pfd[0]);
                close(pfd[1]);
                fake_reboot_how = -1;
                on_power_signal(SIGTERM);
                /* Reached only if the handler returned instead of
                   _exit()ing; 43 means it never even asked to reboot. */
                _exit(fake_reboot_how == RB_AUTOBOOT ? 42 : 43);
            }
            close(pfd[1]);
            char msg[256];
            ssize_t r = read(pfd[0], msg, sizeof msg - 1);
            if (r < 0) r = 0;
            msg[r] = '\0';
            close(pfd[0]);
            int st = 0;
            if (pid > 0) waitpid(pid, &st, 0);
            if (WIFEXITED(st) && WEXITSTATUS(st) == 42) {
                printf("ok   the handler returns when reboot(2) fails "
                       "(PID 1 would survive)\n");
            } else {
                printf("FAIL the handler must return when reboot(2) fails "
                       "(exit %d, signal %d)\n",
                       WIFEXITED(st) ? WEXITSTATUS(st) : -1,
                       WIFSIGNALED(st) ? WTERMSIG(st) : -1);
                fails++;
            }
            if (strstr(msg, "reboot(2) failed") != NULL) {
                printf("ok   it says why, on the console (stderr)\n");
            } else {
                printf("FAIL no failure message on stderr (got '%s')\n", msg);
                fails++;
            }
        }
    }

    if (fails) {
        printf("%d check(s) failed\n", fails);
        return 1;
    }
    printf("session privileges: all good\n");
    return 0;
}
