/*
 * copper-init — Copper Linux PID 1.
 *
 * No systemd, no init scripts: this IS the init. It mounts the basics
 * (the initramfs already did most of it), applies the hostname, brings the
 * network up, runs the first-boot wizard once, then parks a copper-sh login
 * shell on tty1 and keeps it alive.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <net/if.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E   /* stable Linux value, in case musl is shy */
#endif

static void console_stdio(void) {
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
}

static void mount_if_needed(const char *what, const char *where,
                            const char *type) {
    struct stat st;
    if (stat(where, &st) != 0 || !S_ISDIR(st.st_mode))
        mkdir(where, 0755);
    if (mount(what, where, type, 0, NULL) != 0 && errno != EBUSY)
        perror(where);
}

static void apply_hostname(void) {
    char host[128] = "copper";
    FILE *f = fopen("/etc/hostname", "r");
    if (f) {
        if (fgets(host, sizeof host, f))
            host[strcspn(host, "\r\n")] = '\0';
        fclose(f);
    }
    sethostname(host, strlen(host));
}

/* Boot chatter. Goes to the console everyone is already looking at, and to
   the serial port when the machine has one. Both, not either: /dev/console
   only ever points at one of them — whichever console= was last on the kernel
   command line — so writing to stdout alone means a quiet boot leaves a serial
   log completely empty, which is precisely when a log is most wanted. */
static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    int n;
    FILE *tty;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    printf("copper: %s\n", line);
    fflush(stdout);
    tty = fopen("/dev/ttyS0", "w");
    if (tty) {
        fprintf(tty, "copper: %s\n", line);
        fclose(tty);
    }
}

/* ARPHRD_* link-layer types, from linux/if_arp.h. Spelled out rather than
   included: this builds against musl, which does not ship the kernel UAPI
   headers, and two numbers are not worth a build dependency. */
#define ARPHRD_ETHER             1
#define ARPHRD_IEEE80211_RADIOTAP 801

/* Link-layer type of an interface, or -1 if it cannot be read.
   /sys/class/net/<if>/type is the ARPHRD_* value in decimal. */
static int iface_type(const char *ifname) {
    char path[64];
    char buf[32];
    FILE *f;
    long v;

    snprintf(path, sizeof path, "/sys/class/net/%s/type", ifname);
    f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, sizeof buf, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    v = strtol(buf, NULL, 10);
    if (v < 0 || v > 0xffff)
        return -1;
    return (int)v;
}

/* First interface worth handing to DHCP, or NULL.
   Not simply the first non-loopback name in the directory: with MODULES=n
   every driver is built in, and several of them invent an interface at boot
   before the real NIC has finished probing. The sit module's sit0 is one,
   and handing DHCP a tunnel means broadcasting discover into nowhere. So ask
   sysfs what the interface actually is, and only take something with a real
   link layer. Wired first, wireless second — a box with both should use the
   wire. */
static const char *first_nonloop_iface(void) {
    static const int prefs[] = { ARPHRD_ETHER, ARPHRD_IEEE80211_RADIOTAP };
    static char name[IFNAMSIZ];
    struct dirent *ent;
    DIR *dir;
    size_t pass;

    for (pass = 0; pass < sizeof prefs / sizeof prefs[0]; pass++) {
        dir = opendir("/sys/class/net");
        if (!dir)
            return NULL;
        while ((ent = readdir(dir)) != NULL) {
            size_t len = strlen(ent->d_name);
            /* d_name is far wider than an interface name, so anything that
               long is not one. */
            if (len == 0 || len >= sizeof name || ent->d_name[0] == '.')
                continue;
            if (iface_type(ent->d_name) != prefs[pass])
                continue;
            memcpy(name, ent->d_name, len + 1);
            closedir(dir);
            return name;
        }
        closedir(dir);
    }
    return NULL;
}

/* IFF_UP through ioctl: no subprocess, and no guessing where the build
   happened to install busybox's applet links. */
