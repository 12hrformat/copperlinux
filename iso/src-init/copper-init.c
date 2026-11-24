/*
 * copper-init — Copper Linux PID 1.
 *
 * No systemd, no init scripts: this IS the init. It mounts the basics
 * (the initramfs already did most of it), applies the hostname, brings the
 * network up, runs the first-boot wizard once, then parks a Bash login
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

/* --console means systemd owns the daemons; this file owns only the console.
   Declared before say(), which keeps those lines serial-only. */
static int g_console_only;

/* Boot chatter goes to both the console and the serial port: /dev/console names
   just one of them. Under --console the console half is silent so it cannot
   corrupt the wizard's table or push the shell prompt down. */
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
    if (!g_console_only) {
        printf("copper: %s\n", line);
        fflush(stdout);
    }
    tty = fopen("/dev/ttyS0", "w");
    if (tty) {
        fprintf(tty, "copper: %s\n", line);
        fclose(tty);
    }
}

/* ARPHRD_ETHER: musl lacks the kernel UAPI headers; one number is not a dependency. */
#define ARPHRD_ETHER             1

/* /sys/class/net/<if>/type is the ARPHRD_* value in decimal, or -1 on error. */
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

/* Pick an interface by link type, not by name: built-in drivers invent sit0
   before the real NIC probes. Only a wired ARPHRD_ETHER will do. */
static const char *first_nonloop_iface(void) {
    static const int prefs[] = { ARPHRD_ETHER };
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

/* IFF_UP via ioctl: no subprocess and no guessing busybox's applet paths. */
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
/* udhcpc's lease script needs PATH; udhcpc never sets it. */
    setenv("PATH", "/sbin:/usr/sbin:/bin:/usr/bin", 1);
    snprintf(pidfile, sizeof pidfile, "/run/udhcpc.%s.pid", ifname);
    execl("/sbin/udhcpc", "udhcpc", "-i", ifname,
          "-s", "/usr/share/udhcpc/default.script", "-b", "-p", pidfile,
          (char *)NULL);
    _exit(127);
}

/* Bring the link up and start DHCP in the background so a slow server never
   holds up the wizard. */
static void bring_up_network(void) {
    char ifname[IFNAMSIZ] = "";
    int tries;

/* A VMware NIC can appear just after boot; give the bus a moment. */
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

/* The shell runs as the wizard's user, not uid 0 with HOME=/home/<user> --
   Firefox refuses that mismatch. Without a marker user it stays root. */
struct session {
    char name[64];
    char home[160];
    uid_t uid;
    gid_t gid;
    int ok;
};

static struct session g_session;

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

/* A configured shell must exist in the tree before use; fall back to the
   passwd entry, then bash. Returns a static path or NULL. */
static const char *configured_shell(void) {
    static char path[64];
    FILE *f = fopen("/etc/copper.conf", "r");
    if (!f) return NULL;
    char line[128];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = '\0';
        if (strncmp(line, "shell=", 6) != 0) continue;
        const char *v = line + 6;
        const char *want = NULL;
        if (strcmp(v, "zsh") == 0) want = "/usr/bin/zsh";
        else if (strcmp(v, "bash") == 0) want = "/usr/bin/bash";
        if (want && access(want, X_OK) == 0) {
            snprintf(path, sizeof path, "%s", want);
            fclose(f);
            return path;
        }
    }
    fclose(f);
    return NULL;
}

/* Fail open: a failed drop leaves a root shell rather than no session at all. */
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
/* Installers read $SHELL; an unset one killed an installer under `set -u`.
   The wizard's answer wins, then passwd, then bash. */
    const char *sh = configured_shell();
    if (!sh) {
        struct passwd *pw = getpwuid(s->uid);
        if (pw && pw->pw_shell && *pw->pw_shell) sh = pw->pw_shell;
    }
    setenv("SHELL", sh ? sh : "/usr/bin/bash", 1);
}

/* Xorg runs as the session user but no udev exists, so hand that user the
   input, DRM, framebuffer and VT nodes; missing nodes are not an error. */
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

/* Write libudev records by hand: with no udev daemon, libinput discards every
   device whose 'not initialized' flag is unset, and needs ID_INPUT_* tags
   beyond bare ID_INPUT or it drops the device anyway. Paths are arguments
   so tests can use a fixture; the return count is records written. */

