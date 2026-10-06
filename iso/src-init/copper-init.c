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
#include <net/if.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
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
    execl("/usr/bin/copper-sh", "copper-sh", (char *)NULL);
    execl("/bin/sh", "sh", (char *)NULL);
    _exit(1);
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

    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    signal(SIGCHLD, SIG_DFL);

    mount_if_needed("proc", "/proc", "proc");
    mount_if_needed("sysfs", "/sys", "sysfs");
    mount_if_needed("devtmpfs", "/dev", "devtmpfs");
    mount_if_needed("tmpfs", "/run", "tmpfs");

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

/* Land in the user's own home, not in /.

       This has to happen after the wizard, not before: on a first boot the
       done-marker does not exist yet, so reading it any earlier finds nothing.
       /etc/copper-firstboot.done holds the username on its first line, written
       by the wizard as it finishes.

       Dropping someone at / is worth avoiding. That is uid 0 sitting next to
       /boot, /etc and the block devices, with no login in front of it. This
       does not make the system safe -- init goes straight to a root shell, and
       pretending otherwise would be worse than saying so plainly -- but the
       working directory should not be the root of the filesystem. */
    {
        char who[64] = "";
        FILE *m = fopen("/etc/copper-firstboot.done", "r");
        if (m) {
            if (fgets(who, sizeof who, m)) {
                char *nl = strchr(who, '\n');
                if (nl) *nl = '\0';
            }
            fclose(m);
        }
        if (who[0]) {
            char home[160];
            snprintf(home, sizeof home, "/home/%s", who);
            /* Only adopt it if it is a real, enterable directory: a stale
               marker left by a half-finished wizard must not put us somewhere
               that does not exist. */
            if (access(home, X_OK) == 0 && chdir(home) == 0) {
                setenv("HOME", home, 1);
                setenv("USER", who, 1);
                setenv("LOGNAME", who, 1);
            } else {
                printf("copper: no home directory at %s -- staying in /\n",
                       home);
            }
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

    say("copper: type startxfce for XFCE");

    /* Exactly one session at a time. Keep the pid so the reaper below can wait
       on this specific child instead of on any child: udhcpc is our child too,
       and `udhcpc -b` leaves a short-lived parent behind when it daemonises.

       waitpid(-1) would return on that exit and start a second copper-sh on the
       same tty, so two shells fought over stdin -- typing came out garbled and
       the banner printed twice. */
    for (;;) {
        pid_t session = spawn_tty(1);
        int wst;
        if (session > 0)
            waitpid(session, &wst, 0);
    }
    return 0;                        /* never reached */
}