static int link_up(const char *ifname) {
    struct ifreq ifr;
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    int rc = 0;

    if (sock < 0)
        return -1;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", ifname);
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0)
        rc = -1;
    else {
        ifr.ifr_flags |= IFF_UP | IFF_BROADCAST;
        if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0)
            rc = -1;
    }
    close(sock);
    return rc;
}

static void start_dhcp(const char *ifname) {
    char pidfile[64];
    pid_t pid = fork();

    if (pid != 0)
        return;
    /* udhcpc passes its own environment to the lease script and never sets
       PATH itself, so the script needs one to find ip(8). */
    setenv("PATH", "/sbin:/usr/sbin:/bin:/usr/bin", 1);
    snprintf(pidfile, sizeof pidfile, "/run/udhcpc.%s.pid", ifname);
    execl("/sbin/udhcpc", "udhcpc", "-i", ifname, "-b", "-p", pidfile,
          (char *)NULL);
    _exit(127);
}

/* Nobody has logged in yet, but the box should already be online: raise the
   interface and let DHCP sort out the address, the default route and the
   resolver. Runs in the background, so a slow or absent DHCP server never
   holds up the first-boot wizard. */
static void bring_up_network(void) {
    char ifname[IFNAMSIZ] = "";
    int tries;

    /* The kernel is done probing before it runs us, but a freshly attached
       VMware NIC can land a moment later. Give the bus a couple of seconds
       before deciding this machine has no network. */
    for (tries = 0; tries < 20 && !ifname[0]; tries++) {
        const char *found = first_nonloop_iface();
        if (found)
            snprintf(ifname, sizeof ifname, "%s", found);
        else
            usleep(100 * 1000);
    }
    if (!ifname[0]) {
        say("no network interface, skipping DHCP");
        return;
    }
    if (link_up(ifname) != 0) {
        say("could not bring up %s, skipping DHCP", ifname);
        return;
    }
    say("%s is up, asking DHCP for an address", ifname);
    start_dhcp(ifname);
}

/* The session user.

   The wizard creates a named account and writes the login name on the first
   line of /etc/copper-firstboot.done. Until this existed the shell on tty1 ran
   as uid 0 -- spawn_tty() forked and exec'd with no setgid/setuid anywhere --
   while the environment said HOME=/home/<user>. That mismatch is exactly what
   Firefox refuses to start on:

       Running Firefox as root in a regular user's session is not supported.

   So the shell, and everything it starts (the desktop included), now runs as
   the wizard's user, and PID 1 keeps root with sudo as the way back up. When
   there is no marker user -- a first boot before the wizard has run, or an
   account that no longer resolves -- the session stays root, which is what the
   image did before. */
struct session {
    char name[64];
    char home[160];
    uid_t uid;
    gid_t gid;
    int ok;
};

static struct session g_session;

/* Fill `s` from the done-marker's first line, resolved through getpwnam.
   Returns 1 when there is a usable account, 0 otherwise. */
static int session_from_marker(const char *path, struct session *s) {
    memset(s, 0, sizeof *s);
    FILE *m = fopen(path, "r");
    if (!m) return 0;
    char who[64] = "";
    if (fgets(who, sizeof who, m)) {
        char *nl = strchr(who, '\n');
        if (nl) *nl = '\0';
    }
    fclose(m);
    if (!who[0]) return 0;
    struct passwd *pw = getpwnam(who);
    if (!pw) return 0;
    snprintf(s->name, sizeof s->name, "%s", pw->pw_name);
    snprintf(s->home, sizeof s->home, "%s", pw->pw_dir);
    s->uid = pw->pw_uid;
    s->gid = pw->pw_gid;
    s->ok = 1;
    return 1;
}

/* Drop the forked child to the session user. Runs only in the spawn_tty
   child, never in PID 1. If a step fails the child would rather be a root
   shell -- the state this image shipped in for months -- than a session that
   cannot start at all, so it says what went wrong and carries on as it is. */