/* Kernel input ABI numbers, spelled out because musl's wrapper cannot include
   <linux/input.h>. These are the values udev's input_id builtin compares. */
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

#define CAP_WORDS 16

struct capset {
    unsigned long long word[CAP_WORDS];
};

static void cap_read(struct capset *c, const char *dir, const char *attr) {
    memset(c, 0, sizeof *c);

/* 384 not 320: a truncated path looks like an unreadable attribute and a
   device silently becomes unclassifiable. */
    char path[384];
    snprintf(path, sizeof path, "%s/%s", dir, attr);
    FILE *f = fopen(path, "r");
    if (!f) return;

    char buf[512];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = '\0';

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

static int cap_test(const struct capset *c, unsigned bit) {
    return (bit >> 6) < CAP_WORDS
        && (int)((c->word[bit >> 6] >> (bit & 63)) & 1ULL);
}

static int cap_any(const struct capset *c, unsigned limit) {
    for (unsigned i = 0; i < CAP_WORDS && i * 64 < limit; i++) {
        unsigned long long v = c->word[i];
        if ((i + 1) * 64 > limit)
            v &= (1ULL << (limit - i * 64)) - 1ULL;
        if (v) return 1;
    }
    return 0;
}

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

/* Classify pointers and keyboards by udev's rules, not by approximations:
   an extra tag costs a setting, a missing one costs the device. */
static unsigned input_device_tags(const char *dir) {
    struct capset ev, key, rel, abs, props;
    cap_read(&ev, dir, "capabilities/ev");
    cap_read(&key, dir, "capabilities/key");
    cap_read(&rel, dir, "capabilities/rel");
    cap_read(&abs, dir, "capabilities/abs");
    cap_read(&props, dir, "properties");

    unsigned tags = 0;
    int is_pointer = 0;

    int has_keys = cap_test(&ev, EV_KEY);
    int has_abs_coordinates = cap_test(&abs, ABS_X) && cap_test(&abs, ABS_Y);
    int has_3d = has_abs_coordinates && cap_test(&abs, ABS_Z);
    int is_accelerometer = cap_test(&props, INPUT_PROP_ACCELEROMETER);
    if (!has_keys && has_3d)
        is_accelerometer = 1;

    if (is_accelerometer) {
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
        if (has_mt && cap_test(&abs, ABS_MT_SLOT) && cap_test(&abs, ABS_MT_SLOT - 1))
            has_mt = 0;
        int is_direct = cap_test(&props, INPUT_PROP_DIRECT);
        int has_touch = cap_test(&key, BTN_TOUCH);
        int has_pad_buttons = cap_test(&key, BTN_0) && cap_test(&key, BTN_1)
                           && !has_pen;
        int has_wheel = cap_test(&ev, EV_REL)
                     && (cap_test(&rel, REL_WHEEL) || cap_test(&rel, REL_HWHEEL));

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

        if (has_pad_buttons && has_wheel && !has_rel) {
            is_tablet = 1;
            is_tablet_pad = 1;
        }

        if (!is_tablet && !is_touchpad && !is_joystick && has_mouse_button
            && (has_rel || !has_abs_coordinates))
            is_mouse = 1;

        if (is_mouse && hex_attr(dir, "id/bustype") == BUS_I2C)
            is_pointing_stick = 1;

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

    int is_key = 0;
    if (cap_test(&ev, EV_KEY)) {
        int found = cap_any(&key, BTN_MISC);
        for (unsigned b = KEY_OK; b < BTN_DPAD_UP && !found; b++)
            if (cap_test(&key, b)) found = 1;
        for (unsigned b = KEY_ALS_TOGGLE; b < BTN_TRIGGER_HAPPY && !found; b++)
            if (cap_test(&key, b)) found = 1;
        if (!found) {
            for (unsigned b = 16; b < 40 && !found; b++)
                if (cap_test(&key, b)) found = 1; /* 'q' starts around 16 */
            if (!found) {
                for (unsigned b = 1; b < 0x60 && !found; b++)
                    if (cap_test(&key, b)) found = 1;
            }
            if (!found) {
                for (unsigned b = 0x80; b < 0xa0 && !found; b++)
                    if (cap_test(&key, b)) found = 1;
            }
        }
        if (found) {
            tags |= TAG_KEY;
            is_key = 1;
        }

        if ((key.word[0] & 0xFFFFFFFEULL) == 0xFFFFFFFEULL) {
            tags |= TAG_KEYBOARD;
            is_key = 1;
        } else if (tags & TAG_KEY) {
            if (!is_pointer || (tags & TAG_POINTINGSTICK)) {
                tags |= TAG_KEYBOARD;
                is_key = 1;
            }
        }
    }

    if (!is_pointer && !is_key && cap_test(&ev, EV_REL)
        && (cap_test(&rel, REL_WHEEL) || cap_test(&rel, REL_HWHEEL)))
        tags |= TAG_KEY;

/* Be permissive for VMs with odd capability bits: a keyboard with keys but no
   pointer role gets KEY+KEYBOARD so libinput accepts it. */
    if (!is_key && !is_pointer && cap_test(&ev, EV_KEY)) {
        int has_any_key = 0;
        for (unsigned b = 1; b < 255; b++) {
            if (cap_test(&key, b)) { has_any_key = 1; break; }
        }
        if (!has_any_key) {
            for (unsigned b = KEY_OK; b < BTN_DPAD_UP; b++) {
                if (cap_test(&key, b)) { has_any_key = 1; break; }
            }
        }
        if (has_any_key) {
            tags |= TAG_KEY | TAG_KEYBOARD;
            is_key = 1;
        }
    }

    if (cap_test(&ev, EV_SW))
        tags |= TAG_SWITCH;

    return tags;
}

static int is_input_device(const char *dir) {
    char probe[384];
    snprintf(probe, sizeof probe, "%s/capabilities/ev", dir);
    return access(probe, R_OK) == 0;
}

static int seed_udev_input_db(const char *sysdir, const char *dbdir, int *typed) {
    DIR *d = opendir(sysdir);
    if (!d) return 0;

/* Make the database leaf ourselves: no udev daemon will, and without it every
   fopen below fails and the boot log claims there are no input devices. */
    (void)mkdir(dbdir, 0755);

    unsigned long long usec = 0;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0)
        usec = (unsigned long long)ts.tv_sec * 1000000ULL
             + (unsigned long long)ts.tv_nsec / 1000ULL;

/* `src` can need 580 bytes; a truncated path silently skips a device. */
    char src[640], dst[320], num[64], devdir[320];
    int written = 0, named = 0;
    struct dirent *e;


/* Walk inputN, not eventN: the capabilities live on the input device, while
   the event node supplies the number used in the record's filename. */
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "input", 5) != 0) continue;
        snprintf(devdir, sizeof devdir, "%s/%s", sysdir, e->d_name);
        if (!is_input_device(devdir)) continue;

        unsigned tags = input_device_tags(devdir);

