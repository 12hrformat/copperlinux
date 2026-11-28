/*
 * copper-firstboot — first-boot personalization, in the spirit of the OOBE
 * on real distros / Windows. copper-init runs this once (until the marker
 * /etc/copper-firstboot.done exists).
 *
 * Draws the boot animation, then a centred table of every question, then
 * applies the answers.
 *
 * Live-session only for now (the overlay is tmpfs, so it re-runs next
 * boot) — real persistence is a later phase.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

static void banner(void) {
    printf("\n===================================================\n");
    printf("         Welcome to Copper Linux\n");
    printf("===================================================\n");
    printf("A couple of questions and you're in. This is a live\n");
    printf("session: it runs from the ISO, and at the end you can\n");
    printf("hand it a spare disk so your files are kept.\n\n");
}

/* stdin_eof: a rejected answer with closed stdin spins forever. */
static int stdin_eof;

static int read_line(char *buf, size_t cap) {
    if (!fgets(buf, cap, stdin)) { stdin_eof = 1; return 0; }
    buf[strcspn(buf, "\r\n")] = '\0';
    return 1;
}


static int term_cols = 80, term_rows = 25;

/* Query the terminal: VGA lies about size, and serial/pty windows differ. */
static void term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
        term_cols = ws.ws_col;
        term_rows = ws.ws_row;
    }
}

/* A real terminal only: on a serial console this would erase scrollback. */
static int ui_fancy;

static void ui_init(void) {
    term_size();
    ui_fancy = isatty(STDOUT_FILENO) && isatty(STDIN_FILENO) &&
               term_cols >= 46 && term_rows >= 14;
}

static void msleep(int ms) { usleep((useconds_t)ms * 1000); }

/* Reset the scroll region before erasing: otherwise \033[H homes to the
   region's top and a scrolled console draws everything low. */
static void clr(void)      { fputs("\033[r\033[2J\033[H", stdout); }
static void at(int r, int c) { printf("\033[%d;%dH", r, c); }

/* Only account questions: desktop/shell/audio/init are details with working defaults. */
enum { F_NAME, F_USER, F_HOST, F_ROOTPW, F_USERPW, F_TZ, F_COUNT };

#define FIELD_CAP 192

static int valid_user(const char *s);
static int valid_host(const char *s);
static int valid_tz(const char *s);

struct field {
    const char *label;
/* Help lives under the table; in the value cell it left debris after typed characters. */
    const char *help;
    const char *ask;       /* the status line while this one is live */
    const char *reject;    /* why the last answer was not accepted */
    char value[FIELD_CAP];
    int  secret;
    int  has_value;
/* Validate every answer pasted into a shell command (hostname, timezone) before use. */
    int (*ok)(const char *);
};

static int ok_host(const char *s) { return !s[0] || valid_host(s); }
static int ok_tz(const char *s)   { return !s[0] || valid_tz(s); }
static int ok_pw(const char *s)   { return s[0] != '\0'; }


/* Initialise every field member: a missing `secret` would print a password. */
#define FIELD(lbl, hlp, prompt, rej, sec, chk) \
    { (lbl), (hlp), (prompt), (rej), {0}, (sec), 0, (chk) }

static struct field fields[F_COUNT] = {
    FIELD("Your name",     "Enter alone to use \"friend\"",
          "What should Copper call you?", 0, 0, NULL),
    FIELD("Username",      "letters, digits, dash and underscore",
          "Pick a login name", "Letters, digits, dash and underscore only", 0, valid_user),
    FIELD("Hostname",      "Enter alone to use \"copper\"",
          "Name this machine",
          "Letters, digits, dot and dash only", 0, ok_host),
    FIELD("Root password", 0,
          "Set the root password",
          "A password cannot be blank", 1, ok_pw),
    FIELD("Your password", 0,
          "Set your own password",
          "A password cannot be blank", 1, ok_pw),
    FIELD("Timezone",      "Enter alone to use \"UTC\", or Europe/London",
          "Timezone, e.g. Europe/London",
          "That does not look like a timezone", 0, ok_tz),
};

#define LABEL_COL 18

#define BOX_PAD 3

/* VALUE_COL derives from the same row geometry, so cursor and text cannot disagree. */
#define VALUE_COL (box_left + 1 + BOX_PAD + LABEL_COL + 2)

static int box_w(void) {
    int w = term_cols - 8;
    if (w > 66) w = 66;
    if (w < 40) w = 40;
    return w;
}

static int box_left;

static void box_begin(int w, int rows) {
    box_left = (term_cols - w) / 2;
    if (box_left < 0) box_left = 0;
    (void)rows;
}

/* Absolute rows only: cursor-relative layout drifts after any scrolling. */
static void box_line(const char *text, int w, int row) {
    int room = w - 2;
    int len = (int)strlen(text);
/* Truncate, never wrap: a wrapped status line tears a hole in the table wall. */
    if (len > room) len = room;
    int pad = room - len;
    at(row, box_left + 1);
    printf("|%.*s%*s|", len, text, pad, "");
}

static void box_rule(int w, int row) {
    char bar[80];
    memset(bar, '-', (size_t)(w - 2));
    bar[w - 2] = '\0';
    at(row, box_left + 1);
    printf("+%s+", bar);
}