static void drop_to_session(const struct session *s) {
    if (!s->ok) return;
    if (initgroups(s->name, s->gid) != 0) {
        fprintf(stderr, "copper: initgroups(%s) failed: %s\n",
                s->name, strerror(errno));
        return;
    }
    if (setgid(s->gid) != 0) {
        fprintf(stderr, "copper: setgid(%d) failed: %s\n",
                (int)s->gid, strerror(errno));
        return;
    }
    if (setuid(s->uid) != 0) {
        fprintf(stderr, "copper: setuid(%d) failed: %s\n",
                (int)s->uid, strerror(errno));
        return;
    }
    setenv("HOME", s->home, 1);
    setenv("USER", s->name, 1);
    setenv("LOGNAME", s->name, 1);
}

/* Hand the X server's device nodes to the session user.

   Xorg now runs as that user too. There is no udev on this image, so devtmpfs
   leaves /dev/input/event* (evdev), /dev/dri/card* (the KMS/modesetting driver)
   and the framebuffer and console VTs owned by root with modes a plain user
   cannot open -- Xorg would then start with a dead pointer and no keyboard.
   Give the session user ownership of exactly those nodes. Best effort: a node
   that is not present is not an error, and there is only ever one session. */
static void grant_devices(const struct session *s) {
    if (!s->ok) return;
    static const char *subdirs[] = { "/dev/input", "/dev/dri", NULL };
    char path[320];
    for (int i = 0; subdirs[i]; i++) {
        DIR *d = opendir(subdirs[i]);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.') continue;
            snprintf(path, sizeof path, "%s/%s", subdirs[i], e->d_name);
            (void)chown(path, s->uid, s->gid);
        }
        closedir(d);
    }
    DIR *d = opendir("/dev");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        const char *n = e->d_name;
        if (n[0] == '.') continue;
        if (strncmp(n, "tty", 3) != 0 && strncmp(n, "fb", 2) != 0 &&
            strncmp(n, "vcs", 3) != 0 && strcmp(n, "uinput") != 0)
            continue;
        snprintf(path, sizeof path, "/dev/%s", n);
        (void)chown(path, s->uid, s->gid);
    }
    closedir(d);
}

/* Directories the session expects that nothing else has made.

   /dev/shm is where glibc's shm_open() keeps its files; devtmpfs does not
   create it on its own. /run/user/<uid> is the XDG runtime directory, and
   nothing here logs in through pam so nothing makes it. startxfce used to
   create both itself, but it runs as the session user now and a user cannot
   mkdir under root-owned /dev or /run -- so PID 1 makes them first. Best
   effort, exactly like the device nodes. */
static void prepare_session_dirs(const struct session *s) {
    if (!s->ok) return;
    mkdir("/dev/shm", 01777);
    chmod("/dev/shm", 01777);
    char run[192];
    snprintf(run, sizeof run, "/run/user/%d", (int)s->uid);
    mkdir("/run/user", 0755);
    if (mkdir(run, 0700) == 0 || errno == EEXIST) {
        (void)chown(run, s->uid, s->gid);
        (void)chmod(run, 0700);
    }
}

/* Which desktop the first-boot wizard recorded.

   `path` holds one word on its first line. Anything unreadable or unrecognised
   means XFCE, which is the desktop that has always been here, so a missing or
   half-written marker is never a machine with no desktop -- it is the default
   one. Takes a path rather than hardcoding one so tests/init-session.c can
   exercise it without touching /etc. */
static int chose_hyprland(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[32] = "";
    if (fgets(line, sizeof line, f))
        line[strcspn(line, "\r\n")] = '\0';
    fclose(f);
    return strcmp(line, "hyprland") == 0;
}