/* Say every verdict: libinput's drop is silent at the log level Aquamarine
   uses, and the sysfs name is what makes a bad classification actionable. */
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

/* PID 1 makes /dev/shm and /run/user/<uid>: the session user cannot mkdir
   under root-owned /dev or /run, and no PAM login creates them. */
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

/* First line of /etc/copper-desktop names the desktop; anything unreadable
   or unknown means XFCE, the one always present. */
enum {
    XFCE = 0,
    NIRI,
    HYPERRAND
};
static int chose_desktop(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return XFCE;
    char line[32] = "";
    if (fgets(line, sizeof line, f))
        line[strcspn(line, "\r\n")] = '\0';
    fclose(f);
    if (strcmp(line, "niri") == 0) return NIRI;
    if (strcmp(line, "hyprland") == 0) return HYPERRAND;
    return XFCE;
}

/* Kept separate so the contract stays tested: only the exact word "niri"
   selects niri; a missing or half-written marker means XFCE. */
static int chose_niri(const char *path) {
    return chose_desktop(path) == NIRI;
}

/* niri gets devices from seatd, which needs the _seatd group; XFCE does not
   need it. A missing seatd is reported, not fatal. */
static void start_seatd(void) {
    static const char *paths[] = { "/usr/bin/seatd", "/usr/sbin/seatd", NULL };
    const char *exe = NULL;
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) { exe = paths[i]; break; }
    }
    if (!exe) return;                 /* no niri in this image */

/* Recreate _seatd here if the build stage missed it: seatd looks the group
   up by name and exits early without it. */
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
    usleep(200 * 1000);
}