static void render_form(int active, const char *status) {
    int w = box_w();
    int total = 4 + F_COUNT + 2;
    int top = (term_rows - total) / 2;
    if (top < 1) top = 1;   /* screen rows are 1-based; row 0 is not a row */

    clr();
    box_begin(w, total);

    int r = top;
    box_rule(w, r++);
    box_line("   Copper Linux  -  first boot setup", w, r++);
    box_rule(w, r++);

    const int first_field = r;

    for (int i = 0; i < F_COUNT; i++, r++) {
        char shown[220];
        const struct field *f = &fields[i];
        if (f->secret && f->has_value) {
            int n = (int)strlen(f->value);
            if (n > 40) n = 40;
            for (int k = 0; k < n; k++) shown[k] = '*';
            shown[n] = '\0';
        } else if (f->has_value) {
            snprintf(shown, sizeof shown, "%s", f->value);
        } else {
            shown[0] = '\0';     /* empty. Never a hint -- see struct field. */
        }
        char row[256];
        snprintf(row, sizeof row, "%*s%-*s %s", BOX_PAD, "", LABEL_COL,
                 f->label, shown);
        box_line(row, w, r);
    }

    box_rule(w, r++);

    char line[256];
    const char *help =
        (active >= 0 && active < F_COUNT) ? fields[active].help : 0;
    if (help && *help)
        snprintf(line, sizeof line, " %s  --  %s", status, help);
    else
        snprintf(line, sizeof line, " %s", status);
    box_line(line, w, r++);
    box_rule(w, r);

    if (active >= 0) at(first_field + active, VALUE_COL);
}


static struct termios saved_tio;
static int raw_on;

/* Raw mode, but keep ISIG so Ctrl-C still kills the wizard. */
static void raw_begin(void) {
    if (!isatty(STDIN_FILENO)) return;
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) != 0) return;
    saved_tio = t;
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0) raw_on = 1;
}

static void raw_end(void) {
    if (raw_on) { tcsetattr(STDIN_FILENO, TCSANOW, &saved_tio); raw_on = 0; }
}

static void erase_left(int n) {
    while (n-- > 0) { putchar('\b'); putchar(' '); putchar('\b'); }
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
/* `hostname %s` has no `--`: a leading dash would be read as an option. */
    if (*h == '-') return 0;
    for (const char *p = h; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '-' || *p == '.'))
            return 0;
    return 1;
}

static int valid_tz(const char *z) {
    if (!z[0] || strlen(z) > 100) return 0;
/* Same reason: this value reaches `ln -sf` and `echo > /etc/timezone`. */
    if (*z == '-') return 0;
    for (const char *p = z; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '-' ||
              *p == '+' || *p == '/'))
            return 0;
    return 1;   /* bare zones (UTC) and paths (America/New_York) both OK */
}

/* Account files ship with no trailing newline; appending welds two records into
   one unparseable line, so add the missing byte before any append. */
static void ensure_trailing_newline(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fseek(f, -1, SEEK_END) == 0 && fgetc(f) != '\n') {
        fclose(f);
        FILE *w = fopen(path, "a");
        if (w) { fputc('\n', w); fclose(w); }
        return;
    }
    fclose(f);
}

/* Write the three account files directly: busybox adduser has failed twice here,
   and the format is ours. Returns 0 on success. */
