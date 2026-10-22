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
#include <time.h>
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
    /* god please kill me: fork, then hope the lease script finds its own way
       to ip(8). If it does not, the machine boots offline and says nothing. */
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

/* Make the input devices visible to libinput -- and say what each one is.

   Hyprland gets its keyboard and pointer from libinput, and libinput discards
   every device that libudev calls "not initialized". That flag does not mean
   the device is broken: it means udevd has written a record for it under
   /run/udev/data. This image runs no udev daemon -- the note under "the
   desktop as a real user" in HANDOFF.md explains why -- so nothing ever writes
   those records, libinput enumerates /sys/class/input/event*, discards every
   one, and the compositor comes up with a pointer that does not move and a
   keyboard that types nowhere. XFCE never noticed because startxfce writes an
   xorg.conf naming the evdev nodes directly, and Xorg does not consult libudev
   for them.

   The record is small: one file per device, named for its device number
   ("c13:64"), whose I: line carries the initialise stamp. Write them by hand,
   as root and before the shell starts. This is not a udev replacement -- it
   does not follow hotplug -- but it is exactly what libudev reads, and the
   devices in a VM are present from boot anyway.

   Clearing that flag is only half of being seen. libinput does not work out a
   device's type from its kernel capabilities: it reads udev's ID_INPUT_* tags,
   and a device whose only tag is ID_INPUT is dropped by the gate near the top
   of evdev_device_create():

       if ((udev_tags & EVDEV_UDEV_TAG_INPUT) == 0 ||
           (udev_tags & ~EVDEV_UDEV_TAG_INPUT) == 0)
               goto err;

   So a record that says only "ID_INPUT=1" is worth what no record at all is
   worth: the device is enumerated, then it is dropped, and the session still
   has no keyboard -- while the boot log says the records were written and
   everything looks right. On a real machine those tags come from udev's
   input_id builtin, which reads the device's sysfs capabilities and writes
   down what it found. There is no udev here to do that, so the same verdicts
   are reached here, from the same attributes and by the same rules (systemd's
   udev-builtin-input_id.c). The rules are worth following rather than
   approximating, because the two ways to be wrong are not symmetrical: an
   extra tag costs a setting, a missing one costs the device.

   Takes the sysfs directory and the database directory as arguments rather
   than naming the real ones, so tests/init-session.c can point it at a fake
   tree, and reports how many records carried a type -- which is the difference
   between input working and input being enumerated and dropped. Returns how
   many records it wrote. */

/* Input event codes, button ranges and property bits, from linux/input.h and
   linux/input-event-codes.h. Spelled out rather than included, for the same
   reason the ARPHRD_* above are: this builds against musl, whose gcc wrapper
   has only musl's own headers on the include path (build.sh, build_musl), so
   <linux/input.h> is not reachable from here. These are kernel ABI -- assigned
   once and never moved -- and they are the numbers udev's input_id builtin
   compares against. */
#define EV_KEY                  0x01
#define EV_REL                  0x02
#define EV_SW                   0x05

#define REL_X                   0x00
#define REL_Y                   0x01
#define REL_HWHEEL              0x06
#define REL_WHEEL               0x08

#define ABS_X                   0x00
#define ABS_Y                   0x01
#define ABS_Z                   0x02
#define ABS_RX                  0x03
#define ABS_PRESSURE            0x18
#define ABS_MT_SLOT             0x2f
#define ABS_MT_POSITION_X       0x35
#define ABS_MT_POSITION_Y       0x36

#define INPUT_PROP_DIRECT       0x01
#define INPUT_PROP_POINTING_STICK 0x05
#define INPUT_PROP_ACCELEROMETER  0x06

#define BTN_MISC                0x100
#define BTN_0                   0x100
#define BTN_1                   0x101
#define BTN_MOUSE               0x110   /* BTN_LEFT */
#define BTN_JOYSTICK            0x120   /* BTN_TRIGGER */
#define BTN_DIGI                0x140   /* BTN_TOOL_PEN: the same number */
#define BTN_TOOL_PEN            0x140
#define BTN_TOOL_FINGER         0x145
#define BTN_TOUCH               0x14a
#define BTN_STYLUS              0x14b
#define BTN_DPAD_UP             0x220
#define BTN_DPAD_RIGHT          0x223
#define BTN_TRIGGER_HAPPY       0x2c0
#define BTN_TRIGGER_HAPPY1      0x2c0
#define BTN_TRIGGER_HAPPY40     0x2e7