/* On VMware, start vmtoolsd so resolutionKMS tracks the window size; the DMI
   vendor check keeps it off elsewhere, and a missing package is harmless. */
static void start_vmtools(void) {
    static const char *paths[] = { "/usr/bin/vmtoolsd", "/usr/sbin/vmtoolsd", NULL };
    const char *exe = NULL;
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) { exe = paths[i]; break; }
    }
    if (!exe) return;                 /* open-vm-tools not in this image */

    char vendor[64] = "";
    FILE *vf = fopen("/sys/class/dmi/id/sys_vendor", "r");
    if (vf) {
        if (fgets(vendor, sizeof vendor, vf)) {
            char *nl = strchr(vendor, '\n');
            if (nl) *nl = '\0';
        }
        fclose(vf);
    }
    if (!strstr(vendor, "VMware")) return;

    pid_t pid = fork();
    if (pid < 0) {
        say("could not fork vmtoolsd: %s", strerror(errno));
        return;
    }
    if (pid == 0) {
        setsid();
        execl(exe, "vmtoolsd", "--background", (char *)NULL);
        _exit(127);
    }
    usleep(200 * 1000);
    say("VMware guest tools are up (the console follows the window size)");
}


/* Steal the tty with TIOCSCTTY(1) when it belongs to another session: under
   systemd the service already owns tty1, and without /dev/tty sudo cannot
   prompt for a password even though stdin and stdout work. */
static void acquire_ctty(int fd) {
    if (fd < 0) return;
    if (ioctl(fd, TIOCSCTTY, 0) == 0) return;
    (void)ioctl(fd, TIOCSCTTY, 1);
}

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
        acquire_ctty(fd);
        if (fd > 2) close(fd);
    }
    drop_to_session(&g_session);
    const char *sh = getenv("SHELL");
    if (sh && *sh) execl(sh, sh, (char *)NULL);
    execl("/usr/bin/bash", "-bash", (char *)NULL);
    execl("/usr/bin/copper-sh", "copper-sh", (char *)NULL);
    execl("/bin/sh", "sh", (char *)NULL);
    _exit(1);
}

static pid_t spawn_getty(int tty) {
    pid_t pid = fork();
    if (pid != 0) return pid;

    setsid();
    char name[16];
    snprintf(name, sizeof name, "tty%d", tty);
    execl("/sbin/getty", "getty", "-L", "38400", name, "linux",
          (char *)NULL);
    execl("/bin/busybox", "busybox", "getty", "-L", "38400", name,
          "linux", (char *)NULL);
    _exit(127);
}

/* busybox's halt/poweroff/reboot applets signal PID 1: SIGTERM and SIGINT
   reboot, SIGUSR2 powers off, the rest halt. Kept separate so the mapping
   is unit-testable without rebooting the test host. */
static int power_how(int sig) {
    if (sig == SIGTERM || sig == SIGINT) return RB_AUTOBOOT;
    if (sig == SIGUSR2) return RB_POWER_OFF;
    return RB_HALT_SYSTEM;              /* SIGUSR1, SIGPWR */
}

/* Applets signal PID 1 instead of calling reboot(2) directly; sync twice, then
   hand the machine to the kernel. A refused reboot must not _exit(0): that
   kills PID 1 and panics the kernel. Return so the waitpid loop retries.
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

/* Plymouth needs the cmdline switches (no udev, no serial consoles), both
   binaries present, and a daemon that answers before showing the splash;
   each is checked so a broken splash costs a pause, not a hung boot. */
static pid_t g_splash_pid = -1;

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

/* Pass --ignore-serial-consoles explicitly: it is a real option of the staged
   plymouthd (checked against --help), and without it the daemon draws nothing. */
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

/* Reap the daemon here: a zombie still answers kill(pid, 0). */
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

/* The console attach can fail; retry without it rather than lose the splash. */
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
    for (i = 0; i < 50 && splash_alive(); i++)
        usleep(20 * 1000);
    g_splash_pid = -1;
}


/* No systemd means nothing starts the system D-Bus, so polkit, udisks2 and
   power-profiles-daemon are unreachable. Start dbus-daemon here and repair
   the messagebus/polkitd accounts the unpacked .debs would have created;
   the paths are arguments so tests can use a fixture. */