static int create_user_direct(const char *user, const char *shell) {
/* Nine shadow fields versus seven passwd fields: one colon decides login. */
    ensure_trailing_newline("/etc/passwd");
    ensure_trailing_newline("/etc/group");
    ensure_trailing_newline("/etc/shadow");

    FILE *chk = fopen("/etc/passwd", "r");
    if (chk) {
        char line[512];
        while (fgets(line, sizeof line, chk)) {
            if (strncmp(line, user, strlen(user)) == 0 && line[strlen(user)] == ':') {
                fclose(chk);
                return 0;      /* present already, not a failure */
            }
        }
        fclose(chk);
    }

/* uid is the THIRD passwd field; reading the password field gave atoi("x")==0
   and handed every account 1000, so avoid the ids actually in use. */
    int uid = 1000;
    FILE *p = fopen("/etc/passwd", "r");
    if (p) {
        char line[512];
        int used[65536];
        memset(used, 0, sizeof used);
        while (fgets(line, sizeof line, p)) {
            char *c1 = strchr(line, ':');
            if (!c1) continue;
            char *c2 = strchr(c1 + 1, ':');
            if (!c2) continue;
            int v = atoi(c2 + 1);          /* third field: uid */
            if (v > 0 && v < 65536) used[v] = 1;
        }
        fclose(p);
        while (uid < 65535 && used[uid]) uid++;
        if (uid >= 65535) return 1;   /* no id left; do not reuse one */
    }

    char home[128], gecos[256];
    snprintf(home, sizeof home, "/home/%s", user);
    snprintf(gecos, sizeof gecos, "%s", user);

    int have_group = 0;
    FILE *g = fopen("/etc/group", "r");
    if (g) {
        char line[512];
        while (fgets(line, sizeof line, g))
            if (strncmp(line, user, strlen(user)) == 0 && line[strlen(user)] == ':') {
                have_group = 1; break;
            }
        fclose(g);
    }
    if (!have_group) {
        g = fopen("/etc/group", "a");
        if (g) { fprintf(g, "%s:x:%d:\n", user, uid); fclose(g); }
    }

    p = fopen("/etc/passwd", "a");
    if (!p) return 1;
    fprintf(p, "%s:x:%d:%d:%s:%s:%s\n",
            user, uid, uid, gecos, home, shell);
    fclose(p);

/* Start locked so there is no empty-password window. Shadow has nine fields;
   an empty lastchg shifts them all and no parser accepts the record. */
    int have_shadow = 0;
    FILE *s = fopen("/etc/shadow", "r");
    if (s) {
        char line[512];
        while (fgets(line, sizeof line, s))
            if (strncmp(line, user, strlen(user)) == 0 && line[strlen(user)] == ':') {
                have_shadow = 1; break;
            }
        fclose(s);
    }
    if (!have_shadow) {
        s = fopen("/etc/shadow", "a");
        if (s) { fprintf(s, "%s:!:0:0:99999:7:::\n", user); fclose(s); }
    }

    if (mkdir(home, 0755) != 0 && errno != EEXIST) {
        printf("(note: couldn't create %s)\n", home);
    }
    chown(home, uid, uid);
/* A setgid /home (seen as drwxr-sr-x on the live image) makes every later
   file inherit the group. Nothing here needs it; clear it on both paths. */
    chmod(home, 0755);

    const char *skel = "/etc/skel";
    if (access(skel, R_OK) == 0) {
        DIR *d = opendir(skel);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != NULL) {
                if (de->d_name[0] == '.') continue;
                char from[512], to[512];
                if (snprintf(from, sizeof from, "%s/%s", skel, de->d_name)
                        >= (int)sizeof from) continue;
                if (snprintf(to, sizeof to, "%s/%s", home, de->d_name)
                        >= (int)sizeof to) continue;
                struct stat st;
                if (stat(from, &st) == 0 && S_ISREG(st.st_mode)) {
                    /* ignore failures: a missing dotfile is not worth a boot */
                    (void)remove(to);
                    if (link(from, to) != 0) { /* hardlink, else copy */
                        FILE *in = fopen(from, "r"), *out = fopen(to, "w");
                        if (in && out) {
                            char buf[4096]; size_t n;
                            while ((n = fread(buf, 1, sizeof buf, in)) > 0)
                                fwrite(buf, 1, n, out);
                        }
                        if (in) fclose(in);
                        if (out) fclose(out);
                    }
                    chown(to, uid, uid);
                }
            }
            closedir(d);
        }
    }

    return 0;
}

/* getpass() needs a controlling tty the forked wizard lacks; when it fails,
   print the prompt ourselves so the answer is not typed blind. */
static void ask_password(const char *prompt, char *buf, size_t cap) {
    char *p = getpass(prompt);
    if (p) {
        if (strlen(p) < cap)
            snprintf(buf, cap, "%s", p);
        else
            buf[0] = '\0';
        return;
    }
    printf("%s", prompt);
    fflush(stdout);
    if (!read_line(buf, cap)) buf[0] = '\0';
}

static void read_password(const char *prompt, char *buf, size_t cap,
                          const char *confirm_prompt) {
    char again[256];
    for (;;) {
        ask_password(prompt, buf, cap);
/* stdin_eof: closed stdin here would spin this retry loop printing errors. */
        if (stdin_eof) return;

        if (confirm_prompt) {
            ask_password(confirm_prompt, again, sizeof again);
            if (stdin_eof) return;
            if (buf[0] && strcmp(buf, again) == 0) return;
            printf("Those didn't match — try again.\n");
            fflush(stdout);
            continue;
        }
        if (buf[0]) return;
        printf("Password can't be empty.\n");
        fflush(stdout);
    }
}