#define KEY_OK                  0x160
#define KEY_ALS_TOGGLE          0x230
#define KEY_LEFTCTRL            29
#define KEY_CAPSLOCK            58
#define KEY_NUMLOCK             69
#define KEY_INSERT              110
#define KEY_MUTE                113
#define KEY_CALC                140
#define KEY_FILE                144
#define KEY_MAIL                155
#define KEY_PLAYPAUSE           164
#define KEY_BRIGHTNESSDOWN      224

#define BUS_I2C                 0x18

/* The capability attributes are hex bitmaps, most significant word first
   ("120013", or "0 0 1f"), and a word the kernel left out is zero. KEY_MAX,
   the largest bit any of them carries, is 0x2ff: sixteen 64-bit words. */
#define CAP_WORDS 16

struct capset {
    unsigned long long word[CAP_WORDS];
};

/* Read one capability attribute into `c`. A missing or empty attribute is not
   an error: it means the device has none of those bits. */
static void cap_read(struct capset *c, const char *dir, const char *attr) {
    memset(c, 0, sizeof *c);

    /* 384 rather than 320: dir is itself a 320-byte buffer, and a truncated
       path only looks like an unreadable attribute -- a device silently
       becomes unclassifiable and libinput drops it. */
    char path[384];
    snprintf(path, sizeof path, "%s/%s", dir, attr);
    FILE *f = fopen(path, "r");
    if (!f) return;

    char buf[512];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = '\0';

    /* Split into words, then take them from the end: the last word printed
       holds bits 0-63, the one before it 64-127, and so on. */
    const char *word[CAP_WORDS];
    size_t words = 0;
    for (char *p = buf; *p != '\0' && words < CAP_WORDS; ) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == '\0') break;
        word[words++] = p;
        while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
        if (*p != '\0') *p++ = '\0';
    }
    for (size_t i = 0; i < words; i++)
        c->word[i] = strtoull(word[words - 1 - i], NULL, 16);
}

/* Is that bit set? */
static int cap_test(const struct capset *c, unsigned bit) {
    return (bit >> 6) < CAP_WORDS
        && (int)((c->word[bit >> 6] >> (bit & 63)) & 1ULL);
}

/* Is any bit below `limit` set? udev asks this of whole blocks of keys. */
static int cap_any(const struct capset *c, unsigned limit) {
    for (unsigned i = 0; i < CAP_WORDS && i * 64 < limit; i++) {
        unsigned long long v = c->word[i];
        if ((i + 1) * 64 > limit)
            v &= (1ULL << (limit - i * 64)) - 1ULL;
        if (v) return 1;
    }
    return 0;
}

/* One bit per ID_INPUT_* property the classifier can decide on, and the name
   each is written under. The order is udev's. */
enum {
    TAG_POINTINGSTICK = 1u << 0,
    TAG_MOUSE         = 1u << 1,
    TAG_TOUCHPAD      = 1u << 2,
    TAG_TOUCHSCREEN   = 1u << 3,
    TAG_JOYSTICK      = 1u << 4,
    TAG_TABLET        = 1u << 5,
    TAG_TABLET_PAD    = 1u << 6,
    TAG_ACCELEROMETER = 1u << 7,
    TAG_KEY           = 1u << 8,
    TAG_KEYBOARD      = 1u << 9,
    TAG_SWITCH        = 1u << 10
};

static const struct {
    unsigned flag;
    const char *property;
} input_tags[] = {
    { TAG_POINTINGSTICK, "ID_INPUT_POINTINGSTICK" },
    { TAG_MOUSE,         "ID_INPUT_MOUSE" },
    { TAG_TOUCHPAD,      "ID_INPUT_TOUCHPAD" },
    { TAG_TOUCHSCREEN,   "ID_INPUT_TOUCHSCREEN" },
    { TAG_JOYSTICK,      "ID_INPUT_JOYSTICK" },
    { TAG_TABLET,        "ID_INPUT_TABLET" },
    { TAG_TABLET_PAD,    "ID_INPUT_TABLET_PAD" },
    { TAG_ACCELEROMETER, "ID_INPUT_ACCELEROMETER" },
    { TAG_KEY,           "ID_INPUT_KEY" },
    { TAG_KEYBOARD,      "ID_INPUT_KEYBOARD" },
    { TAG_SWITCH,        "ID_INPUT_SWITCH" }
};

