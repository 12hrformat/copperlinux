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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
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

/* Set once stdin runs out. Any prompt that loops on a rejected answer has to
   be able to break out on this, or it spins forever: fgets() keeps failing,
   the buffer stays empty, and an empty answer is not a valid username, so the
   do/while never ends. That is a hot loop on a machine nobody is watching. */
static int stdin_eof;

static int read_line(char *buf, size_t cap) {
    if (!fgets(buf, cap, stdin)) { stdin_eof = 1; return 0; }
    buf[strcspn(buf, "\r\n")] = '\0';
    return 1;
}

/* ------------------------------------------------------------------ */
/*  the terminal                                                       */
/* ------------------------------------------------------------------ */

static int term_cols = 80, term_rows = 25;

/* Ask the terminal how big it is, rather than assuming.

   The VGA console answers 80x25 no matter how large the emulator window is, so
   80x25 is the number that has to be designed against. But a serial console,
   a pty in a test harness, or someone running this over ssh can all be
   something else, and art sized for 80x25 on a 200-column terminal looks lost
   and broken in the other direction. */
static void term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
        term_cols = ws.ws_col;
        term_rows = ws.ws_row;
    }
}

/* The form is for a real terminal and nothing else. On a serial console it is
   worse than decoration: it clears the scrollback that somebody is reading to
   find out why the boot is stuck. So this is a gate, not a preference. */
static int ui_fancy;

static void ui_init(void) {
    term_size();
    ui_fancy = isatty(STDOUT_FILENO) && isatty(STDIN_FILENO) &&
               term_cols >= 46 && term_rows >= 14;
}

static void msleep(int ms) { usleep((useconds_t)ms * 1000); }

/* Wipe the screen and put the cursor at the top left.

   The DECSTBM reset (\033[r) before the erase is not decoration. A console
   sitting inside a scroll region counts scrolled lines against the region
   rather than the whole screen, so \033[H on its own can home to the top of
   the *region* rather than the top of the screen, and everything drawn
   afterwards lands low by however much has scrolled away.

   This was found by the boot art, which was 40 rows drawn onto a 25-row screen
   and so scrolled fifteen times, putting the form visibly out of place half way
   through the boot. The art is gone, but the form redraws itself as fields are
   answered, so a console that has scrolled is still reachable by this path, and
   the reset is one byte. Resetting the region first means the position of
   everything after this point is decided here and not by whatever the console
   happened to be doing. */
static void clr(void)      { fputs("\033[r\033[2J\033[H", stdout); }
static void at(int r, int c) { printf("\033[%d;%dH", r, c); }
/* ------------------------------------------------------------------ */
/*  the questions, as a table                                         */
/* ------------------------------------------------------------------ */
/* ------------------------------------------------------------------ */

enum { F_NAME, F_USER, F_HOST, F_ROOTPW, F_USERPW, F_TZ, F_COUNT };

/* Capacity of every answer buffer, on screen and off. Generous on purpose:
   the field editor caps what can be typed to what fits inside the box, so
   nothing this size can be filled in practice, and every buffer being the same
   size means no copy between them can ever truncate. */
#define FIELD_CAP 192

/* Defined further down, with the rest of the input checks. */
static int valid_user(const char *s);
static int valid_host(const char *s);
static int valid_tz(const char *s);

struct field {
    const char *label;
    /* Extra guidance, shown on the status line under the table.

       This used to be drawn *inside* the value cell, which put text where the
       answer goes. Keystrokes then overwrote only the front of it: type "Bo"
       over the hint "friend" and the screen showed "Boiend", with four
       characters of hint left sitting in the field. The only way past that was
       to backspace the debris by hand before typing anything, which is what a
       field you have to clear first always feels like. A value cell now starts
       genuinely empty and the help lives where help belongs. */
    const char *help;
    const char *ask;       /* the status line while this one is live */
    const char *reject;    /* why the last answer was not accepted */
    char value[FIELD_CAP];
    int  secret;
    int  has_value;
    /* Every field that ends up inside a system() command needs one of these.

     * This is not decoration. The hostname and the timezone are both pasted
     * into a shell command line -- `echo %s > /etc/hostname`,
     * `ln -sf /usr/share/zoneinfo/%s /etc/localtime` -- so an answer that has
     * not been through valid_host()/valid_tz() is arbitrary shell. The plain
     * prompt path always checked them; the table path checked only the
     * username, so the same typo was accepted on one terminal and refused on
     * another, and the table one could run what it was given. */
    int (*ok)(const char *);
};