/* The seat.

   Hyprland is a Wayland compositor: through libseat it opens /dev/dri and
   /dev/input. With no logind and no systemd, the seat comes from seatd, a small
   daemon that hands out device access over a unix socket. Start it once, as
   root, with the _seatd group the hypr stage created; the socket lands at
   /run/seatd.sock and the session user reaches it because the first-boot wizard
   put them in _seatd.

   XFCE does not need it -- Xorg is given its devices by copper-init directly --
   so a machine without seatd is still a working XFCE machine. Report it and
   carry on rather than refusing to boot for the other desktop's sake. */
static void start_seatd(void) {
    static const char *paths[] = { "/usr/bin/seatd", "/usr/sbin/seatd", NULL };
    const char *exe = NULL;
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) { exe = paths[i]; break; }
    }
    if (!exe) return;                 /* no Hyprland in this image */

    /* On images where the _seatd group did not arrive from the build stage
       (a reset /etc/group on a live init), recreating it here is cheaper than
       refusing to boot Hyprland. seatd looks the group up by name before doing
       any useful work, so without this line on such systems it exits early
       with "Could not find group by name '_seatd'." and there is no seat. */
    if (!getgrnam("_seatd")) {
        int _seatd_gid = 999;
        while (_seatd_gid > 100 && getgrgid(_seatd_gid)) _seatd_gid--;
        FILE *gl = fopen("/etc/group", "a");
        if (gl) {
            fprintf(gl, "_seatd:x:%d:\n", _seatd_gid);
            fclose(gl);
            say("created the missing _seatd group at gid %d (build stage did not ship it)", _seatd_gid);
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        say("could not fork seatd: %s", strerror(errno));
        return;
    }
    if (pid == 0) {
        setsid();
        execl(exe, "seatd", "-g", "_seatd", (char *)NULL);
        _exit(127);
    }
    /* Best effort: a moment for the socket to bind so the first starthyprland
       finds a seat. Not a wait on the socket itself -- the user types slowly,
       and a busy wait here would only delay the shell. seatd is PID 1's child
       and is reaped only if it exits, which it should not. */
    usleep(200 * 1000);
}


/* Returns the child's pid (the caller reaps it), or -1 if the fork failed. */
static pid_t spawn_tty(int tty) {
    pid_t pid = fork();
    if (pid != 0) return pid;

    setsid();
    char dev[32];
    snprintf(dev, sizeof dev, "/dev/tty%d", tty);
    int fd = open(dev, O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        ioctl(fd, TIOCSCTTY, 0);
        if (fd > 2) close(fd);
    }
    drop_to_session(&g_session);
    execl("/usr/bin/copper-sh", "copper-sh", (char *)NULL);
    execl("/bin/sh", "sh", (char *)NULL);
    _exit(1);
}

/* Which reboot(2) action an incoming power signal means.

   These are busybox init's signal names, chosen so the busybox halt /
   poweroff / reboot applets and our /sbin/shutdown all agree on one
   convention:

       SIGTERM -> reboot      SIGUSR2 -> poweroff      SIGUSR1 -> halt

   Kept as its own function so the mapping is unit-testable without actually
   rebooting the machine that runs the test -- see tests/init-session.c. */
static int power_how(int sig) {
    if (sig == SIGTERM) return RB_AUTOBOOT;
    if (sig == SIGUSR2) return RB_POWER_OFF;
    return RB_HALT_SYSTEM;              /* SIGUSR1, SIGPWR */
}

/* The power request handler.

   busybox's halt/poweroff/reboot applets do NOT call reboot(2) unless given
   -f; by default they signal PID 1 and expect it to do the orderly shutdown
   ("go through init"). Copper's PID 1 used to ignore SIGUSR1/SIGUSR2/SIGTERM,
   so `sudo reboot` and `sudo poweroff` silently did nothing (bug 18).
   sync() twice -- the second pass is the usual belt and braces for the
   persisted overlay upper -- then hand the machine to the kernel. */
static void on_power_signal(int sig) {
    sync();
    sync();
    reboot(power_how(sig));
    _exit(0);                           /* only if reboot(2) failed */
}