static int file_has_name(const char *path, const char *name) {
    char line[512];
    size_t n = strlen(name);
    FILE *f = fopen(path, "r");

    if (!f)
        return 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, name, n) == 0 && line[n] == ':') {
            fclose(f);
            return 1;
        }
    }
    fclose(f);
    return 0;
}

static int file_has_id(const char *path, int id) {
    char line[512];
    FILE *f = fopen(path, "r");

    if (!f)
        return 0;
    while (fgets(line, sizeof line, f)) {
        char *p = strchr(line, ':');
        if (!p)
            continue;
        p = strchr(p + 1, ':');
        if (p && atoi(p + 1) == id) {
            fclose(f);
            return 1;
        }
    }
    fclose(f);
    return 0;
}

static int file_group_id(const char *path, const char *name, int *gid) {
    char line[512];
    size_t n = strlen(name);
    FILE *f = fopen(path, "r");

    if (!f)
        return 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, name, n) == 0 && line[n] == ':') {
            char *p = strchr(line, ':');
            p = p ? strchr(p + 1, ':') : NULL;
            if (p) {
                *gid = atoi(p + 1);
                fclose(f);
                return 1;
            }
        }
    }
    fclose(f);
    return 0;
}

static int next_free_id(const char *a, const char *b) {
    int id = 999;

    while (id > 100) {
        if (!file_has_id(a, id) && (!b || !file_has_id(b, id)))
            return id;
        id--;
    }
    return -1;
}

static int ensure_system_user(const char *passwd_path, const char *group_path,
                              const char *name, const char *home,
                              const char *shell) {
    int gid = -1, uid, id;
    FILE *f;

    if (file_has_name(passwd_path, name))
        return 0;

    if (!file_group_id(group_path, name, &gid)) {
        id = next_free_id(passwd_path, group_path);
        if (id < 0) {
            errno = ERANGE;
            return -1;
        }
        f = fopen(group_path, "a");
        if (!f)
            return -1;
        if (fprintf(f, "%s:x:%d:\n", name, id) < 0 || fclose(f) != 0)
            return -1;
        gid = id;
        uid = id;
    } else {
        uid = next_free_id(passwd_path, NULL);
        if (uid < 0) {
            errno = ERANGE;
            return -1;
        }
    }

    f = fopen(passwd_path, "a");
    if (!f)
        return -1;
    if (fprintf(f, "%s:x:%d:%d:%s:%s:%s\n", name, uid, gid, name, home,
                shell) < 0 || fclose(f) != 0)
        return -1;
    return 1;
}

static void start_system_bus(void) {
    static const char *paths[] = { "/usr/bin/dbus-daemon",
                                   "/bin/dbus-daemon", NULL };
    static const char sock[] = "/run/dbus/system_bus_socket";
    const char *exe = NULL;
    int made = 0, rc, st;
    pid_t pid;

    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) {
            exe = paths[i];
            break;
        }
    }
    if (!exe)
        return;                 /* no D-Bus in this image */

    if (access(sock, F_OK) == 0) {
        say("system bus: already running");
        return;
    }
    if (access("/usr/share/dbus-1/system.conf", R_OK) != 0) {
        say("system bus: no /usr/share/dbus-1/system.conf, so polkit and removable media stay unavailable");
        return;
    }

    rc = ensure_system_user("/etc/passwd", "/etc/group", "messagebus",
                            "/nonexistent", "/bin/false");
    if (rc < 0) {
        say("system bus: could not add the messagebus account: %s",
            strerror(errno));
        return;
    }
    made |= rc > 0;
    rc = ensure_system_user("/etc/passwd", "/etc/group", "polkitd",
                            "/nonexistent", "/bin/false");
    if (rc < 0) {
        say("polkit: could not add the polkitd account: %s", strerror(errno));
    } else {
        made |= rc > 0;
    }

    if (mkdir("/run/dbus", 0755) != 0 && errno != EEXIST) {
        say("system bus: could not make /run/dbus: %s", strerror(errno));
        return;
    }

    pid = fork();
    if (pid < 0) {
        say("system bus: could not fork dbus-daemon: %s", strerror(errno));
        return;
    }
    if (pid == 0) {
        execl(exe, "dbus-daemon", "--system", "--fork", (char *)NULL);
        _exit(127);
    }
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
    usleep(200 * 1000);

    if (access(sock, F_OK) == 0) {
        say("system bus: up%s", made ? " (created the missing service accounts)"
                                      : "");
    } else {
        say("system bus: dbus-daemon left no socket, so polkit and removable media stay unavailable");
    }
}