static int ok_host(const char *s) { return !s[0] || valid_host(s); }
static int ok_tz(const char *s)   { return !s[0] || valid_tz(s); }
static int ok_pw(const char *s)   { return s[0] != '\0'; }

/* All members, always. A partial initialiser silently zeroes the rest, and
   there is no way to see at a glance that a missing `secret` is 0 rather than
   a mistake -- which for a password field is the difference between masked and
   printed in the clear. */
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

/* |   label(18)   value */
#define LABEL_COL 18

/* Spaces between the left-hand wall and the label. */
#define BOX_PAD 3

/* 1-based screen column where a field's value begins.

   Derived from the same numbers that format the row, because the one way this
   went wrong before was for the two to be computed separately and disagree:
   the box drew flush left while the cursor sat elsewhere, and every keystroke
   landed somewhere other than where the character had just been drawn. */
#define VALUE_COL (box_left + 1 + BOX_PAD + LABEL_COL + 2)

static int box_w(void) {
    int w = term_cols - 8;
    if (w > 66) w = 66;
    if (w < 40) w = 40;
    return w;
}

/* Where the box starts, in columns from the left edge. One owner, because
   both the drawing and the cursor placement need it. */
static int box_left;

static void box_begin(int w, int rows) {
    box_left = (term_cols - w) / 2;
    if (box_left < 0) box_left = 0;
    (void)rows;
}

/* Both of these place themselves by absolute screen coordinates.

   They used to indent with leading spaces and stack with newlines, which made
   every line's position depend on where the cursor happened to be -- and
   after a scrolling animation, that is not a place this code can reason about.
   Absolute rows cannot drift. */