/* ---- the boot splash ------------------------------------------------------

   Plymouth draws the Copper boot animation and then hands the console back.
   It is started here, from PID 1, rather than by a service manager, because
   there is no service manager: copper-init is the init.

   Three things have to line up, and each is checked rather than assumed:

     - the kernel command line asks for it. grub.cfg passes "splash", and
       "plymouth.ignore-udev" beside it. The second is not optional: this
       image runs no udev, and without that switch plymouthd enumerates its
       devices through udev, finds nothing, and never draws a frame. With it,
       plymouthd takes its own fallback path and drives DRM or the
       framebuffer directly.

     - the pieces are in the image. Both the daemon and the control client are
       checked for, because a splash that cannot be quit is worse than none:
       it would sit on the console the login shell needs.

     - the daemon answers. The splash is only shown once the client can reach
       it, so a broken plymouth costs a short bounded pause, not a hang. */
static pid_t g_splash_pid = -1;

/* Exact-token match against /proc/cmdline, so "splash" does not also match
   "nosplash" and a "word=value" switch has to match whole. */
static int cmdline_has(const char *want) {
    FILE *f = fopen("/proc/cmdline", "r");
    char line[1024];
    char *p;
    size_t n, wantlen = strlen(want);

    if (!f)
        return 0;
    n = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    line[n] = '\0';

    for (p = line; *p; ) {
        size_t len;
        while (*p == ' ' || *p == '\t' || *p == '\n')
            p++;
        if (!*p)
            break;
        len = strcspn(p, " \t\n");
        if (len == wantlen && strncmp(p, want, len) == 0)
            return 1;
        p += len;
    }
    return 0;
}

/* Run the plymouth client once and wait for it. Returns its exit status, or
   -1 if it could not be run at all. */
