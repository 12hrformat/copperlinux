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

/* Read a whole file into buf, or "" when it is not there. */
static void slurp(const char *path, char *buf, size_t bufsz) {
    buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    size_t r = fread(buf, 1, bufsz - 1, f);
    buf[r] = '\0';
    fclose(f);
}

/* Run print_welcome(os_release_path) in a forked child with stdout on a
   pipe and read back what it printed. Returns the byte count, or -1 when
   the plumbing itself failed (a plumbing failure is the gate's, not the
   init's). The child _exits rather than returning, so what it printed has
   to have been flushed -- which print_welcome does itself, on purpose: the
   real caller hands it a tty, and a banner still sitting in a stdio buffer
   at spawn time would lose the race with the shell that follows it. */
static int capture_welcome(const char *os_release_path, char *out, size_t cap) {
    int pfd[2];
    if (pipe(pfd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        /* The parent has an unflushed stdio buffer here (stdout to a pipe is
           fully buffered and nothing has flushed since the ok lines). The
           child inherits it and print_welcome's own fflush would flush the
           inherited bytes first -- so clear the buffer before writing. */
        fflush(NULL);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[0]);
        close(pfd[1]);
        print_welcome(os_release_path);
        _exit(0);
    }
    close(pfd[1]);
    ssize_t r = read(pfd[0], out, cap - 1);
    int n = r >= 0 ? (int)r : -1;
    close(pfd[0]);
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) { }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) return -1;
    if (n >= 0) out[n] = '\0';
    return n;
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

    /* --------------------------------- the system bus's service accounts */
    /* dbus-daemon --system refuses to start without the messagebus account
       its system.conf names, and polkitd drops to polkitd. The package
       postinsts that would create them do not run in this build, so
       copper-init writes the records itself on images that lost them. The
       writer takes the database paths as arguments, which is what lets this
       run against a fixture instead of the host's /etc. */
    char adir[] = "/tmp/copper-init-acct-XXXXXX";
    if (!mkdtemp(adir)) {
        printf("FAIL mkdtemp for the account fixture: %s\n", strerror(errno));
        fails++;
    } else {
        char pwp[320], grp[320], before[1024], after[1024];
        snprintf(pwp, sizeof pwp, "%s/passwd", adir);
        snprintf(grp, sizeof grp, "%s/group", adir);

        /* A bare database: both records are missing and must be made. */
        put(pwp, "root:x:0:0:root:/root:/bin/sh\n");
        put(grp, "root:x:0:\n");
        int r = ensure_system_user(pwp, grp, "messagebus",
                                   "/nonexistent", "/bin/false");
        int gid = -1, uid = -1, pgid = -1;
        slurp(pwp, after, sizeof after);
        char *line = strstr(after, "messagebus:x:");
        if (line)
            sscanf(line, "messagebus:x:%d:%d:", &uid, &pgid);
        if (r == 1 && file_group_id(grp, "messagebus", &gid) && line
            && uid == gid && pgid == gid && uid > 100 && uid < 1000
            && strstr(line, ":/nonexistent:/bin/false") != NULL) {
            printf("ok   a missing service account is created with its own group\n");
        } else {
            printf("FAIL a missing service account is created with its own "
                   "group (rc %d, uid %d, gid %d, passwd gid %d)\n",
                   r, uid, gid, pgid);
            fails++;
        }

        /* Calling it again must change nothing. Boot runs this every time. */
        slurp(pwp, before, sizeof before);
        r = ensure_system_user(pwp, grp, "messagebus",
                               "/nonexistent", "/bin/false");
        slurp(pwp, after, sizeof after);
        if (r == 0 && strcmp(before, after) == 0) {
            printf("ok   an existing service account is left byte-for-byte alone\n");
        } else {
            printf("FAIL an existing service account is left byte-for-byte "
                   "alone (rc %d)\n", r);
            fails++;
        }

        /* An account whose group arrived from a package keeps that gid. The
           passwd record is the missing half here, and the gid must not be
           reallocated: polkit's rules.d ownership is pinned to it. */
        put(pwp, "root:x:0:0:root:/root:/bin/sh\n");
        put(grp, "root:x:0:\npolkitd:x:4242:\n");
        r = ensure_system_user(pwp, grp, "polkitd",
                               "/nonexistent", "/bin/false");
        slurp(pwp, after, sizeof after);
        line = strstr(after, "polkitd:x:");
        pgid = -1;
        if (line)
            sscanf(line, "polkitd:x:%*d:%d:", &pgid);
        if (r == 1 && pgid == 4242
            && file_group_id(grp, "polkitd", &gid) && gid == 4242) {
            printf("ok   an existing group's gid is reused, not reallocated\n");
        } else {
            printf("FAIL an existing group's gid is reused, not reallocated "
                   "(rc %d, passwd gid %d, group gid %d)\n", r, pgid, gid);
            fails++;
        }

        /* Ids already in either file are never handed out twice. */
        put(pwp, "root:x:0:0:root:/root:/bin/sh\nfoo:x:999:999::/:/bin/false\n");
        put(grp, "root:x:0:\nfoo:x:999:\n");
        r = ensure_system_user(pwp, grp, "messagebus",
                               "/nonexistent", "/bin/false");
        gid = uid = -1;
        slurp(pwp, after, sizeof after);
        line = strstr(after, "messagebus:x:");
        if (line)
            sscanf(line, "messagebus:x:%d:%d:", &uid, &pgid);
        if (r == 1 && uid < 999 && gid < 999 && uid == pgid) {
            printf("ok   a service account never takes an id already in use\n");
        } else {
            printf("FAIL a service account never takes an id already in use "
                   "(rc %d, uid %d, gid %d)\n", r, uid, gid);
            fails++;
        }

        rmtree(adir);
    }

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

    /* ------------------------------------------- the controlling terminal */
    /* `sudo` on the console asked for a password it could not read: "a
       terminal is required to read the password". The shell had stdin and
       stdout on tty1 but no controlling terminal: under systemd,
       copper-console.service's StandardInput=tty has already given tty1 to the
       service's session, so the child's setsid() + TIOCSCTTY(0) answers EPERM
       and /dev/tty cannot be opened at all. acquire_ctty() steals the tty in
       that case. A pty stands in for tty1; one child holds the slave the way
       the service does, and a second does what spawn_tty() does. The control
       child proves the fixture really is the bug -- a plain TIOCSCTTY(0) must
       be refused -- so the fixed child passing means something. */
    {
        int master = posix_openpt(O_RDWR | O_NOCTTY);
        if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
            printf("FAIL a pty for the controlling-terminal test: %s\n",
                   strerror(errno));
            fails++;
        } else {
            char slave[64];
            snprintf(slave, sizeof slave, "%s", ptsname(master));

            int ready[2], wake[2];
            if (pipe(ready) != 0 || pipe(wake) != 0) {
                printf("FAIL pipe: %s\n", strerror(errno));
                fails++;
            } else {
                /* The service's session, exactly as systemd leaves it. */
                pid_t holder = fork();
                if (holder == 0) {
                    close(ready[0]);
                    close(wake[1]);
                    if (setsid() < 0) _exit(20);
                    int hfd = open(slave, O_RDWR);
                    if (hfd < 0) _exit(21);
                    if (ioctl(hfd, TIOCSCTTY, 0) != 0) _exit(22);
                    if (write(ready[1], "R", 1) != 1) _exit(23);
                    char b;
                    (void)!read(wake[0], &b, 1);
                    _exit(0);
                }
                close(ready[1]);
                close(wake[0]);

                char r = 0;
                int held = holder > 0 && read(ready[0], &r, 1) == 1;
                close(ready[0]);
                if (!held) {
                    printf("FAIL the service-session fixture did not take the tty\n");
                    fails++;
                } else {
                    /* Control: the session that owns the tty refuses to give
                       it up to a plain TIOCSCTTY(0), which is the bug. */
                    pid_t control = fork();
                    if (control == 0) {
                        setsid();
                        int cfd = open(slave, O_RDWR);
                        if (cfd < 0) _exit(2);
                        errno = 0;
                        if (ioctl(cfd, TIOCSCTTY, 0) != -1 || errno != EPERM)
                            _exit(1);
                        _exit(0);
                    }
                    int cst = 0;
                    if (control > 0) waitpid(control, &cst, 0);
                    int c_exit = WIFEXITED(cst) ? WEXITSTATUS(cst) : -1;
                    if (control > 0 && c_exit == 0) {
                        printf("ok   the fixture denies a plain TIOCSCTTY(0)\n");
                    } else {
                        printf("FAIL the fixture does not reproduce the bug "
                               "(control exit %d)\n", c_exit);
                        fails++;
                    }

                    /* The shell, with the fix: it has to end up with a usable
                       /dev/tty, or sudo cannot prompt. */
                    pid_t shell = fork();
                    if (shell == 0) {
                        setsid();
                        int sfd = open(slave, O_RDWR);
                        if (sfd < 0) _exit(10);
                        acquire_ctty(sfd);
                        int t = open("/dev/tty", O_RDWR | O_NOCTTY);
                        if (t < 0) _exit(11);
                        close(t);
                        _exit(0);
                    }
                    int sst = 0;
                    if (shell > 0) waitpid(shell, &sst, 0);
                    int s_exit = WIFEXITED(sst) ? WEXITSTATUS(sst) : -1;
                    if (shell > 0 && s_exit == 0) {
                        printf("ok   acquire_ctty takes a tty another session owns\n");
                        printf("ok   the console shell keeps /dev/tty, so sudo can prompt\n");
                    } else if (s_exit == 11) {
                        printf("FAIL acquire_ctty ran but /dev/tty is still unusable\n");
                        fails++;
                    } else {
                        printf("FAIL acquire_ctty did not give the shell a tty "
                               "(exit %d)\n", s_exit);
                        fails++;
                    }
                }

                close(wake[1]);          /* let the fixture session go */
                if (holder > 0) waitpid(holder, NULL, 0);
                close(master);
            }
        }
    }

    /* ------------------------------------------------- the desktop marker */
    /* chose_niri() decides which launcher the boot hint names. It must be
       conservative: only the exact word "niri" selects niri, and anything else
       -- missing file, empty file, a stray word, a half-written line -- means
       XFCE, the desktop that is always present. */
    {
        static const struct { const char *text; int want; } cases[] = {
            { "niri\n",       1 },
            { "niri",         1 },
            { "niri\r\n",    1 },
            { "xfce\n",       0 },
            { "\n",           0 },
            { "",             0 },
            { "niri2",        0 },
            { " niri\n",      0 },   /* no trimming: exact word only */
            { "Niri\n",       0 },   /* case matters */
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            put(marker, cases[i].text);
            int got = chose_niri(marker);
            if (got == cases[i].want) {
                printf("ok   chose_niri(%s) -> %s\n",
                       cases[i].text[0] ? cases[i].text : "(empty)",
                       got ? "niri" : "xfce");
            } else {
                printf("FAIL chose_niri(%s) gave %d, wanted %d\n",
                       cases[i].text, got, cases[i].want);
                fails++;
            }
        }
        unlink(marker);
        if (chose_niri(marker) == 0) {
            printf("ok   a missing marker means XFCE\n");
        } else {
            printf("FAIL a missing marker means XFCE\n");
            fails++;
        }
    }

    /* --------------------------------------------------- the welcome banner */
    /* print_welcome() paints the tty the session is about to own: the clear,
       the welcome line, the startniri/startxfce hint, and -- gated on the
       image's own os-release -- the version. The hint used to go through
       say(), which under --console is serial-only diagnostic chatter, so the
       person at the screen never once saw it; these assertions pin the banner
       to stdout and pin what it says, including the version gate: a
       copper-init running somewhere that is not Copper must not report that
       machine's version as the image's. print_welcome takes the os-release
       path as its argument for exactly this fixture. */
    {
        char dir[] = "/tmp/copper-init-banner-XXXXXX";
        char *d = mkdtemp(dir);
        if (!d) {
            printf("FAIL mkdtemp: %s\n", strerror(errno));
            fails++;
        } else {
            char osr[320], out[512];
            snprintf(osr, sizeof osr, "%s/os-release", d);

            /* The image's own os-release, quoted values and all. */
            put(osr, "NAME=\"Copper Linux\"\n"
                     "ID=copper\n"
                     "VERSION_ID=\"1.2.0-alpha.1\"\n"
                     "PRETTY_NAME=\"Copper Linux 1.2.0-alpha.1\"\n");
            int n = capture_welcome(osr, out, sizeof out);
            if (n > 0 && memcmp(out, "\033[H\033[2J\033[3J", 9) == 0) {
                printf("ok   the banner clears the screen first, with the raw escape codes\n");
            } else {
                printf("FAIL the banner does not open with the clear sequence (n %d)\n", n);
                fails++;
            }
            if (n > 0 && strstr(out, "welcome to copper linux!") != NULL) {
                printf("ok   it says welcome to copper linux!\n");
            } else {
                printf("FAIL no welcome line (n %d)\n", n);
                fails++;
            }
            if (n > 0 && strstr(out, "type 'startniri' for niri and 'startxfce' for xfce") != NULL) {
                printf("ok   it names both desktop launchers\n");
            } else {
                printf("FAIL the startniri/startxfce hint is missing (n %d)\n", n);
                fails++;
            }
            if (n > 0 && strstr(out, "\nv1.2.0-alpha.1\n") != NULL) {
                printf("ok   the version line comes from os-release's VERSION_ID\n");
            } else {
                printf("FAIL no version line for a copper os-release (n %d)\n", n);
                fails++;
            }

            /* Not Copper: the version line must not appear at all. This is
               the gate the banner's own comment promises -- a build host or
               a chroot must not be reported as the image. */
            put(osr, "NAME=\"Debian GNU/Linux\"\nID=debian\nVERSION_ID=\"12\"\n");
            n = capture_welcome(osr, out, sizeof out);
            if (n > 0 && strstr(out, "\nv") == NULL) {
                printf("ok   a non-copper os-release prints no version line\n");
            } else {
                printf("FAIL a foreign os-release leaked a version line (n %d)\n", n);
                fails++;
            }

            /* Copper, but no VERSION_ID: the line is omitted, not guessed. */
            put(osr, "ID=copper\n");
            n = capture_welcome(osr, out, sizeof out);
            if (n > 0 && strstr(out, "\nv") == NULL) {
                printf("ok   a missing VERSION_ID omits the line rather than guessing\n");
            } else {
                printf("FAIL a missing VERSION_ID produced a version line (n %d)\n", n);
                fails++;
            }

            /* The parser itself, on the form the file also allows: an
               unquoted value, and a field that is simply not there. */
            put(osr, "ID=copper\nVERSION_ID=2.0\n");
            char v[64];
            os_release_field(osr, "VERSION_ID", v, sizeof v);
            if (strcmp(v, "2.0") == 0) {
                printf("ok   os_release_field reads an unquoted value\n");
            } else {
                printf("FAIL os_release_field read '%s' for an unquoted value\n", v);
                fails++;
            }
            os_release_field(osr, "VERSION_CODENAME", v, sizeof v);
            if (v[0] == '\0') {
                printf("ok   an absent field is an empty string\n");
            } else {
                printf("FAIL an absent field read '%s'\n", v);
                fails++;
            }
            os_release_field("/no/such/os-release-xyz", "ID", v, sizeof v);
            if (v[0] == '\0') {
                printf("ok   a missing file is an empty string\n");
            } else {
                printf("FAIL a missing file read '%s'\n", v);
                fails++;
            }

            rmtree(d);
        }
    }

    /* ------------------------------------------------- the libudev records */
    /* niri gets its keyboard and pointer from libinput, and libinput drops
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