static void box_line(const char *text, int w, int row) {
    int room = w - 2;
    int len = (int)strlen(text);
    /* Truncate, never wrap.

       The status line carries the prompt plus the help, and at 50 columns that
       is longer than the box. A wrapped line breaks the right-hand wall off
       and leaves a fragment on the row below, which at that point is a field
       row -- so the table loses a wall AND a value. A table with a clipped
       cell looks deliberate; a table with a missing wall looks broken. */
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

/* Draw the whole form and leave the cursor sitting in the active field's value
   cell, so the first character typed lands in the right place. */
static void render_form(int active, const char *status) {
    int w = box_w();
    int total = 4 + F_COUNT + 2;
    int top = (term_rows - total) / 2;
    if (top < 1) top = 1;   /* screen rows are 1-based; row 0 is not a row */

    clr();
    box_begin(w, total);

    /* Every line is placed at a row this code computed, counted from here.
       Nothing below depends on where the cursor happens to be. */
    int r = top;
    box_rule(w, r++);
    box_line("   Copper Linux  -  first boot setup", w, r++);
    box_rule(w, r++);

    /* Where the first field lands, taken from the same counter that drew the
       rows rather than counted out again by hand. An off-by-one here is
       invisible in the source and very visible on screen: the cursor sits one
       row below its own field, so what you type appears in the next
       question. */
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

    /* The prompt, plus whatever the live field needs to know -- including what
       pressing Enter on its own will do, which used to be shown inside the cell
       it would have to be typed over. */
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

/* ------------------------------------------------------------------ */
/*  typing into a field                                                */
/* ------------------------------------------------------------------ */

static struct termios saved_tio;
static int raw_on;

/* Non-canonical with no echo, so a keystroke arrives when it is pressed and is
   drawn by us rather than by the tty driver. ISIG is deliberately left on, so
   Ctrl-C still kills the wizard instead of being swallowed as a character. */
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

/* Erase n characters to the left of the cursor. */
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

/* /etc/passwd, /etc/group and /etc/shadow all ship WITHOUT a trailing newline.

   Appending to a file that does not end in one does not begin a new line, it
   concatenates onto the last record. So writing the new account produced

       nobody:x:65534:65534:nobody:/nonexistent:/bin/falsedemo:x:1000:...

   which is one unparseable line instead of two records: the last existing
   record ending in "false" and the brand new one starting with "demo",
   welded together. busybox then refused to read the file at all
   ("addgroup: /etc/passwd: bad record", once per supplementary group), and
   the account that had just been created was not readable by anything.

   The cost of fixing it is one byte per file. The alternative is an account
   that exists on disk and does not work, which is exactly what happened. */
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

/* Create the account by editing /etc/passwd, /etc/group and /etc/shadow
   directly.

   This exists because busybox adduser has now broken account creation on a
   booted system twice, in two different ways that only reproduce against this
   exact build's busybox (it calls PAM and groupadd, neither of which is in the
   image). /etc/passwd is a colon-separated file and we already know its exact
   format -- it is ours. Writing three lines is less clever than calling a
   helper, and it is a helper that has repeatedly not worked.

   Returns 0 on success. */
static int create_user_direct(const char *user) {
    /* Before anything is appended. See ensure_trailing_newline() above: an
       append to a file with no trailing newline silently corrupts the last
       record instead of adding a new one. */
    ensure_trailing_newline("/etc/passwd");
    ensure_trailing_newline("/etc/group");
    ensure_trailing_newline("/etc/shadow");

    /* Already there? Then this is a re-run and the account is fine. */
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

    /* Find an unused uid by scanning the passwd file for the numeric ids.

       A passwd record is name:passwd:uid:gid:gecos:home:shell, so the uid is
       the THIRD field. This used to read the second one:

           char *c1 = strchr(line, ':');
           int v = atoi(c1 + 1);          <-- the password field

       which is "x" on every normal account. atoi("x") is 0, the v > 0 test
       threw it away, and used[] came out all zeros. So the scan below had
       nothing to avoid and every account got 1000, colliding with whatever
       was already there.

       Two accounts sharing a uid is not cosmetic: the kernel compares home
       directory ownership numerically, so the first user owns the second
       user's files outright. Found by the account test, which seeded a
       passwd file containing uid 1000 and was handed 1000 anyway. */
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

    /* group: same name and id as the user, which is the convention adduser
       follows when no primary group is named. */
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
    fprintf(p, "%s:x:%d:%d:%s:%s:/usr/bin/copper-sh\n",
            user, uid, uid, gecos, home);
    fclose(p);

    /* shadow: locked, no password. set_password() fills it in moments later;
       starting locked means there is no window where the account has an empty
       password and is reachable from a console.

       Nine fields, in this order:
         name : passwd : lastchg : min : max : warn : inactive : expire : flag

       This used to write "%s:!::0:0:99999:7:::", which is TEN fields: the
       empty lastchg pushed everything right by one, so max landed on warn,
       99999 landed on inactive, and 7 landed on expire. On a live boot
       busybox chpasswd rewrites the line moments later and hides it, so it
       only shows up when chpasswd is missing -- and then the account is left
       holding a record no shadow parser will accept, which is the same class
       of fault as the trailing-newline weld this file already had to fix. */
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

    /* home directory, owned by the new user */
    if (mkdir(home, 0755) != 0 && errno != EEXIST) {
        printf("(note: couldn't create %s)\n", home);
    }
    chown(home, uid, uid);

    /* skel, so a new home is not an empty directory */
    const char *skel = "/etc/skel";
    if (access(skel, R_OK) == 0) {
        /* copy regular files out of skel; no subdirs are shipped there */
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

/* Ask for one password, twice, and insist the two match.

   getpass() reads from /dev/tty rather than stdin, so it needs the process to
   own a controlling terminal. The wizard is forked straight out of copper-init
   and inherits no session of its own, so getpass() usually cannot open /dev/tty
   and hands back NULL. That fallback used to print only its warning, never the
   question itself, which left the user staring at a bare "(no silent input
   available)" line with no idea what was being asked — and whatever they typed
   next went in blind. Print the prompt ourselves in that case. */
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

        if (confirm_prompt) {
            ask_password(confirm_prompt, again, sizeof again);
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

/* run a shell command with absolute busybox; input is pre-validated */
static int run(const char *fmt, ...) {
    char cmd[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    return system(cmd);
}

/* Run a command and throw away what it says.

   The wizard is not a build log. busybox prints a warning for things that are
   entirely normal here -- no /etc/adduser.conf, a group that already exists --
   and six lines of that landing in the middle of a password prompt is what
   made the first boot look like it was asking the same question over and
   over. It was not; it was printing warnings underneath it. */
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

/* Run a command but KEEP what it said, so that if it fails the reason can be
   shown instead of being swallowed. Silence on success, diagnostics on
   failure -- the opposite trade-off to run_quiet().

   `fmt` has to be the LAST named parameter: va_start's second argument must be
   the last named parameter of the variadic function, or the va_list is set up
   from the wrong place and every argument after it is garbage. */
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

/* ------------------------------------------------------------------ */
/*  asking                                                            */
/* ------------------------------------------------------------------ */

/* Type one field, showing what is typed as it goes.

   This is deliberately dumb: it draws the form, reads keys, echoes them at the
   cursor, and leaves validation to collect(). That split is why a rejected
   answer can re-ask with a reason on screen -- the old looped-on-an-invalid-
   username prompt gave no reason at all. */
static void type_into(int idx, const char *status, char *dest, size_t cap) {
    struct field *f = &fields[idx];

    /* Leave room so a long answer cannot run past the right-hand wall and wrap,
       which would tear the box in half. */
    int maxlen = box_w() - LABEL_COL - 8;
    if (maxlen > (int)cap - 1) maxlen = (int)cap - 1;
    if (maxlen < 1) maxlen = 1;

    render_form(idx, status);
    dest[0] = '\0';
    int n = 0;

    for (;;) {
        int c = getchar();
        if (c == EOF) { dest[n] = '\0'; return; }
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

/* Collect one field, in whichever mode this terminal turned out to support. */
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
                /* Confirm. The field is shown empty while this happens so the
                   stored value is never on screen in the clear. */
                char again[FIELD_CAP];
                fields[idx].has_value = 0;
                type_into(idx, "Type it once more to be sure",
                          again, sizeof again);
                if (again[0] && strcmp(again, f->value) == 0) break;
                f->value[0] = '\0';
                msleep(900);
                continue;
            }
            type_into(idx, status, f->value, sizeof f->value);
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

    /* Plain terminal: the original one-line prompts, which is also what the
       serial console and the test harness use. */
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
                /* Nobody left to answer. Use a name that is certain to be
                   valid rather than re-asking into a spin. */
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

/* ------------------------------------------------------------------ */
/*  applying, and the two end screens                                  */
/* ------------------------------------------------------------------ */

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

    /* Step off the box before returning.

       Nothing here ends in a newline any more -- the rows are placed by
       coordinate, not stacked by carriage return -- so the cursor is still
       sitting on the last rule when this returns. Anything printed next, such
       as the reason an account could not be created, then starts in the middle
       of the table and overwrites it: the box ends up with a run of text
       across its bottom wall and the diagnostic is unreadable as well.

       Park on the first free row below instead. */
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
        snprintf(l3, sizeof l3, "%*sType 'help' to see the builtins.",
                 BOX_PAD, "");
        box_line(l1, w, r++);
        box_line(l2, w, r++);
        box_line(l3, w, r++);
    }
    box_rule(w, r);
    msleep(2600);
    /* Hand the screen over clean: copper-sh prints its own banner next, and
       two banners stacked in 25 rows looks like a mistake. */
    clr();
}

int main(void) {
    /* Every one of these is FIELD_CAP, not a snug 64 or 128. The values have
       already been validated -- a username is capped at 32, a hostname at 63,
       a timezone at 100 -- but a compiler cannot see that through the struct,
       and a buffer smaller than its source is exactly the kind of thing that
       truncates silently at 3am. Same size as the field, so it cannot. */
    char name[FIELD_CAP];
    char user[FIELD_CAP];
    char host[FIELD_CAP];
    char tz[FIELD_CAP];
    char rootpw[FIELD_CAP];
    char userpw[FIELD_CAP];

    /* Unbuffered, once, so no prompt can ever be left sitting in a buffer
       waiting for a newline to push it out. /dev/console is a character
       device, not a terminal, so stdio picks full buffering and a prompt
       without a trailing newline stays invisible until something else
       happens to flush it -- which looked like the wizard hanging. */
    setvbuf(stdout, NULL, _IONBF, 0);

    ui_init();
    banner();

    /* Every question up front, in the table. They used to be interleaved with
       the work -- your own password was asked after the account had already
       been created -- which meant the questions were not in one place on
       screen and there was no single picture of what was still outstanding. */
    for (int i = 0; i < F_COUNT; i++) collect(i);

    /* If nobody answered, do not half-apply the form. Creating an account from
       whatever happened to be in the buffers -- an empty password above all --
       is worse than creating none and saying so. */
    if (stdin_eof) {
        printf("\nNo answers were entered, so no account was set up.\n");
        return 1;
    }

    /* Blank means "use the default", which the status line tells you before you
       type anything. A username is the one field with no default: an account
       called "" is not an account. */
    snprintf(name, sizeof name, "%s",
             fields[F_NAME].value[0] ? fields[F_NAME].value : "friend");
    snprintf(user, sizeof user, "%s", fields[F_USER].value);
    snprintf(host, sizeof host, "%s",
             fields[F_HOST].value[0] ? fields[F_HOST].value : "copper");
    snprintf(tz, sizeof tz, "%s",
             fields[F_TZ].value[0] ? fields[F_TZ].value : "UTC");
    snprintf(rootpw, sizeof rootpw, "%s", fields[F_ROOTPW].value);
    snprintf(userpw, sizeof userpw, "%s", fields[F_USERPW].value);

    if (!ui_fancy) printf("\nSetting things up...\n");

    /* --- apply ------------------------------------------------------- */

    draw_progress(0);

    /* hostname + hosts */
    run("echo %s > /etc/hostname", host);
    run("echo '127.0.0.1 localhost %s' > /etc/hosts", host);
    run("echo '::1 localhost ip6-localhost ip6-loopback' >> /etc/hosts");
    run("/bin/busybox hostname %s", host);
    draw_progress(1);

    /* The named user, with copper-sh as their login shell.

       Three things about this command, all of them found by running it against
       the busybox that actually ships in the ISO rather than by reading docs:

       -G <own group>   The group must already exist. Without it adduser fails
            with "adduser: unknown group <user>" and creates nothing. So the
            group goes in first, one line above. Omitting -G entirely does not
            help: busybox then tries to create a group of the same name itself
            and reports "adduser: group '<user>' in use".

       --disabled-password  Not -D. On this busybox -D is AMBIGUOUS between
            --debug, --disabled-login and --disabled-password, so the short
            form is rejected with "Option d is ambiguous" and adduser prints
            its usage and exits without creating the account. The long option
            is unambiguous and does what the wizard wants: the wizard sets both
            passwords itself with chpasswd a few lines further down.

       -s /usr/bin/copper-sh   The login shell. Nothing logs in yet -- init
            goes straight to a shell -- but it is what makes the account a
            Copper account rather than a generic one.

       If it still fails, fall through to writing /etc/passwd by hand rather
       than aborting the boot. A machine with a root account and no named user
       is a broken machine; one with slightly hand-written account files is
       merely unusual. */
    run_quiet("/bin/busybox addgroup %s", user);

    char why[1024] = "";
    if (run_capture(why, sizeof why,
                    "/bin/busybox adduser --disabled-password -G %s "
                    "-h /home/%s -s /usr/bin/copper-sh %s",
                    user, user, user) != 0) {
        printf("(adduser failed, writing the account files directly)\n");
        if (why[0]) printf("  busybox said: %s\n", why);
        if (create_user_direct(user) != 0) {
            printf("Couldn't create user %s.\n", user);
            return 1;
        }
    }
    const char *supp[] = {"wheel", "users", "audio", "video", "dialout", "cdrom", NULL};
    for (const char **g = supp; *g; g++) {
        /* A missing supplementary group is not worth aborting the boot for --
           the account itself already exists and works. And the output is
           suppressed: on a no-newline /etc/group every one of these printed a
           "bad record" complaint, which is what filled the screen with noise
           in the middle of the password question. */
        run_quiet("/bin/busybox addgroup %s %s", user, *g);
    }
    draw_progress(2);
    /* Both passwords come from the table now. Asking for the user's own
       password here, after the account already existed, meant the question
       arrived in the middle of the progress output instead of up front with
       everything else, and a person who pressed Ctrl-C at the wrong moment
       got an account with no password and no way back to the question. */
    set_password("root", rootpw);
    set_password(user, userpw);

    /* timezone */
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

    /* done marker

       Line 1 is the LOGIN NAME, not the display name, and that ordering is
       load-bearing: copper-init reads line 1 and does

           chdir("/home/<line 1>")

       to decide where the shell starts. While this file held the display name,
       a person who typed "Jane Doe" as their name and "jane" as their username
       was sent to /home/Jane Doe, which does not exist -- init printed "no
       home directory" and dropped them in / instead.

       Line 2 is the display name, for anything that wants to greet them. */
    {
        FILE *m = fopen("/etc/copper-firstboot.done", "w");
        if (m) {
            fprintf(m, "%s\n%s\n", user, name);
            fclose(m);
        }
    }

    screen_done(name);
    return 0;
}