static int plymouth_cmd(const char *cmd) {
    pid_t pid = fork();
    int st;

    if (pid < 0)
        return -1;
    if (pid == 0) {
        execl("/usr/bin/plymouth", "plymouth", cmd, (char *)NULL);
        _exit(127);
    }
    if (waitpid(pid, &st, 0) < 0)
        return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Fork the daemon. attach selects the console-redirecting form. */
static pid_t splash_spawn(int attach) {
    pid_t pid = fork();

    if (pid != 0)
        return pid;
    if (attach)
        execl("/usr/sbin/plymouthd", "plymouthd",
              "--mode=boot", "--pid-file=/run/plymouth/pid",
              "--attach-to-session", "--no-daemon", (char *)NULL);
    else
        execl("/usr/sbin/plymouthd", "plymouthd",
              "--mode=boot", "--pid-file=/run/plymouth/pid",
              "--no-daemon", (char *)NULL);
    _exit(127);
}

/* Is the daemon still running? Reaps it and clears the pid once it has gone: a
   zombie still answers kill(pid, 0), so this waits rather than probing. */
static int splash_alive(void) {
    int st;
    pid_t r;

    if (g_splash_pid <= 0)
        return 0;
    r = waitpid(g_splash_pid, &st, WNOHANG);
    if (r == g_splash_pid || r < 0) {
        g_splash_pid = -1;
        return 0;
    }
    return 1;
}

/* Wait for the daemon to start answering. 0 once it does, -1 if it died or
   never answered within the bound. */
static int splash_ready(void) {
    int i;

    for (i = 0; i < 50; i++) {
        if (plymouth_cmd("--ping") == 0)
            return 0;
        if (!splash_alive())
            return -1;
        usleep(20 * 1000);
    }
    return -1;
}

static void splash_start(void) {
    if (!cmdline_has("splash") || cmdline_has("nosplash") ||
        cmdline_has("plymouth.enable=0"))
        return;
    if (access("/usr/sbin/plymouthd", X_OK) != 0 ||
        access("/usr/bin/plymouth", X_OK) != 0)
        return;

    g_splash_pid = splash_spawn(1);
    if (g_splash_pid < 0)
        return;
    if (splash_ready() == 0 && plymouth_cmd("--show-splash") == 0)
        return;

    /* Either it never answered, or it exited: the console-session attach is
       the step that can fail. Restart it without that step so the animation
       still plays, rather than dropping the whole idea for one failure. */
    if (g_splash_pid > 0) {
        int i;
        plymouth_cmd("--quit");
        for (i = 0; i < 25 && splash_alive(); i++)
            usleep(20 * 1000);
    }
    g_splash_pid = splash_spawn(0);
    if (g_splash_pid > 0 && splash_ready() == 0)
        plymouth_cmd("--show-splash");
}

static void splash_stop(void) {
    int i;

    if (g_splash_pid <= 0)
        return;
    plymouth_cmd("--quit");
    /* Wait for it to exit, so the console is back in text mode before the
       login shell is spawned onto it -- and so the daemon is reaped. */
    for (i = 0; i < 50 && splash_alive(); i++)
        usleep(20 * 1000);
    g_splash_pid = -1;
}

int main(void) {
    console_stdio();

    /* PATH, set once, here, before anything is forked.

       This was the cause of "ip: command not found" and "ifconfig: command
       not found" on a booted system, and it is worth writing down properly
       because the commands were never missing.

       PID 1 starts with an environment the kernel builds, and it has no PATH
       in it. When a program has no PATH, execvp() falls back to
       confstr(_CS_PATH), which is the kernel's compiled-in default:

           /bin:/usr/bin

       Copper's networking applets are in sbin. So `ip`, `ifconfig`, `route`,
       `arp` and everything else installed under /sbin and /usr/sbin were
       unreachable by name, while `ping`, `grep`, `touch` and the rest worked
       because they are in /bin and /usr/bin. The commands were present,
       compiled in, and correctly linked the whole time -- the shell was
       simply never told to look in sbin.

       Setting it in start_dhcp() did not help, because that runs in a forked
       child: the child got a PATH and the shell, which is what people
       actually type at, did not. Anything that wants a PATH has to inherit
       it from here. */
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           1);

    /* Power signals get real handlers (see on_power_signal). SIGINT and
       SIGHUP stay ignored: Ctrl-Alt-Del and a terminal hangup are not things
       this init should act on. SIGCHLD is left at its default, because the
       reaper below relies on waitpid. */
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_power_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);      /* reboot */
    sigaction(SIGUSR1, &sa, NULL);      /* halt */
    sigaction(SIGUSR2, &sa, NULL);      /* poweroff */
#ifdef SIGPWR
    sigaction(SIGPWR, &sa, NULL);       /* halt (ACPI power button) */