/* The decided tags as short names, for the boot log: "KEY KEYBOARD", or
   "none" when a device got only ID_INPUT -- the one outcome that makes
   libinput drop it. Written into buf; always NUL-terminated. */
static void tag_names(unsigned tags, char *buf, size_t bufsz)
{
    size_t used = 0;

    if (bufsz == 0)
        return;
    buf[0] = '\0';
    for (size_t i = 0; i < sizeof input_tags / sizeof input_tags[0]; i++) {
        const char *name;

        if (!(tags & input_tags[i].flag))
            continue;
        /* "ID_INPUT_" is a fixed 9-byte prefix on every property. */
        name = input_tags[i].property + 9;
        if (used && used + 1 < bufsz)
            buf[used++] = ' ';
        for (size_t j = 0; name[j] && used + 1 < bufsz; j++)
            buf[used++] = name[j];
        buf[used] = '\0';
    }
    if (buf[0] == '\0' && bufsz > 4)
        memcpy(buf, "none", 5);
}

/* A sysfs attribute holding a newline-trimmed string. Returns 0 when it is
   not there or empty. */
static int read_attr(const char *dir, const char *attr, char *out, size_t outsz) {
    char path[384];
    snprintf(path, sizeof path, "%s/%s", dir, attr);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(out, 1, outsz - 1, f);
    fclose(f);
    out[n] = '\0';
    n = strcspn(out, "\r\n");
    out[n] = '\0';
    return n > 0;
}