/* The Linux VT has one bitmap font and no per-glyph fallback, so box-drawing
   codepoints became '?' until Uni2-VGA16 was loaded. setfont is a busybox
   applet, so this works on the console-only boot too. */
static void load_console_font(void) {
    static const char font[] = "/usr/share/consolefonts/Uni2-VGA16.psf";
    static const char tty[] = "/dev/tty1";
    int st;
    pid_t p;

    if (access(font, R_OK) != 0 || access(tty, W_OK) != 0)
        return;
    p = fork();
    if (p == 0) {
        execl("/bin/busybox", "busybox", "setfont", "-C", tty, font,
              (char *)NULL);
        _exit(127);
    }
    if (p < 0)
        return;
    while (waitpid(p, &st, 0) < 0 && errno == EINTR)
        ;
}

/* Read one os-release field, quotes stripped. The path is an argument because
   the gate runs this against a fixture, not the build host's /etc. */
static void os_release_field(const char *path, const char *want,
                             char *out, size_t cap) {
    out[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f)
        return;
    char line[256];
    size_t wl = strlen(want);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, want, wl) != 0 || line[wl] != '=')
            continue;
        char *v = line + wl + 1;
        v[strcspn(v, "\r\n")] = '\0';
        size_t n = strlen(v);
        if (n >= 2 && v[0] == '"' && v[n - 1] == '"') {
            v[n - 1] = '\0';
            v++;
            n -= 2;
        }
        if (n >= cap)
            n = cap - 1;
        memcpy(out, v, n);
        out[n] = '\0';
        break;
    }
    fclose(f);
}

/* This is UI, not say() chatter: it must reach the tty the user is looking at.
   Use the escape sequence `clear` sends, not the binary, and print it on
   every respawn. The os-release path is an argument for fixture tests. */
static void print_welcome(const char *os_release) {
    char id[32], version[64];
    os_release_field(os_release, "ID", id, sizeof id);
    os_release_field(os_release, "VERSION_ID", version, sizeof version);

    printf("\033[H\033[2J\033[3J");
    printf("welcome to copper linux!\n");
    printf("\n");
    printf("type 'startniri' for niri and 'startxfce' for xfce\n");
/* Only report VERSION_ID when ID is copper, so a chroot cannot pass its own
   os-release off as ours; omit the line when it is absent. */
    if (strcmp(id, "copper") == 0 && version[0])
        printf("\nv%s\n", version);
    printf("\n");
    fflush(stdout);
}