#endif
    signal(SIGINT, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    signal(SIGCHLD, SIG_DFL);

    mount_if_needed("proc", "/proc", "proc");
    mount_if_needed("sysfs", "/sys", "sysfs");
    mount_if_needed("devtmpfs", "/dev", "devtmpfs");
    mount_if_needed("tmpfs", "/run", "tmpfs");

    /* The splash comes up as soon as there is a /proc to read the kernel
       command line from and a /run for the daemon's pid file, and before
       anything prints: with the console redirected, it covers the boot rather
       than scrolling past underneath it. */
    splash_start();

    apply_hostname();

    /* Started before the wizard on purpose: DHCP gets to negotiate while
       the user is still typing their name. */
    bring_up_network();

    /* ...but udhcpc prints its progress to the same console the wizard is
       prompting on, and a lease landing mid-question lands in the middle of
       the prompt. Give it a beat to finish talking before the first question,
       which costs a second on a normal DHCP server and keeps the questions
       readable. A slow server is still not blocking: this is a fixed pause,
       not a wait on the lease. */
    usleep(1500 * 1000);
    printf("\n");
    fflush(stdout);

    /* Hand the console back before anything interactive. The first-boot wizard
       prompts on this console and the login shell reads from it; a splash left
       up would hide what the machine is asking, and the quit is what puts the
       VT back into text mode. */
    splash_stop();

    struct stat st_done;
    if (stat("/etc/copper-firstboot.done", &st_done) != 0) {
        pid_t wiz = fork();
        if (wiz == 0) {
            /* The wizard needs a controlling terminal of its own. getpass()
               reads from /dev/tty rather than stdin, so without a session and
               an acquired tty it cannot open /dev/tty at all and the password
               questions come back unusable. Same treatment spawn_tty() gives
               the shell, pointed at /dev/console because that is where the
               wizard's stdout already goes. */
            setsid();
            int cfd = open("/dev/console", O_RDWR);
            if (cfd >= 0) {
                ioctl(cfd, TIOCSCTTY, 0);
                if (cfd > 2) close(cfd);
            }
            execl("/usr/bin/copper-firstboot", "copper-firstboot",
                  (char *)NULL);
            _exit(1);
        }
        int wst;
        waitpid(wiz, &wst, 0);
    }

/* The session user, and where the shell starts.

       This has to happen after the wizard, not before: on a first boot the
       done-marker does not exist yet, so reading it any earlier finds nothing.
       /etc/copper-firstboot.done holds the username on its first line, written
       by the wizard as it finishes. Resolving it here means one read, used
       both to pick the working directory and to drop the shell's privileges
       in spawn_tty() below.

       Dropping someone at / is worth avoiding: that is the session account
       sitting next to /boot, /etc and the block devices. The account is no
       longer root, so this is smaller than it once was, but the working
       directory still should not be the root of the filesystem. */
    session_from_marker("/etc/copper-firstboot.done", &g_session);
    if (g_session.ok) {
        /* Only adopt the home if it is a real, enterable directory: a stale
           marker left by a half-finished wizard must not put us somewhere
           that does not exist. The drop does not depend on this -- the
           account is real either way, and cwd is not the shell's identity. */
        if (access(g_session.home, X_OK) == 0 && chdir(g_session.home) == 0) {
            setenv("HOME", g_session.home, 1);
            setenv("USER", g_session.name, 1);
            setenv("LOGNAME", g_session.name, 1);
        } else {
            printf("copper: no home directory at %s -- staying in /\n",
                   g_session.home);
        }
    }

    /* The shell.

       There is no automatic desktop. The desktop is XFCE, and XFCE is something
       the user starts with `startxfce` at the prompt below rather than something
       boot hands them: the X stack is not in this image yet, so an automatic
       start either works or leaves a blank screen, and neither is worth it to
       someone who is about to type startxfce anyway. A shell in front of it also
       means a failure in the X stack costs a shell rather than the machine.

       This also removes the whole reason the desktop used to have a kernel
       command line switch. Driving the VGA into a graphics mode is irreversible
       from the text console: on a machine whose framebuffer it cannot drive there
       is no way back, because the shell exists but there is no longer a screen to
       show it on. Xorg takes the display through KMS and leaves a working console
       behind, so there is nothing to switch away from. */

    say("type %s",
        chose_hyprland("/etc/copper-desktop")
            ? "starthyprland for Hyprland (or startxfce for XFCE)"
            : "startxfce for XFCE (or starthyprland for Hyprland)");

    /* The seat, before the shell: Hyprland needs it the moment starthyprland
       runs, and starting it here means the user never waits on it. */
    start_seatd();

    /* Exactly one session at a time. Keep the pid so the reaper below can wait
       on this specific child instead of on any child: udhcpc is our child too,
       and `udhcpc -b` leaves a short-lived parent behind when it daemonises.

       waitpid(-1) would return on that exit and start a second copper-sh on the
       same tty, so two shells fought over stdin -- typing came out garbled and
       the banner printed twice. */
    for (;;) {
        grant_devices(&g_session);
        prepare_session_dirs(&g_session);
        pid_t session = spawn_tty(1);
        int wst;
        if (session > 0)
            waitpid(session, &wst, 0);
    }
    return 0;                        /* never reached */
}