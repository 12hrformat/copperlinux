/*
 * copper-firstboot — first-boot personalization, in the spirit of the OOBE
 * handcrafted by farcrowx
 * on real distros / Windows. copper-init runs this once (until the marker
 * /etc/copper-firstboot.done exists).
 *
 * Asks for: name, username, hostname, timezone, and passwords (root + the
 * named user). Creates the account via busybox adduser, sets passwords via
 * busybox chpasswd, wires up /etc/localtime.
 *
 * Live-session only for now (the overlay is tmpfs, so it re-runs next
 * boot) — real persistence is a later phase.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void banner(void) {
    printf("\n===================================================\n");
    printf("         Welcome to Copper Linux\n");
    printf("===================================================\n");
    printf("Made by farcrowx and 12hrformat\n");
    printf("A couple of questions and you're in. (This is a live\n");
    printf("session, so answers apply for now — persistence is\n");
    printf("coming in a later build.)\n\n");
}

static int read_line(char *buf, size_t cap) {
    if (!fgets(buf, cap, stdin)) return 0;
    buf[strcspn(buf, "\r\n")] = '\0';
    return 1;
}

static int valid_user(const char *u) {
    if (!u[0]) return 0;
    size_t n = strlen(u);
    if (n > 32) return 0;
    if (!(isalpha((unsigned char)u[0]) || u[0] == '_')) return 0;
    for (const char *p = u + 1; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '-'))
            return 0;
    return 1;
}

static int valid_host(const char *h) {
    if (!h[0]) return 0;
    size_t n = strlen(h);
    if (n > 63) return 0;
    for (const char *p = h; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '-' || *p == '.'))
            return 0;
    return 1;
}

static int valid_tz(const char *z) {
    if (!z[0] || strlen(z) > 100) return 0;
    for (const char *p = z; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '-' ||
              *p == '+' || *p == '/'))
            return 0;
    return 1;   /* bare zones (UTC) and paths (America/New_York) both OK */
}

/* password reading: silent when a tty is available, plain fallback otherwise */
static void read_password(const char *prompt, char *buf, size_t cap,
                          const char *confirm_prompt) {
    char again[256];
    for (;;) {
        char *p = getpass(prompt);
        if (!p) {
            printf("(no silent input available — type it plainly)\n");
            if (!read_line(buf, cap)) buf[0] = '\0';
        } else if (strlen(p) < cap) {
            snprintf(buf, cap, "%s", p);
        }

        if (confirm_prompt) {
            char *q = getpass(confirm_prompt);
            if (!q) {
                if (!read_line(again, sizeof again)) again[0] = '\0';
            } else if (strlen(q) < sizeof again) {
                snprintf(again, sizeof again, "%s", q);
            }
            if (buf[0] && strcmp(buf, again) == 0) return;
            printf("Those didn't match — try again.\n");
            continue;
        }
        if (buf[0]) return;
        printf("Password can't be empty.\n");
    }
}

/* run a shell command with absolute busybox; input is pre-validated */
static int run(const char *fmt, ...) {
    char cmd[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    return system(cmd);
}

static void set_password(const char *user, const char *pw) {
    char line[1024];
    snprintf(line, sizeof line, "%s:%s\n", user, pw);
    FILE *p = popen("/bin/busybox chpasswd 2>/dev/null", "w");
    if (p) {
        fputs(line, p);
        pclose(p);
    }
}

int main(void) {
    char name[128]  = "";
    char user[64]   = "";
    char host[64]   = "copper";
    char tz[128]    = "UTC";
    char rootpw[256];
    char userpw[256];

    banner();

    printf("Your name: ");
    read_line(name, sizeof name);
    if (!name[0]) snprintf(name, sizeof name, "friend");

    do {
        printf("Username [letters, digits, - _]: ");
        read_line(user, sizeof user);
    } while (!valid_user(user));

    printf("Hostname [copper]: ");
    {
        char h[64] = "";
        if (read_line(h, sizeof h) && h[0] && valid_host(h))
            snprintf(host, sizeof host, "%s", h);
    }

    read_password("Password (root): ", rootpw, sizeof rootpw,
                  "Confirm root password: ");

    printf("Timezone [UTC]: ");
    {
        char z[128] = "";
        if (read_line(z, sizeof z) && z[0] && valid_tz(z))
            snprintf(tz, sizeof tz, "%s", z);
    }

    /* --- apply ------------------------------------------------------- */

    printf("\nSetting things up...\n");

    /* hostname + hosts */
    run("echo %s > /etc/hostname", host);
    run("echo '127.0.0.1 localhost %s' > /etc/hosts", host);
    run("echo '::1 localhost ip6-localhost ip6-loopback' >> /etc/hosts");
    run("/bin/busybox hostname %s", host);

    /* the named user, with copper-sh as their login shell */
    if (run("/bin/busybox adduser -h /home/%s -s /usr/bin/copper-sh "
            "-G users,audio,video,dialout,cdrom %s", user, user) != 0) {
        printf("Couldn't create user %s.\n", user);
        return 1;
    }
    read_password("Password (for you): ", userpw, sizeof userpw,
                  "Confirm your password: ");
    set_password("root", rootpw);
    set_password(user, userpw);

    /* timezone */
    {
        char zfile[160];
        snprintf(zfile, sizeof zfile, "/usr/share/zoneinfo/%s", tz);
        if (access(zfile, R_OK) == 0) {
            run("ln -sf /usr/share/zoneinfo/%s /etc/localtime", tz);
            run("echo %s > /etc/timezone", tz);
        } else {
            printf("(timezone %s not found — staying on UTC)\n", tz);
        }
    }

    /* done marker */
    {
        FILE *m = fopen("/etc/copper-firstboot.done", "w");
        if (m) {
            fprintf(m, "%s\n", name);
            fclose(m);
        }
    }

    printf("\n===================================================\n");
    printf("  Done — welcome, %s.\n", name);
    printf("  Copper is yours. Type 'help' to see builtins.\n");
    printf("===================================================\n\n");
    return 0;
}