/* A sysfs attribute holding one hex number, or 0 when it is not there. */
static unsigned hex_attr(const char *dir, const char *attr) {
    char path[384], buf[32];
    snprintf(path, sizeof path, "%s/%s", dir, attr);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (!fgets(buf, sizeof buf, f)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return (unsigned)strtoul(buf, NULL, 16);
}

/* The tags this device earns. The rules are udev's: test_pointers() decides
   what kind of pointer it is, test_key() whether it is a keyboard, and the
   builtin around them adds the two smaller cases at the end. */
static unsigned input_device_tags(const char *dir) {
    struct capset ev, key, rel, abs, props;
    cap_read(&ev, dir, "capabilities/ev");
    cap_read(&key, dir, "capabilities/key");
    cap_read(&rel, dir, "capabilities/rel");
    cap_read(&abs, dir, "capabilities/abs");
    cap_read(&props, dir, "properties");

    unsigned tags = 0;
    int is_pointer = 0;

    /* --------------------------------------------- pointers (test_pointers) */
    int has_keys = cap_test(&ev, EV_KEY);
    int has_abs_coordinates = cap_test(&abs, ABS_X) && cap_test(&abs, ABS_Y);
    int has_3d = has_abs_coordinates && cap_test(&abs, ABS_Z);
    int is_accelerometer = cap_test(&props, INPUT_PROP_ACCELEROMETER);
    if (!has_keys && has_3d)
        is_accelerometer = 1;

    if (is_accelerometer) {
        /* An accelerometer is its own kind, and udev stops here rather than
           also asking what kind of pointer it is. */
        tags |= TAG_ACCELEROMETER;
        is_pointer = 1;
    } else {
        int is_pointing_stick = cap_test(&props, INPUT_PROP_POINTING_STICK);
        int has_stylus = cap_test(&key, BTN_STYLUS);
        int has_pen = cap_test(&key, BTN_TOOL_PEN);
        int finger_but_no_pen = cap_test(&key, BTN_TOOL_FINGER) && !has_pen;
        int has_mouse_button = 0;
        for (unsigned b = BTN_MOUSE; b < BTN_JOYSTICK && !has_mouse_button; b++)
            has_mouse_button = cap_test(&key, b);
        int has_rel = cap_test(&ev, EV_REL) && cap_test(&rel, REL_X)
                   && cap_test(&rel, REL_Y);
        int has_mt = cap_test(&abs, ABS_MT_POSITION_X)
                  && cap_test(&abs, ABS_MT_POSITION_Y);
        /* A device claiming every absolute axis there is, both multi-touch
           ones included, is not really multi-touch. */
        if (has_mt && cap_test(&abs, ABS_MT_SLOT) && cap_test(&abs, ABS_MT_SLOT - 1))
            has_mt = 0;
        int is_direct = cap_test(&props, INPUT_PROP_DIRECT);
        int has_touch = cap_test(&key, BTN_TOUCH);
        int has_pad_buttons = cap_test(&key, BTN_0) && cap_test(&key, BTN_1)
                           && !has_pen;
        int has_wheel = cap_test(&ev, EV_REL)
                     && (cap_test(&rel, REL_WHEEL) || cap_test(&rel, REL_HWHEEL));

        /* Buttons in the joystick range -- unless the mouse range runs into
           it, which is what a mouse with more than sixteen buttons does. */
        int stick_buttons = 0, stick_axes = 0;
        if (!cap_test(&key, BTN_JOYSTICK - 1)) {
            for (unsigned b = BTN_JOYSTICK; b < BTN_DIGI; b++)
                if (cap_test(&key, b)) stick_buttons++;
            for (unsigned b = BTN_TRIGGER_HAPPY1; b <= BTN_TRIGGER_HAPPY40; b++)
                if (cap_test(&key, b)) stick_buttons++;
            for (unsigned b = BTN_DPAD_UP; b <= BTN_DPAD_RIGHT; b++)
                if (cap_test(&key, b)) stick_buttons++;
        }
        for (unsigned a = ABS_RX; a < ABS_PRESSURE; a++)
            if (cap_test(&abs, a)) stick_axes++;

        int is_tablet = 0, is_touchpad = 0, is_touchscreen = 0, is_joystick = 0;
        int is_mouse = 0, is_abs_mouse = 0, is_tablet_pad = 0;

        if (has_abs_coordinates) {
            if (has_stylus || has_pen)
                is_tablet = 1;
            else if (finger_but_no_pen && !is_direct)
                is_touchpad = 1;
            else if (has_mouse_button)
                is_abs_mouse = 1;      /* VMware's USB mouse: axes, no touch */
            else if (has_touch || is_direct)
                is_touchscreen = 1;
            else if (stick_buttons > 0 || stick_axes > 0)
                is_joystick = 1;
        } else if (stick_buttons > 0 || stick_axes > 0) {
            is_joystick = 1;
        }

        if (has_mt) {
            if (has_stylus || has_pen)
                is_tablet = 1;
            else if (finger_but_no_pen && !is_direct)
                is_touchpad = 1;
            else if (has_touch || is_direct)
                is_touchscreen = 1;
        }

        if (is_tablet && has_pad_buttons)
            is_tablet_pad = 1;

        /* Two pad buttons and a wheel, with no relative axes: a tablet pad. */
        if (has_pad_buttons && has_wheel && !has_rel) {
            is_tablet = 1;
            is_tablet_pad = 1;
        }

        if (!is_tablet && !is_touchpad && !is_joystick && has_mouse_button
            && (has_rel || !has_abs_coordinates))
            is_mouse = 1;

        /* There is no such thing as an i2c mouse: that is a trackpoint. */
        if (is_mouse && hex_attr(dir, "id/bustype") == BUS_I2C)
            is_pointing_stick = 1;

        /* Un-detecting joysticks: keyboards carry the odd joystick button, so
           a device with several of the keys below is a keyboard, and one with
           fewer than two buttons or axes is not a joystick either. */
        if (is_joystick) {
            static const unsigned keyboard_keys[] = {
                KEY_LEFTCTRL, KEY_CAPSLOCK, KEY_NUMLOCK, KEY_INSERT, KEY_MUTE,
                KEY_CALC, KEY_FILE, KEY_MAIL, KEY_PLAYPAUSE, KEY_BRIGHTNESSDOWN
            };
            int well_known = 0;
            if (has_keys)
                for (size_t i = 0; i < sizeof keyboard_keys / sizeof keyboard_keys[0]; i++)
                    if (cap_test(&key, keyboard_keys[i])) well_known++;
            if (well_known >= 4 || stick_buttons + stick_axes < 2)
                is_joystick = 0;
            if (has_wheel && has_pad_buttons)
                is_joystick = 0;
        }

        if (is_pointing_stick)          tags |= TAG_POINTINGSTICK;
        if (is_mouse || is_abs_mouse)   tags |= TAG_MOUSE;
        if (is_touchpad)                tags |= TAG_TOUCHPAD;
        if (is_touchscreen)             tags |= TAG_TOUCHSCREEN;
        if (is_joystick)                tags |= TAG_JOYSTICK;
        if (is_tablet)                  tags |= TAG_TABLET;
        if (is_tablet_pad)              tags |= TAG_TABLET_PAD;

        is_pointer = is_tablet || is_mouse || is_abs_mouse || is_touchpad
                  || is_touchscreen || is_joystick || is_pointing_stick;
    }

    /* ------------------------------------------------------ keys (test_key) */
    int is_key = 0;
    if (cap_test(&ev, EV_KEY)) {
        /* Any KEY_* below the mouse and joystick buttons, or one of the two
           high blocks that hold the few keys above them. */
        int found = cap_any(&key, BTN_MISC);
        for (unsigned b = KEY_OK; b < BTN_DPAD_UP && !found; b++)
            if (cap_test(&key, b)) found = 1;
        for (unsigned b = KEY_ALS_TOGGLE; b < BTN_TRIGGER_HAPPY && !found; b++)
            if (cap_test(&key, b)) found = 1;
        if (found) {
            tags |= TAG_KEY;
            is_key = 1;
        }

        /* The first 32 bits are ESC, the numbers and Q to D: a device with all
           of them is a full keyboard, whatever else it also looks like. The
           reserved key 0 is not asked for. */
        if ((key.word[0] & 0xFFFFFFFEULL) == 0xFFFFFFFEULL) {
            tags |= TAG_KEYBOARD;
            is_key = 1;
        }
    }

    /* Some evdev nodes are a scroll wheel and nothing else. */
    if (!is_pointer && !is_key && cap_test(&ev, EV_REL)
        && (cap_test(&rel, REL_WHEEL) || cap_test(&rel, REL_HWHEEL)))
        tags |= TAG_KEY;

    if (cap_test(&ev, EV_SW))
        tags |= TAG_SWITCH;

    return tags;
}

/* Does this directory look like an input device? Its capability attributes
   say so. */
static int is_input_device(const char *dir) {
    char probe[384];
    snprintf(probe, sizeof probe, "%s/capabilities/ev", dir);
    return access(probe, R_OK) == 0;
}

static int seed_udev_input_db(const char *sysdir, const char *dbdir, int *typed) {
    DIR *d = opendir(sysdir);
    if (!d) return 0;

    /* The database directory is ours to make: there is no udev daemon here to
       have made it. The caller creates the parent (/run/udev), but a record
       cannot be written until the leaf directory itself exists, and mkdir's
       failure is deliberately ignored -- EEXIST is the normal case on every
       pass after the first. Without this, every fopen() below fails with
       ENOENT and the function reports zero records while looking, to the boot
       log, exactly like a machine with no input devices at all. */
    (void)mkdir(dbdir, 0755);

    unsigned long long usec = 0;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0)
        usec = (unsigned long long)ts.tv_sec * 1000000ULL
             + (unsigned long long)ts.tv_nsec / 1000ULL;

    /* `src` carries a whole event path, and the compiler can see that the two
       names inside it make 580 bytes possible: give it the room, because a
       truncated path skips a device with nothing said. */
    char src[640], dst[320], num[64], devdir[320];
    int written = 0, named = 0;
    struct dirent *e;

    /* idk how ts works: a device is a mouse if its capability bits say EV_REL
       and EV_KEY and EV_SW are not enough to tell a mouse from a keyboard with
       a trackball, so every one of these tags is a guess the kernel could have
       made for us. */

    /* Walk the devices rather than the event nodes. The inputN entries are the
       input devices themselves -- the directory udev's input_id builtin reaches
       by walking up from an event node -- so the capability attributes it reads
       are right there, and no guess that the two numbers are equal: event12 is
       a child of input19, and they are not the same number. The event node is
       what carries the device number, and that number is the record's name,
       because event nodes are what libinput enumerates. A class entry with no
       event node (js0, mouse0) writes nothing. */
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "input", 5) != 0) continue;
        snprintf(devdir, sizeof devdir, "%s/%s", sysdir, e->d_name);
        if (!is_input_device(devdir)) continue;

        /* What the device is, once per device. It is answered before any
           record is written: the record is the only place the answer can go,
           and libinput ignores a device whose record names no type. */
        unsigned tags = input_device_tags(devdir);

        /* Name every device and its verdict, every pass. The compositor's
           silence when it drops a device is total -- libinput logs at a
           debug level Aquamarine turns into nothing -- so this line is the
           only place a bad classification can ever be seen. The sysfs
           name is what makes it actionable: it says which physical
           device the verdict belongs to. */
        char names[128], devname[64];
        tag_names(tags, names, sizeof names);
        if (!read_attr(devdir, "name", devname, sizeof devname))
            snprintf(devname, sizeof devname, "(unnamed)");
        say("input: %s \"%s\" -> %s", e->d_name, devname, names);

        DIR *v = opendir(devdir);
        if (!v) continue;
        struct dirent *c;
        while ((c = readdir(v)) != NULL) {
            if (strncmp(c->d_name, "event", 5) != 0) continue;
            snprintf(src, sizeof src, "%s/%s/dev", devdir, c->d_name);
            FILE *in = fopen(src, "r");
            if (!in) continue;
            if (!fgets(num, sizeof num, in)) {
                fclose(in);
                continue;
            }
            fclose(in);
            num[strcspn(num, "\r\n")] = '\0';
            if (strchr(num, ':') == NULL) continue;

            snprintf(dst, sizeof dst, "%s/c%s", dbdir, num);
            FILE *out = fopen(dst, "w");
            if (!out) continue;
            fprintf(out, "I:%llu\nE:ID_INPUT=1\n", usec);
            for (size_t i = 0; i < sizeof input_tags / sizeof input_tags[0]; i++)
                if (tags & input_tags[i].flag)
                    fprintf(out, "E:%s=1\n", input_tags[i].property);
            fclose(out);
            written++;
            if (tags) named++;
        }
        closedir(v);
    }
    closedir(d);
    if (typed) *typed = named;
    return written;
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

    /* Firstboot may have run before the _seatd group existed, so the account
       never got added to it. Put it there now, before the login shell starts,
       so libseat can open the input devices (cursor/keyboard in Hyprland).
       Only when the group actually exists and the user is really not in it --
       addgroup's "already a member" complaint on every boot would be noise on
       the console. */
    {
        FILE *dm = fopen("/etc/copper-firstboot.done", "r");
        if (dm) {
            char uname[64];
            if (fgets(uname, sizeof uname, dm)) {
                char *nl = strchr(uname, '\n');
                if (nl) *nl = '\0';
                struct group *sg = uname[0] ? getgrnam("_seatd") : NULL;
                struct passwd *pw = uname[0] ? getpwnam(uname) : NULL;
                if (sg && pw) {
                    int ng = 32, i, have = 0;
                    gid_t groups[32];
                    if (getgrouplist(uname, pw->pw_gid, groups, &ng) >= 0)
                        for (i = 0; i < ng; i++)
                            if (groups[i] == sg->gr_gid) have = 1;
                    if (!have) {
                        char cmd[160];
                        snprintf(cmd, sizeof cmd, "/bin/busybox addgroup %s _seatd", uname);
                        int rc = system(cmd);
                        (void)rc;
                    }
                }
            }
            fclose(dm);
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

/* Which reboot(2) action an incoming signal means.

   These are busybox init's signal names, chosen so the busybox halt /
   poweroff / reboot applets and our /sbin/shutdown all agree on one
   convention:

       SIGTERM -> reboot      SIGUSR2 -> poweroff      SIGUSR1 -> halt

   SIGINT is not one of those: the kernel turns Ctrl-Alt-Del into SIGINT for
   PID 1, and every other Linux init reboots on it. It is listed here rather
   than left to the halt fallback because a keyboard trap that halts the
   machine instead of restarting it would be worse than the trap.

   Kept as its own function so the mapping is unit-testable without actually
   rebooting the machine that runs the test -- see tests/init-session.c. */
static int power_how(int sig) {
    /* kill me: three signals and three meanings, and the only way to find out
       which one the user meant is to guess. SIGTERM says reboot, SIGUSR2 says
       power off, everything else says halt. */
    if (sig == SIGTERM || sig == SIGINT) return RB_AUTOBOOT;
    if (sig == SIGUSR2) return RB_POWER_OFF;
    return RB_HALT_SYSTEM;              /* SIGUSR1, SIGPWR */
}

/* The power request handler.

   busybox's halt/poweroff/reboot applets do NOT call reboot(2) unless given
   -f; by default they signal PID 1 and expect it to do the orderly shutdown
   ("go through init"). Copper's PID 1 used to ignore SIGUSR1/SIGUSR2/SIGTERM,
   so `sudo reboot` and `sudo poweroff` silently did nothing (bug 18).
   sync() twice -- the second pass is the usual belt and braces for the
   persisted overlay upper -- then hand the machine to the kernel.

   If reboot(2) refuses, this used to _exit(0), which kills PID 1: the kernel
   panics "Attempted to kill init" and takes the reason down with it. The
   handler now reports on the console (write(2), because printf is not
   async-signal-safe; fd 2 is /dev/console, main() dup2s it there) and
   returns instead -- the session below keeps running and the machine stays
   up, which is the better failure for a live image. Returning makes the
   interrupted waitpid in the main loop come back with EINTR, so that loop
   retries rather than reading it as "the session ended" (two shells, one
   tty -- the bug described at spawn_tty).
   updated by farcrowx, bug 33, iso/src-init/copper-init.c:on_power_signal */
static void on_power_signal(int sig) {
    sync();
    sync();
    if (reboot(power_how(sig)) != 0) {
        static const char msg[] =
            "copper-init: reboot(2) failed; system stays up\n";
        write(STDERR_FILENO, msg, sizeof msg - 1);
    }
}

/* ---- the boot splash ------------------------------------------------------

   Plymouth draws the Copper boot animation and then hands the console back.
   It is started here, from PID 1, rather than by a service manager, because
   there is no service manager: copper-init is the init.

   Three things have to line up, and each is checked rather than assumed:

     - the kernel command line asks for it. grub.cfg passes "splash", and
       "plymouth.ignore-udev" and "plymouth.ignore-serial-consoles" beside it.
       The second is not optional: this image runs no udev, and without that
       switch plymouthd enumerates its devices through udev, finds nothing, and
       never draws a frame. With it, plymouthd takes its own fallback path and
       drives DRM or the framebuffer directly. The third is not optional
       either: the command line carries a serial console as well as the screen,
       and plymouthd reads any console= that is not the default VT as a serial
       console -- serial_consoles_detected is set and no renderer is ever
       created, so nothing is drawn at all (bug 25). splash_spawn() passes that
       one as an argument too, so it does not depend on the command line alone.

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

/* Fork the daemon. attach selects the console-redirecting form.

   --ignore-serial-consoles is the switch grub.cfg passes, passed again here:
   this image gives the kernel a serial console for the log beside the screen,
   and plymouthd reads a second active console as "the display is not here" --
   it forces its built-in text splash and creates no renderer at all (bug 25).
   Passing it as an argument too keeps the fix from depending on a command line
   a booting user can edit.

   It is worth passing because it is an option this plymouthd really has, not
   one assumed from plymouth's git tree: `plymouthd --help` from the packaged
   build (plymouth 24.004.60-1ubuntu7.2, the one this image stages) lists
   `--ignore-serial-consoles`, and a bogus option makes the same daemon print
   that whole list instead of starting. An option it did not know would leave
   the console on a usage dump and kill the splash outright, which is why this
   was checked against the .deb before being written here. */
static pid_t splash_spawn(int attach) {
    pid_t pid = fork();

    if (pid != 0)
        return pid;
    if (attach)
        execl("/usr/sbin/plymouthd", "plymouthd",
              "--mode=boot", "--pid-file=/run/plymouth/pid",
              "--attach-to-session", "--no-daemon",
              "--ignore-serial-consoles", (char *)NULL);
    else
        execl("/usr/sbin/plymouthd", "plymouthd",
              "--mode=boot", "--pid-file=/run/plymouth/pid",
              "--no-daemon", "--ignore-serial-consoles", (char *)NULL);
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

/* Set by --console: something else is PID 1 (systemd, once Copper makes that
   swap), and the half of this file that starts daemons is then somebody
   else's job -- the units own the daemons, this file owns only the console.
   see console_main(). */
static int g_console_only = 0;

/* The wizard, the session user, and the shell that waits for them.

   Everything from "is the wizard done?" down to the loop that respawns the
   session. Shared by both entry points: PID 1 (main), and a service under
   another init (--console). Nothing in here mounts anything, installs a
   signal handler or waits on a global child, so it is safe to reach from
   either. */
static void run_session(void) {
    struct stat st_done;
    if (stat("/etc/copper-firstboot.done", &st_done) != 0) {
        pid_t wiz = fork();
        if (wiz == 0) {
            /* The wizard needs a controlling terminal of its own. getpass()
               reads from /dev/tty rather than stdin, so without a session and
               an acquired tty it cannot open /dev/tty at all and the password
               questions come back unusable. Same treatment spawn_tty() gives
               the shell, pointed at /dev/console because that is where the
               wizard's stdout already goes -- except under --console, where
               the service's stdin already IS the console the user is looking
               at (the unit pins TTYPath=/dev/tty1) and /dev/console may well
               be a serial port instead. */
            setsid();
            int cfd = g_console_only ? dup(0) : open("/dev/console", O_RDWR);
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
       runs, and starting it here means the user never waits on it. Under
       --console there is a unit for that (copper-seatd.service) and it is
       ordered before this service, so starting a second seatd here would only
       be a second process failing to bind the same socket. */
    if (!g_console_only)
        start_seatd();

    /* Exactly one session at a time. Keep the pid so the reaper below can wait
       on this specific child instead of on any child: udhcpc is our child too,
       and `udhcpc -b` leaves a short-lived parent behind when it daemonises.

       waitpid(-1) would return on that exit and start a second copper-sh on the
       same tty, so two shells fought over stdin -- typing came out garbled and
       the banner printed twice. */
    for (;;) {
        /* The libudev records, before the shell for the same reason the seat
           is: the compositor needs them the moment starthyprland runs. Every
           pass, not just the first, so a session that logs out and back in --
           or a keyboard that only showed up later -- still gets its records.
           /run/udev is ours to make; there is no daemon to have made it, and
           the seeder makes the data/ directory under it.

           Skipped under --console, where systemd-udevd owns /run/udev and
           writes real records into it. Seeding here would put our guesses on
           top of the daemon's own answer, and a stale hand-written record is
           worse for libinput than no record at all. */
        if (!g_console_only) {
            mkdir("/run/udev", 0755);
            int typed = 0;
            int seeded = seed_udev_input_db("/sys/class/input",
                                            "/run/udev/data", &typed);
            if (seeded > 0) {
                say("input: wrote %d libudev record(s), %d naming a device type",
                    seeded, typed);
                /* A record with no type in it is a record libinput will not use,
                   and the session that follows looks like a working one: seat,
                   config and DRM all fine, with a pointer that does not move. Say
                   so here, where the only evidence is. */
                if (typed == 0)
                    say("input: none names a type, so libinput will ignore every device");
            } else {
                say("input: no /sys/class/input/event* node to seed yet");
            }
        }
        grant_devices(&g_session);
        prepare_session_dirs(&g_session);
        pid_t session = spawn_tty(1);
        int wst;
        /* EINTR, not a bare wait: the power handler in main() returns when
           reboot(2) fails, and a returning handler leaves the syscall it
           interrupted with EINTR. Read as "the session ended" that would
           spawn a second copper-sh on the same tty -- the two-shells bug
           described above -- so retry on EINTR and only treat a real reap as
           the session's end.
           updated by farcrowx, bug 33, iso/src-init/copper-init.c (main loop) */
        if (session > 0)
            while (waitpid(session, &wst, 0) < 0 && errno == EINTR)
                ;
    }
}

/* --console: the tty1 half of this file, run as a service under another init.

   This is the systemd entry point, and it is deliberately almost empty.
   Everything a real PID 1 does is left to the init that is actually PID 1:

     - mounting /proc, /sys, /dev and /run   -> already done before switch_root
     - the power signal handlers             -> systemd's job; SIGTERM on a
                                                service must mean "stop", not
                                                "reboot the machine from under
                                                the shutdown that asked"
     - hostname, DHCP, seatd, dbus, polkit    -> units (copper-*.service)
     - reaping orphans                        -> systemd reaps

   What is left is exactly what the console needs: a PATH, the wizard, the
   session user and the shell. The unit orders this after udevd and seatd and
   pins TTYPath=/dev/tty1, which is the tty spawn_tty() below opens. */
static int console_main(void) {
    g_console_only = 1;
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           1);
    run_session();
    return 0;                        /* never reached */
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--console") == 0)
        return console_main();

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

    /* Power signals get real handlers (see on_power_signal), and Ctrl-Alt-Del
       is one of them.

       The kernel turns Ctrl-Alt-Del into SIGINT for PID 1, and this init used
       to throw it away: SIGINT was SIG_IGN. That is invisible until a session
       stops responding -- dead input, a wedged compositor -- and then the one
       escape the kernel still offers, the one that works without a working
       session at all, is the one being ignored. A stuck screen had no way out
       but a power cycle. Every other Linux init reboots on Ctrl-Alt-Del, and
       so does this one now.

       SIGHUP stays ignored: a terminal hangup is not a reason to take the
       machine down. SIGCHLD is left at its default, because the reaper below
       relies on waitpid. */
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
    sigaction(SIGINT, &sa, NULL);       /* ctrl-alt-del -> reboot */
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

    /* Everything from here down is shared with the --console entry point:
       the wizard, the session user, and the loop that keeps a shell on tty1.
       It was split out when systemd became a possible PID 1 -- see
       run_session() above -- because both entry points want exactly this and
       neither wants the mounts, the signal handlers or the daemons. */
    run_session();
    return 0;                        /* never reached */
}