static int run(const char *fmt, ...) {
    char cmd[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    return system(cmd);
}

/* Discard busybox's routine warnings: they buried the prompt and looked like a re-ask. */
static int run_quiet(const char *fmt, ...) {
    char cmd[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    char quiet[1200];
    snprintf(quiet, sizeof quiet, "%s >/dev/null 2>&1", cmd);
    return system(quiet);
}

/* Diagnostics on failure, silence on success. `fmt` must be the last named
   parameter or va_start reads garbage. */
static int run_capture(char *out, size_t cap, const char *fmt, ...) {
    char cmd[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);

    char wrapped[1200];
    snprintf(wrapped, sizeof wrapped, "%s 2>&1", cmd);

    out[0] = '\0';
    FILE *p = popen(wrapped, "r");
    if (!p) return -1;

    size_t n = fread(out, 1, cap - 1, p);
    out[n] = '\0';
    int rc = pclose(p);
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) out[--n] = '\0';
    return rc;
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


static void type_into(int idx, const char *status, char *dest, size_t cap) {
    struct field *f = &fields[idx];

/* Cap input to the box width so a long answer cannot wrap and tear it. */
    int maxlen = box_w() - LABEL_COL - 8;
    if (maxlen > (int)cap - 1) maxlen = (int)cap - 1;
    if (maxlen < 1) maxlen = 1;

    render_form(idx, status);
    dest[0] = '\0';
    int n = 0;

    for (;;) {
        int c = getchar();
/* Record EOF, not just an empty answer, or the retry loops never end. */
        if (c == EOF) { dest[n] = '\0'; stdin_eof = 1; return; }
        if (c == '\r' || c == '\n') break;
        if (c == 127 || c == 8) {                 /* backspace */
            if (n > 0) { n--; erase_left(1); }
            continue;
        }
        if (c == 21) {                            /* Ctrl-U clears the field */
            erase_left(n);
            n = 0;
            continue;
        }
        if (c < 32 || c > 126) continue;          /* arrows, function keys */
        if (n >= maxlen) continue;
        dest[n++] = (char)c;
        putchar(f->secret ? '*' : (char)c);
    }
    dest[n] = '\0';
}

static void collect(int idx) {
    struct field *f = &fields[idx];
    f->has_value = 0;
    f->value[0] = '\0';

    if (ui_fancy) {
        raw_begin();
        const char *status = f->ask;
        for (;;) {
            if (f->secret) {
                type_into(idx, status, f->value, sizeof f->value);
                char again[FIELD_CAP];
                fields[idx].has_value = 0;
                type_into(idx, "Type it once more to be sure",
                          again, sizeof again);
/* EOF mid-confirmation must stop the loop, not re-ask forever. */
                if (stdin_eof) break;
                if (again[0] && strcmp(again, f->value) == 0) break;
                f->value[0] = '\0';
                msleep(900);
                continue;
            }
            type_into(idx, status, f->value, sizeof f->value);
            if (stdin_eof) break;   /* same, for the validating fields */
            if (f->ok && !f->ok(f->value)) {
                f->value[0] = '\0';
                status = f->reject;
                continue;
            }
            break;
        }
        raw_end();
        f->has_value = 1;
        return;
    }

    char buf[FIELD_CAP] = "";
    switch (idx) {
    case F_NAME:
        printf("Your name: ");
        fflush(stdout);
        read_line(buf, sizeof buf);
        break;
    case F_USER:
        for (;;) {
            printf("Username [letters, digits, - _]: ");
            fflush(stdout);
            if (!read_line(buf, sizeof buf)) {
/* EOF gets a known-valid name instead of spinning. */
                snprintf(buf, sizeof buf, "%s", "copper");
                break;
            }
            if (valid_user(buf)) break;
            printf("Letters, digits, dash and underscore only.\n");
        }
        break;
    case F_HOST:
        printf("Hostname [copper]: ");
        fflush(stdout);
        if (read_line(buf, sizeof buf) && buf[0] && !valid_host(buf))
            buf[0] = '\0';
        break;
    case F_ROOTPW:
        read_password("Password (root): ", buf, sizeof buf,
                      "Confirm root password: ");
        break;
    case F_USERPW:
        read_password("Password (for you): ", buf, sizeof buf,
                      "Confirm your password: ");
        break;
    case F_TZ:
        printf("Timezone [UTC]: ");
        fflush(stdout);
        if (read_line(buf, sizeof buf) && buf[0] && !valid_tz(buf))
            buf[0] = '\0';
        break;
    }
    snprintf(f->value, sizeof f->value, "%s", buf);
    f->has_value = 1;
}


static const char *const apply_steps[] = {
    "hostname and networking", "your account", "passwords", "timezone", NULL
};

static void draw_progress(int upto) {
    if (!ui_fancy) return;
    int w = box_w();
    int n = 0;
    while (apply_steps[n]) n++;
    int total = 4 + n + 2;
    int top = (term_rows - total) / 2;
    if (top < 1) top = 1;

    clr();
    box_begin(w, total);

    int r = top;
    box_rule(w, r++);
    box_line("   Copper Linux  -  setting things up", w, r++);
    box_rule(w, r++);
    for (int i = 0; i < n; i++, r++) {
        char row[256];
        snprintf(row, sizeof row, "%*s[%c] %s", BOX_PAD, "",
                 i < upto ? 'x' : ' ', apply_steps[i]);
        box_line(row, w, r);
    }
    box_rule(w, r++);
    box_line(" one moment", w, r++);
    box_rule(w, r);

/* Park below the box so the next diagnostic cannot overwrite its bottom wall. */
    int park = r + 1;
    if (park > term_rows) park = term_rows;
    at(park, 1);
}

static void screen_done(const char *name) {
    if (!ui_fancy) {
        printf("\n===================================================\n");
        printf("  Done -- welcome, %s.\n", name);
        printf("  Copper is yours. Type 'help' to see builtins.\n");
        printf("===================================================\n\n");
        return;
    }
    int w = box_w();
    int top = (term_rows - 5) / 2;
    if (top < 1) top = 1;

    clr();
    box_begin(w, 5);

    int r = top;
    box_rule(w, r++);
    {
        char l1[256], l2[256], l3[256];
        snprintf(l1, sizeof l1, "%*sDone -- welcome, %s.", BOX_PAD, "", name);
        snprintf(l2, sizeof l2, "%*sCopper is yours.", BOX_PAD, "");
        snprintf(l3, sizeof l3, "%*sType 'copper help' for Copper commands.",
                 BOX_PAD, "");
        box_line(l1, w, r++);
        box_line(l2, w, r++);
        box_line(l3, w, r++);
    }
    box_rule(w, r);
    msleep(2600);
    clr();
}


/* A COPPER-labelled spare disk becomes the writable layer, saving the session.
   Only real Copper boots are offered one; boot media and mounted disks are never
   candidates, and anything non-empty needs an explicit ERASE. */
#define PERSIST_MARKER "/var/lib/copper/live-boot"
#define PERSIST_MAX_DISKS 16
#define PERSIST_NAME 32

/* Test-bench overrides: skip the countdown and never reboot the test host. */
#define PERSIST_SECONDS_ENV "COPPER_PERSIST_SECONDS"
#define PERSIST_NOREBOOT_ENV "COPPER_PERSIST_NO_REBOOT"

/* Marker names the boot disk and current upper layer, bare of /dev/. */
static char boot_media_disk[PERSIST_NAME];
static char boot_upper_disk[PERSIST_NAME];

static void read_boot_marker(void) {
    boot_media_disk[0] = '\0';
    boot_upper_disk[0] = '\0';
    FILE *f = fopen(PERSIST_MARKER, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl) *nl = '\0';
        const char *v = NULL;
        char *dst = NULL;
        if (strncmp(line, "media=", 6) == 0) { v = line + 6; dst = boot_media_disk; }
        else if (strncmp(line, "upper=", 6) == 0) { v = line + 6; dst = boot_upper_disk; }
        if (!v) continue;
        if (strncmp(v, "/dev/", 5) == 0) v += 5;
        if (strcmp(v, "ram") == 0) dst[0] = '\0';
        else snprintf(dst, PERSIST_NAME, "%s", v);
    }
    fclose(f);
}

/* Partitions belong to their whole disk; a shared prefix does not. */
static int dev_is_part_of(const char *dev, const char *disk) {
    size_t dl = strlen(disk);
    if (dl == 0 || dev[0] == '\0') return 0;
    if (strncmp(dev, disk, dl) != 0) return 0;
    char nxt = dev[dl];
    return nxt == '\0' || (nxt >= '0' && nxt <= '9') || nxt == 'p';
}

static int is_boot_medium(const char *disk) {
    return boot_media_disk[0] && dev_is_part_of(boot_media_disk, disk);
}

/* Never wipe the marker's upper disk, even if /proc/mounts disagrees. */
static int is_upper_disk(const char *disk) {
    return boot_upper_disk[0] && dev_is_part_of(boot_upper_disk, disk);
}

/* Only attachable whole disks: sd, vd, nvme, mmcblk and hd for old IDE guests.
   /sys/block has no partitions and excludes loop, ram, dm, md and cdrom. */
static int is_disk_name(const char *n) {
    return strncmp(n, "sd", 2) == 0 || strncmp(n, "vd", 2) == 0 ||
           strncmp(n, "nvme", 4) == 0 || strncmp(n, "mmcblk", 6) == 0 ||
           strncmp(n, "hd", 2) == 0;
}

/* Any mount of the disk or a partition refuses the format. */
static int disk_in_use(const char *disk) {
    FILE *f = fopen("/proc/mounts", "r");
    if (!f) return 1;                    /* cannot prove it is free: refuse */
    char line[512];
    int used = 0;
    while (fgets(line, sizeof line, f)) {
        char *sp = strchr(line, ' ');
        if (!sp) continue;
        *sp = '\0';
        const char *dev = line;
        if (strncmp(dev, "/dev/", 5) == 0) dev += 5;
        if (dev_is_part_of(dev, disk)) {
            used = 1;
            break;
        }
    }
    fclose(f);
    return used;
}

/* blkid's exit status is a lie: decide from output, and search the same way
   mkfs.ext4 is because the wizard's PATH is inherited. */
static int disk_has_fs(const char *disk) {
    char dev[PERSIST_NAME + 8];
    snprintf(dev, sizeof dev, "/dev/%s", disk);
    char out[256];
    run_capture(out, sizeof out,
                "if command -v blkid >/dev/null 2>&1; then blkid %s; "
                "elif [ -x /sbin/blkid ]; then /sbin/blkid %s; "
                "elif [ -x /usr/sbin/blkid ]; then /usr/sbin/blkid %s; "
                "elif [ -x /bin/busybox ]; then /bin/busybox blkid %s; "
                "fi", dev, dev, dev, dev);
    return strstr(out, "TYPE=") != NULL || strstr(out, "UUID=") != NULL;
}

/* A COPPER label means a disk is already persistence, with nothing to lose. Kept
   separate from disk_has_fs() because its answer no longer decides the branch. */
static int disk_is_copper(const char *disk) {
    char dev[PERSIST_NAME + 8];
    snprintf(dev, sizeof dev, "/dev/%s", disk);
    char out[256];
    run_capture(out, sizeof out,
                "if command -v blkid >/dev/null 2>&1; then blkid %s; "
                "elif [ -x /sbin/blkid ]; then /sbin/blkid %s; "
                "elif [ -x /usr/sbin/blkid ]; then /usr/sbin/blkid %s; "
                "elif [ -x /bin/busybox ]; then /bin/busybox blkid %s; "
                "fi", dev, dev, dev, dev);
    return strstr(out, "LABEL=\"COPPER\"") != NULL;
}

static int list_spare_disks(char disks[][PERSIST_NAME]) {
    DIR *d = opendir("/sys/block");
    if (!d) return 0;
    struct dirent *de;
    int n = 0;
    while ((de = readdir(d)) != NULL && n < PERSIST_MAX_DISKS) {
        if (de->d_name[0] == '.') continue;
        if (!is_disk_name(de->d_name)) continue;
        if (is_boot_medium(de->d_name)) continue;
        if (is_upper_disk(de->d_name)) continue;
        if (disk_in_use(de->d_name)) continue;
        snprintf(disks[n], PERSIST_NAME, "%.*s", PERSIST_NAME - 1, de->d_name);
        n++;
    }
    closedir(d);
    return n;
}

static unsigned long long disk_bytes(const char *disk) {
    char path[128];
    snprintf(path, sizeof path, "/sys/block/%s/size", disk);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long long sectors = 0;
    if (fscanf(f, "%llu", &sectors) != 1) sectors = 0;
    fclose(f);
    return sectors * 512;
}

static void disk_size_str(const char *disk, char *out, size_t cap) {
    unsigned long long b = disk_bytes(disk);
    if (b == 0) { out[0] = '\0'; return; }
    if (b >= 1000000000ULL)
        snprintf(out, cap, "%.1f GB", (double)b / 1000000000.0);
    else
        snprintf(out, cap, "%.0f MB", (double)b / 1000000.0);
}

static int wait_key(int secs) {
    struct pollfd p;
    p.fd = STDIN_FILENO;
    p.events = POLLIN;
    p.revents = 0;
    return poll(&p, 1, secs * 1000) > 0;
}

static int persist_seconds(void) {
    const char *s = getenv(PERSIST_SECONDS_ENV);
    if (!s || !*s) return 5;
    int n = atoi(s);
    if (n < 0) n = 0;
    if (n > 60) n = 60;
    return n;
}

static int format_persistence_disk(const char *dev) {
    printf("\nFormatting /dev/%s ...\n", dev);
    fflush(stdout);
/* Search for mkfs.ext4 instead of trusting PATH: it moves between /sbin and
   /usr/sbin. -F accepts a disk with no partitions. */
    char why[1024] = "";
    if (run_capture(why, sizeof why,
                    "if command -v mkfs.ext4 >/dev/null 2>&1; then "
                    "mkfs.ext4 -q -F -L COPPER /dev/%s; "
                    "elif [ -x /sbin/mkfs.ext4 ]; then "
                    "/sbin/mkfs.ext4 -q -F -L COPPER /dev/%s; "
                    "elif [ -x /usr/sbin/mkfs.ext4 ]; then "
                    "/usr/sbin/mkfs.ext4 -q -F -L COPPER /dev/%s; "
                    "else echo 'mkfs.ext4 is not in this image'; exit 127; fi",
                    dev, dev, dev) != 0) {
        printf("Could not format /dev/%s.\n", dev);
        if (why[0]) printf("  %s\n", why);
        printf("Persistence stays off; this session is unaffected.\n");
        return -1;
    }
    run_quiet("/bin/busybox sync");
    return 0;
}

/* Copy the wizard's answers to the new disk now: next boot mounts it as the
   writable layer and would otherwise ask everything again. Best effort only. */
static void carry_firstboot_answers(const char *dev) {
    const char *mnt = "/mnt/copper-persist";
    run_quiet("/bin/busybox mkdir -p %s", mnt);
    if (run_quiet("/bin/busybox mount -t ext4 /dev/%s %s", dev, mnt) != 0) {
        printf("(could not reopen /dev/%s to carry your answers across)\n", dev);
        return;
    }
    run_quiet("/bin/busybox mkdir -p %s/etc %s/home", mnt, mnt);
/* -a preserves modes so shadow stays private; missing files are skipped. */
    run_quiet("/bin/busybox cp -a /etc/passwd /etc/shadow /etc/group "
              "/etc/hostname /etc/hosts /etc/localtime /etc/timezone "
              "/etc/copper-firstboot.done /etc/copper-desktop "
              "/etc/copper.conf /etc/copper-init %s/etc/", mnt);
    run_quiet("/bin/busybox cp -a /home/. %s/home/", mnt);
    run_quiet("/bin/busybox sync");
    if (run_quiet("/bin/busybox umount %s", mnt) == 0)
        printf("Your answers are on it, so the next boot does not ask again.\n");
    else
        printf("(could not unmount /dev/%s cleanly; a reboot clears it up)\n", dev);
}

/* Reboot so the disk is live now, after the sync above. The override is for
   tests, which must never reboot their host. */
static void reboot_into_persistence(void) {
    if (getenv(PERSIST_NOREBOOT_ENV)) {
        printf("Reboot to turn persistence on — after that your files are kept.\n");
        return;
    }
    printf("Rebooting now — your files are kept from this point on.\n");
    fflush(stdout);
    run_quiet("/bin/busybox sync");
    reboot(RB_AUTOBOOT);
    /* Only reached if the kernel refused the request. */
    printf("Could not reboot automatically — reboot when you are ready.\n");
}

static int offer_persistence(void) {
    if (access(PERSIST_MARKER, R_OK) != 0) return 0;
    read_boot_marker();

    printf("\n");
    printf("Keeping your files\n");

/* An upper disk already means persistence: say so, instead of printing
   "nothing is saved" right after the reboot that enabled it. */
    if (boot_upper_disk[0]) {
        printf("  Already on: your files are kept on /dev/%s and are still here\n",
               boot_upper_disk);
        printf("  after a reboot. Nothing to set up.\n");
        return 1;
    }

    char disks[PERSIST_MAX_DISKS][PERSIST_NAME];
    int n = list_spare_disks(disks);

    if (n == 0) {
        printf("  Copper is running live, so nothing is saved when you reboot, and\n");
        printf("  no spare disk is attached that could change that. Add one (on\n");
        printf("  VMware: the VM's settings) and the next fresh boot will offer it.\n");
        return 1;
    }

/* One empty or already-COPPER disk is safe to take without a question; reusing
   it was the missing case that forced a needless ERASE on repeat VM boots.
   Two candidates or a disk with files still go to the explicit prompt. */
    if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {
        int already = disk_is_copper(disks[0]);
        char sz[32];
        disk_size_str(disks[0], sz, sizeof sz);

        if (already) {
            /* Nothing to format, and no countdown: the disk is already a
               persistence disk and there is no destructive act to escape. The
               session that was on it comes back on the next boot. */
            printf("  Already on: your files are kept on /dev/%s and are still\n",
                   disks[0]);
            printf("  here after a reboot. Nothing to set up.\n");
        } else {
            int secs = persist_seconds();
            printf("  Copper is running live, so nothing is saved when you reboot. One\n");
            printf("  empty disk is attached, so Copper formats it and keeps your files\n");
            printf("  on it from now on.\n");
            printf("\n");
            printf("      %-12s %s\n", disks[0], sz);
            printf("\n");
            printf("  Formatting /dev/%s in %d seconds — press Enter to skip.\n",
                   disks[0], secs);
            fflush(stdout);
            if (wait_key(secs)) {
                char skip[8];
                read_line(skip, sizeof skip);
                printf("\nSkipped — this session stays in RAM.\n");
                return 1;
            }
            printf("\n");
            if (format_persistence_disk(disks[0]) != 0) return 1;
            printf("\nDone. /dev/%s is labeled COPPER.\n", disks[0]);
        }

        carry_firstboot_answers(disks[0]);
        reboot_into_persistence();
        return 1;
    }

    /* More than one candidate, or one that already has files on it: list them
       and make the disk be named and the erasure confirmed. */
    printf("  Copper is running live, so nothing is saved when you reboot. Pick a\n");
    printf("  disk below and it is wiped, formatted and then keeps your files from\n");
    printf("  the next boot on. Press Enter alone to leave everything as it is.\n");
    printf("\n");
    for (int i = 0; i < n; i++) {
        char sz[32];
        disk_size_str(disks[i], sz, sizeof sz);
        printf("      %-12s %s\n", disks[i], sz);
    }
    printf("\n");
    printf("Disk to keep files on [none]: ");
    fflush(stdout);

    char pick[64];
    if (!read_line(pick, sizeof pick) || !pick[0]) {
        printf("Nothing selected — this session stays in RAM.\n");
        return 1;
    }
    const char *dev = pick;
    if (strncmp(dev, "/dev/", 5) == 0) dev += 5;

    int idx = -1;
    for (int i = 0; i < n; i++)
        if (strcmp(disks[i], dev) == 0) { idx = i; break; }
    if (idx < 0) {
        printf("\"%s\" is not one of the disks above — nothing was touched.\n", pick);
        return 1;
    }

    printf("\n  WARNING: /dev/%s will be erased completely.\n", dev);
    printf("  Type ERASE (capital letters) to go ahead: ");
    fflush(stdout);
    char confirm[64];
    if (!read_line(confirm, sizeof confirm) || strcmp(confirm, "ERASE") != 0) {
        printf("Not confirmed — /dev/%s was left alone.\n", dev);
        return 1;
    }

    if (format_persistence_disk(dev) != 0) return 1;
    printf("\nDone. /dev/%s is labeled COPPER.\n", dev);
    carry_firstboot_answers(dev);
    reboot_into_persistence();
    return 1;
}

int main(void) {
    char name[FIELD_CAP];
    char user[FIELD_CAP];
    char host[FIELD_CAP];
    char tz[FIELD_CAP];
    char rootpw[FIELD_CAP];
    char userpw[FIELD_CAP];

/* Unbuffered stdout: /dev/console is fully buffered, so a prompt with no
   newline stays invisible until something else flushes it. */
    setvbuf(stdout, NULL, _IONBF, 0);

    ui_init();
    banner();

    for (int i = 0; i < F_COUNT; i++) collect(i);

/* EOF means no account at all, never one built from empty buffers. */
    if (stdin_eof) {
        printf("\nNo answers were entered, so no account was set up.\n");
        return 1;
    }

    snprintf(name, sizeof name, "%s",
             fields[F_NAME].value[0] ? fields[F_NAME].value : "friend");
    snprintf(user, sizeof user, "%s", fields[F_USER].value);
    snprintf(host, sizeof host, "%s",
             fields[F_HOST].value[0] ? fields[F_HOST].value : "copper");
    snprintf(tz, sizeof tz, "%s",
             fields[F_TZ].value[0] ? fields[F_TZ].value : "UTC");
    snprintf(rootpw, sizeof rootpw, "%s", fields[F_ROOTPW].value);
    snprintf(userpw, sizeof userpw, "%s", fields[F_USERPW].value);

/* Defaults for the unasked four are constants; every consumer still gets a value. */
    const char *shell_word = "bash";
    const char *shell_path = "/usr/bin/bash";
    const char *audio_word = "pulseaudio";
    const char *init_word = "busybox";

    if (!ui_fancy) printf("\nSetting things up...\n");


    draw_progress(0);

    run("echo %s > /etc/hostname", host);
    run("echo '127.0.0.1 localhost %s' > /etc/hosts", host);
    run("echo '::1 localhost ip6-localhost ip6-loopback' >> /etc/hosts");
    run("/bin/busybox hostname %s", host);
    draw_progress(1);

/* addgroup first: without -G the group must already exist. Use the long
   --disabled-password (short -D is ambiguous on this busybox) and -s bash;
   on failure write the account files directly rather than abort the boot. */
    run_quiet("/bin/busybox addgroup %s", user);

    char why[1024] = "";
    if (run_capture(why, sizeof why,
                    "/bin/busybox adduser --disabled-password -G %s "
                    "-h /home/%s -s %s %s",
                    user, user, shell_path, user) != 0) {
        printf("(adduser failed, writing the account files directly)\n");
        if (why[0]) printf("  busybox said: %s\n", why);
        if (create_user_direct(user, shell_path) != 0) {
            printf("Couldn't create user %s.\n", user);
            return 1;
        }
    }
    run_quiet("/bin/busybox cp -a /etc/skel/.bashrc /home/%s/.bashrc", user);
    run_quiet("/bin/busybox chown %s:%s /home/%s/.bashrc", user, user, user);
    run_quiet("/bin/busybox cp -a /etc/skel/.zshrc /home/%s/.zshrc", user);
    run_quiet("/bin/busybox chown %s:%s /home/%s/.zshrc", user, user, user);
/* adduser's home inherited the setgid bit on the reviewed image. 0755 is the
   documented mode and matches the direct-account fallback above. */
    run_quiet("/bin/busybox chmod 0755 /home/%s", user);

/* _seatd lets the session user reach root-run seatd; an absent group is a no-op. */
    const char *supp[] = {"wheel", "users", "audio", "video", "dialout", "cdrom",
                          "_seatd", NULL};
    for (const char **g = supp; *g; g++) {
/* Missing supplementary groups are harmless; quiet output avoids "bad record" noise. */
        run_quiet("/bin/busybox addgroup %s %s", user, *g);
    }
    draw_progress(2);
/* Set both passwords here, after the account, not interleaved with progress. */
    set_password("root", rootpw);
    set_password(user, userpw);

    {
        char zfile[FIELD_CAP + 64];
        snprintf(zfile, sizeof zfile, "/usr/share/zoneinfo/%s", tz);
        if (access(zfile, R_OK) == 0) {
            run("ln -sf /usr/share/zoneinfo/%s /etc/localtime", tz);
            run("echo %s > /etc/timezone", tz);
        } else {
            printf("(timezone %s not found, staying on UTC)\n", tz);
        }
    }
    draw_progress(4);

/* Marker line 1 is the LOGIN NAME: copper-init chdir()s to /home/<line 1>.
   Line 2 is the display name for greetings. */
    {
        FILE *m = fopen("/etc/copper-firstboot.done", "w");
        if (m) {
            fprintf(m, "%s\n%s\n", user, name);
            fclose(m);
        }
    }

/* Default desktop is xfce, the one in the base image; copper-init uses it
   for its hint. The launchers do not read this file. */
    {
        FILE *d = fopen("/etc/copper-desktop", "w");
        if (d) {
            fprintf(d, "xfce\n");
            fclose(d);
        }
    }

/* Settings are defaults an advanced user may edit later. /etc/copper-init
   only affects the NEXT boot; this boot's init came from GRUB or persistence. */
    {
        FILE *c = fopen("/etc/copper.conf", "w");
        if (c) {
            fprintf(c, "# Copper Linux settings (written by the first-boot wizard).\n");
            fprintf(c, "# shell=bash|zsh, audio=pulseaudio|pipewire.\n");
            fprintf(c, "# The init is /etc/copper-init; the GRUB menu can override it.\n");
            fprintf(c, "shell=%s\n", shell_word);
            fprintf(c, "audio=%s\n", audio_word);
            fclose(c);
        }
    }
    {
        FILE *i = fopen("/etc/copper-init", "w");
        if (i) {
            fprintf(i, "%s\n", init_word);
            fclose(i);
        }
    }

/* Offer persistence only after the done-marker, so an interrupt still leaves
   a finished account. Hold the screen only when a page was actually shown. */
    if (offer_persistence() && ui_fancy) {
        printf("\nPress Enter to continue. ");
        fflush(stdout);
        char hold[8];
        read_line(hold, sizeof hold);
    }

    screen_done(name);
    return 0;
}