static void run_session(void) {
/* Set LANG=C.UTF-8 before anything draws: otherwise setlocale("") gave C
   and tools painted a box per byte of their own art. C.UTF-8 needs no
   locale-gen; overwrite an inherited LANG. */
    setenv("LANG", "C.UTF-8", 0);

/* TERM=linux on the VT: bash invents "dumb" when none is set, which breaks
   readline's right margin and `clear`. Keep a real inherited TERM. */
    const char *term = getenv("TERM");
    if (!term || !*term || strcmp(term, "dumb") == 0)
        setenv("TERM", "linux", 1);

    load_console_font();

    struct stat st_done;
    if (stat("/etc/copper-firstboot.done", &st_done) != 0) {
        pid_t wiz = fork();
        if (wiz == 0) {
/* The wizard needs its own session and tty for getpass()/dev/tty; under
   --console the unit's tty1 is already the service's controlling terminal. */
            setsid();
            int cfd = g_console_only ? dup(0) : open("/dev/console", O_RDWR);
            if (cfd >= 0) {
                acquire_ctty(cfd);
                if (cfd > 2) close(cfd);
            }
            execl("/usr/bin/copper-firstboot", "copper-firstboot",
                  (char *)NULL);
            _exit(1);
        }
        int wst;
        waitpid(wiz, &wst, 0);
    }

/* Resolve the marker after the wizard wrote it; one read drives both cwd and
   the privilege drop. Root's cwd would otherwise be /, next to /boot and
   the block devices. */
    session_from_marker("/etc/copper-firstboot.done", &g_session);
    if (g_session.ok) {
        if (access(g_session.home, X_OK) == 0 && chdir(g_session.home) == 0) {
            setenv("HOME", g_session.home, 1);
            setenv("USER", g_session.name, 1);
            setenv("LOGNAME", g_session.name, 1);
        } else {
            printf("copper: no home directory at %s -- staying in /\n",
                   g_session.home);
        }
    }

/* The shell comes first: the X stack is not in the image yet, so auto-start
   would mean a blank screen with no way back. A shell also contains an X
   failure instead of losing the machine. */

    const char *hint;
    switch (chose_desktop("/etc/copper-desktop")) {
    case NIRI:
        hint = "startniri for niri (or startxfce for XFCE)";
        break;
    case HYPERRAND:
/* Name the install command too: starthyprland does not exist until the
   Hyprland payload is installed. */
        hint = "sudo ingot install hyprland, then starthyprland (or startxfce for XFCE)";
        break;
    default:
        hint = "startxfce for XFCE (or startniri for niri)";
        break;
    }
    say("type %s", hint);
    if (!g_console_only)
        say("Ctrl-Alt-F3 opens a password-protected login shell");

/* Start the seat and bus before the shell so niri and the polkit agent never
   wait on them; under --console units already own both. */
    if (!g_console_only) {
        start_system_bus();
        start_seatd();
        start_vmtools();
    }

/* Wait on this specific child: waitpid(-1) also catches udhcpc's short-lived
   parent and would start a second shell fighting over the same tty. */
    pid_t rescue = g_console_only ? -1 : spawn_getty(3);
    if (rescue > 0)
        say("getty running on tty3 (Ctrl-Alt-F3 for a login prompt)");
    else if (!g_console_only)
        say("could not start the tty3 login; the main shell remains on tty1");

    for (;;) {
/* Seed libudev records on every pass so a logout or late keyboard still gets
   them; skip under --console where systemd-udevd owns /run/udev. */
        if (!g_console_only) {
            mkdir("/run/udev", 0755);
            int typed = 0;
            int seeded = seed_udev_input_db("/sys/class/input",
                                            "/run/udev/data", &typed);
            if (seeded > 0) {
                say("input: wrote %d libudev record(s), %d naming a device type",
                    seeded, typed);
                if (typed == 0)
                    say("input: none names a type, so libinput will ignore every device");
            } else {
                say("input: no /sys/class/input/event* node to seed yet");
            }
        }
        grant_devices(&g_session);
        prepare_session_dirs(&g_session);
        print_welcome("/etc/os-release");
        pid_t session = spawn_tty(1);
        int session_status, rescue_status;
        while (session > 0) {
            pid_t got;
            do {
                got = waitpid(session, &session_status, WNOHANG);
            } while (got < 0 && errno == EINTR);
            if (got == session || (got < 0 && errno != ECHILD))
                break;
            if (got < 0 && errno == ECHILD)
                break;

            if (rescue > 0) {
                do {
                    got = waitpid(rescue, &rescue_status, WNOHANG);
                } while (got < 0 && errno == EINTR);
                if (got == rescue || (got < 0 && errno == ECHILD)) {
                    rescue = spawn_getty(3);
                    if (rescue < 0)
                        say("could not restart the tty3 login prompt");
                }
            }
            usleep(100 * 1000);
        }
    }
}

/* --console is almost empty: another init already did the mounts, signals and
   daemons. Only PATH, the wizard, the session and its shell remain. */
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

/* PID 1 gets no PATH from the kernel; execvp()'s default omits /sbin and
   /usr/sbin, so ip and ifconfig were 'not found' though installed. Setting
   it in a forked child was too late -- the shell never inherited it. */
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           1);

/* Handle the power signals, including SIGINT from Ctrl-Alt-Del: ignoring it
   left a wedged compositor with no keyboard escape but a power cycle.
   SIGHUP stays ignored and SIGCHLD at its default for waitpid. */
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

    splash_start();

    apply_hostname();

/* DHCP starts before the wizard so negotiation overlaps typing. */
    bring_up_network();

/* udhcpc prints to the wizard's console; a fixed beat after the lease keeps
   questions readable without waiting on a slow server. */
    usleep(1500 * 1000);
    printf("\n");
    fflush(stdout);

/* Quit the splash before anything interactive so the VT is back in text mode. */
    splash_stop();

    run_session();
    return 0;                        /* never reached */
}
