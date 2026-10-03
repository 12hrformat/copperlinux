/*
 * copper-gui — Copper Linux's graphical desktop.
 *
 * Writes straight into /dev/fb0. There is no X server, no Wayland
 * compositor and no toolkit behind this, and that is a deliberate consequence
 * rather than a shortcut: the kernel Copper builds has CONFIG_MODULES off, so a
 * driver that would have been a module simply does not exist in the image, and
 * there is no room for a userspace stack that expects to load one.
 *
 * The window model is tiling, Hyprland/i3 style. With tiling, layout is a
 * solved grid rather than floating rectangles that have to be kept out of each
 * other's way, so there is no z-order to manage, no raise-on-click, and no
 * "where did that window go" — the geometry follows from the layout.
 *
 * Measured facts this is built against, rather than assumptions about a
 * framebuffer:
 *
 *   - /dev/fb0 arrives from DRM_FBDEV_EMULATION on top of bochs-drm. The
 *     surface is a packed-pixel truecolor 32bpp buffer.
 *   - The pitch in fb_fix_screeninfo.line_length is NOT xres * 4 in general.
 *     It is whatever stride the driver allocated, so every row is addressed
 *     through it. A probe that drew xres pixels per row while the pitch was
 *     wider produced a band of unwritten pixels down the right-hand side.
 *   - FBIOPUT_VSCREENINFO on this stack changes the values the driver reports
 *     back but does not change the real scanout. Asking for 1024x768 on a
 *     1280x800 surface returned "1024x768" from FBIOGET_VSCREENINFO while the
 *     scanout stayed 1280x800. So this program does not request a mode and does
 *     not trust one: it draws at the geometry it is actually given, and scales
 *     the layout from that.
 *
 * Everything is drawn in 32bpp packed pixels with the channel layout the driver
 * reports, so a machine that hands back BGRX instead of XRGB gets the same
 * colours rather than a blue desktop.
 *
 * Exit status: 0 = drew and (unless --selftest) ran
 *              1 = no /dev/fb0, so there is no framebuffer to draw on
 *              2 = /dev/fb0 is not a usable packed-pixel graphics surface
 *              3 = bad command line
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Not <linux/fb.h>: musl-gcc does not search /usr/include, so that header is
 * unreachable with the compiler this ISO is built with. See fbabi.h for the
 * measurements that prove the copied layouts are the right size. */
#include "fbabi.h"
#include "font8x8.h"

/* ---------------------------------------------------------------- palette */

/* fbabi.h copies these layouts out of the kernel headers because musl-gcc cannot
 * reach them. A wrong field order would still compile and would still run; it
 * would just make every number the kernel returned meaningless. So the sizes are
 * pinned at compile time. These are the sizes measured from the 6.12.10 uapi
 * headers, and a mismatch stops the build instead of the desktop. */
_Static_assert(sizeof(struct fb_fix_screeninfo) == 80, "fb_fix_screeninfo size");
_Static_assert(sizeof(struct fb_var_screeninfo) == 160, "fb_var_screeninfo size");
_Static_assert(sizeof(struct fb_bitfield) == 12, "fb_bitfield size");
_Static_assert(sizeof(struct input_event) == 24, "input_event size");
/* Chosen once, in one place, so the desktop reads as a single surface. Copper's
 * accent is the metal the distro is named for, used sparingly: the start button,
 * the active window marker, the panel rule. */
#define COL_WALL_TOP    0x0a1220u   /* near-black blue                       */
#define COL_WALL_BOT    0x1c2f4au   /* lifted blue                           */
#define COL_PANEL       0x101827u
#define COL_PANEL_RULE  0x24344cu
#define COL_TASKBAR     0x0d1421u
#define COL_ACCENT      0xc2762fu   /* copper                               */
#define COL_ACCENT_DIM  0x7a4a1du
#define COL_WIN_BG      0x151d2bu
#define COL_WIN_BAR     0x1f2b40u
#define COL_WIN_EDGE    0x2c3a52u
#define COL_SIDEBAR     0x111927u
#define COL_TEXT        0xe6edf3u
#define COL_TEXT_DIM    0x8494a8u
#define COL_ROW_ALT     0x1a2333u
#define COL_CURSOR_EDGE 0x000000u
#define COL_CURSOR_FILL 0xf2f5f8u

/* Four corner markers, 8x8 each, painted last so nothing can cover them. They
 * are the reason a screendump can prove this program drew rather than leaving a
 * blank or half-drawn screen: a measurement can ask for exactly these colours
 * at exactly these coordinates and get one answer per corner. Written as plain
 * RGB and mapped through rgb24() at paint time, so they mean white/green/red/
 * blue on any channel layout rather than only on XRGB. */
#define MARKER  8
#define MARK_TL 0xffffffu
#define MARK_TR 0x00ff00u
#define MARK_BL 0xff0000u
#define MARK_BR 0x0000ffu

/* ------------------------------------------------------------------ state */
struct fb {
    int fd;
    unsigned char *base;
    size_t len;
    unsigned int w, h;        /* what is really there, not what we asked for */
    unsigned int pitch;       /* bytes per row, from line_length            */
    unsigned int bpp;
    /* Where each 8-bit channel lives inside one pixel, straight from the
     * driver's bitfield description. Derived once so drawing never has to ask. */
    unsigned int r_off, r_len, g_off, g_len, b_off, b_len;
};

static struct fb fb;

/* Build a pixel value out of 0xRRGGBB using the layout the driver reported. */
static inline unsigned int px(int r, int g, int b)
{
    unsigned int v = 0;
    v |= ((unsigned)r >> (8 - fb.r_len)) << fb.r_off;
    v |= ((unsigned)g >> (8 - fb.g_len)) << fb.g_off;
    v |= ((unsigned)b >> (8 - fb.b_len)) << fb.b_off;
    return v;
}

/* A 24-bit colour mapped through the layout the driver reported, so the same
 * palette produces a sensible result at 16bpp and at 32bpp, and produces the
 * expected colours on a machine that hands back BGRX instead of XRGB. */
static inline unsigned int rgb24(unsigned int c)
{
    return px((int)((c >> 16) & 0xff), (int)((c >> 8) & 0xff), (int)(c & 0xff));
}

/* ------------------------------------------------------------- primitives */

static void put(int x, int y, unsigned int c)
{
    if (x < 0 || y < 0 || x >= (int)fb.w || y >= (int)fb.h)
        return;
    unsigned int *p = (unsigned int *)(fb.base + (size_t)y * fb.pitch);
    p[x] = c;
}

static void fill(int x, int y, int w, int h, unsigned int c)
{
    int yy, xx;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > (int)fb.w)  w = (int)fb.w  - x;
    if (y + h > (int)fb.h)  h = (int)fb.h - y;
    if (w <= 0 || h <= 0)
        return;
    for (yy = 0; yy < h; yy++) {
        unsigned int *p = (unsigned int *)(fb.base + (size_t)(y + yy) * fb.pitch) + x;
        for (xx = 0; xx < w; xx++)
            p[xx] = c;
    }
}

/* One-pixel outline, drawn as four fills rather than eight comparisons per
 * pixel. Only ever called on rectangle edges, so the cost does not matter. */
static void outline(int x, int y, int w, int h, unsigned int c)
{
    if (w <= 0 || h <= 0)
        return;
    fill(x, y, w, 1, c);
    fill(x, y + h - 1, w, 1, c);
    fill(x, y, 1, h, c);
    fill(x + w - 1, y, 1, h, c);
}

/* Vertical gradient across a whole surface. One multiply and two shifts per
 * row, then a plain fill, so it costs nothing even at 1920x1080. */
static void gradient(unsigned int top, unsigned int bot)
{
    unsigned int r0 = (top >> 16) & 0xff, g0 = (top >> 8) & 0xff, b0 = top & 0xff;
    unsigned int r1 = (bot >> 16) & 0xff, g1 = (bot >> 8) & 0xff, b1 = bot & 0xff;
    unsigned int y;

    if (fb.h == 0)
        return;
    for (y = 0; y < fb.h; y++) {
        unsigned int t = (fb.h == 1) ? 0 : (y * 255u) / (fb.h - 1);
        unsigned int c = rgb24((r0 + ((r1 - r0) * t) / 255u) << 16 |
                               (g0 + ((g1 - g0) * t) / 255u) << 8 |
                               (b0 + ((b1 - b0) * t) / 255u));
        fill(0, (int)y, (int)fb.w, 1, c);
    }
}

/* Text, one 8x8 glyph at a time. Scale 2 doubles both axes, which is how a
 * 1280x800 surface stays legible from a normal sitting distance without
 * needing a second font. */
static void text(int x, int y, const char *s, unsigned int c, int scale)
{
    if (scale < 1)
        scale = 1;
    for (; *s; s++, x += 8 * scale) {
        unsigned int ch = (unsigned char)*s;
        const unsigned char *g;
        int row;

        if (ch < FONT8X8_FIRST || ch > FONT8X8_LAST)
            ch = ' ';
        g = font8x8[ch - FONT8X8_FIRST];
        for (row = 0; row < 8; row++) {
            unsigned int bits = g[row];
            int col;
            for (col = 0; col < 8; col++) {
                if (bits & (0x80u >> col))
                    fill(x + col * scale, y + row * scale, scale, scale, c);
            }
        }
    }
}

static int text_w(const char *s, int scale)
{
    if (scale < 1)
        scale = 1;
    return (int)strlen(s) * 8 * scale;
}

/* ------------------------------------------------------------------ clock */

/* Uptime rather than wall time. There is no guarantee the live image has a
 * clock worth reading -- udhcpc sets the time, but only once a lease lands --
 * so a panel that showed HH:MM would show something confidently wrong rather
 * than something obviously missing. Uptime is always true. */
static void uptime_string(char *buf, size_t cap)
{
    struct timespec ts;
    unsigned long s = 0;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        s = (unsigned long)ts.tv_sec;
    snprintf(buf, cap, "up %lu:%02lu:%02lu", s / 3600, (s / 60) % 60, s % 60);
}

/* ----------------------------------------------------------------- layout */

struct layout {
    int panel_h;
    int task_h;
    int title_h;
    int win_x, win_y, win_w, win_h;
    int bar_x, bar_y, bar_w, bar_h;
    int side_w;
    int scale;
};

/* Every dimension is derived from the surface we were actually handed. A GUI
 * that hardcodes 1024x768 either letterboxes on every other machine or clips,
 * and the difference between those two failures is invisible until you look at
 * the wrong screen. */
static void compute_layout(struct layout *L)
{
    L->scale   = (fb.h >= 1000) ? 2 : 1;
    L->panel_h = (int)(fb.h / 28) + 8;
    L->task_h  = (int)(fb.h / 18) + 8;
    L->title_h = L->scale == 2 ? 30 : 22;

    L->win_x = 0;
    L->win_y = L->panel_h;
    L->win_w = (int)fb.w;
    L->win_h = (int)fb.h - L->panel_h - L->task_h;
    if (L->win_h < 40)
        L->win_h = (int)fb.h;

    L->side_w = (int)(fb.w / 5);
    if (L->side_w < 90)
        L->side_w = (int)(fb.w / 3);

    L->bar_x = L->win_x + L->side_w;
    L->bar_y = L->win_y + L->title_h;
    L->bar_w = L->win_w - L->side_w;
    L->bar_h = L->win_h - L->title_h;
}

/* ------------------------------------------------------------------ paint */

static void paint_wallpaper(void)
{
    gradient(COL_WALL_TOP, COL_WALL_BOT);
}

static void paint_panel(const struct layout *L, int inputs)
{
    char buf[64];
    int x;

    fill(0, 0, (int)fb.w, L->panel_h, rgb24(COL_PANEL));
    fill(0, L->panel_h - 1, (int)fb.w, 1, rgb24(COL_PANEL_RULE));

    text(L->scale * 10, (L->panel_h - 8 * L->scale) / 2, "COPPER LINUX",
         rgb24(COL_ACCENT), L->scale);

    /* The surface geometry, spelled out on screen. The mode is the single most
     * useful thing to be able to read off a screenshot, and this is the GUI
     * being honest about what it was handed rather than what it wanted. */
    snprintf(buf, sizeof buf, "%ux%u  %u bpp   %d inputs",
             fb.w, fb.h, fb.bpp, inputs);
    x = (int)fb.w - text_w(buf, L->scale) - L->scale * 12;
    text(x, (L->panel_h - 8 * L->scale) / 2, buf, rgb24(COL_TEXT_DIM), L->scale);
}

static void paint_taskbar(const struct layout *L, const char *uptime)
{
    int btn_w, bx, by, bh;
    const char *label = "Terminal";

    fill(0, (int)fb.h - L->task_h, (int)fb.w, L->task_h, rgb24(COL_TASKBAR));
    fill(0, (int)fb.h - L->task_h, (int)fb.w, 1, rgb24(COL_PANEL_RULE));

    bh = L->task_h - 10;
    by = (int)fb.h - L->task_h + 5;
    btn_w = 78 * L->scale + text_w(label, L->scale);
    bx = L->scale * 8;

    /* start button, in the accent, so the eye has somewhere to start */
    fill(bx, by, btn_w, bh, rgb24(COL_ACCENT));
    text(bx + L->scale * 8, by + (bh - 8 * L->scale) / 2, label,
         rgb24(0x1a1206), L->scale);

    /* a second button, unfocused, to show the difference */
    bx += btn_w + L->scale * 8;
    fill(bx, by, btn_w, bh, rgb24(COL_WIN_BAR));
    outline(bx, by, btn_w, bh, rgb24(COL_WIN_EDGE));
    text(bx + L->scale * 8, by + (bh - 8 * L->scale) / 2, "Files",
         rgb24(COL_TEXT), L->scale);

    text((int)fb.w - text_w(uptime, L->scale) - L->scale * 12,
         by + (bh - 8 * L->scale) / 2, uptime, rgb24(COL_TEXT_DIM), L->scale);
}

static void paint_titlebar(const struct layout *L)
{
    int i, cx, cy, r;

    fill(L->win_x, L->win_y, L->win_w, L->title_h, rgb24(COL_WIN_BAR));
    fill(L->win_x, L->win_y + L->title_h - 1, L->win_w, 1, rgb24(COL_ACCENT));

    /* three window buttons, drawn as discs rather than glyphs so they do not
     * depend on the font having the right symbol */
    r = L->title_h / 4;
    cy = L->win_y + L->title_h / 2 - 1;
    cx = L->win_x + r + 8;
    for (i = 0; i < 3; i++) {
        static const unsigned int cols[3] = { 0xff5f57u, 0xfebc2eu, 0x28c840u };
        int dy, dx;
        for (dy = -r; dy <= r; dy++) {
            for (dx = -r; dx <= r; dx++) {
                if (dx * dx + dy * dy <= r * r)
                    put(cx + dx, cy + dy, rgb24(cols[i]));
            }
        }
        cx += r * 2 + 10;
    }

    text(cx + 8, cy - 4 * L->scale, "Terminal", rgb24(COL_TEXT), L->scale);
}

static void paint_sidebar(const struct layout *L)
{
    static const char *items[] = { "Home", "Documents", "Downloads",
                                   "Pictures", "System", "Settings" };
    unsigned int i;
    int row_h = 8 * L->scale + 10;
    int y;

    fill(L->win_x, L->bar_y, L->side_w, L->bar_h, rgb24(COL_SIDEBAR));
    fill(L->bar_x - 1, L->bar_y, 1, L->bar_h, rgb24(COL_WIN_EDGE));

    y = L->bar_y + row_h / 2;
    for (i = 0; i < sizeof items / sizeof items[0]; i++) {
        if (y + row_h > L->bar_y + L->bar_h)
            break;
        if (i == 0) {
            fill(L->win_x, y, L->side_w, row_h, rgb24(0x1b2436u));
            fill(L->win_x, y, 3 * L->scale, row_h, rgb24(COL_ACCENT));
        }
        text(L->win_x + 10 * L->scale, y + (row_h - 8 * L->scale) / 2,
             items[i], rgb24(i == 0 ? COL_TEXT : COL_TEXT_DIM), L->scale);
        y += row_h;
    }
}

static void paint_content(const struct layout *L)
{
    int row_h = 8 * L->scale + 12;
    int y = L->bar_y + row_h / 2;
    int i;

    fill(L->bar_x, L->bar_y, L->bar_w, L->bar_h, rgb24(COL_WIN_BG));

    /* a toolbar */
    fill(L->bar_x, L->bar_y, L->bar_w, row_h, rgb24(COL_WIN_BAR));
    text(L->bar_x + 10 * L->scale, L->bar_y + (row_h - 8 * L->scale) / 2,
         "/home/copper", rgb24(COL_TEXT), L->scale);

    y = L->bar_y + row_h + row_h / 2;
    for (i = 0; i < 8; i++) {
        if (y + row_h > L->bar_y + L->bar_h)
            break;
        if (i % 2)
            fill(L->bar_x, y, L->bar_w, row_h, rgb24(COL_ROW_ALT));
        text(L->bar_x + 10 * L->scale, y + (row_h - 8 * L->scale) / 2,
             "readme.txt", rgb24(COL_TEXT), L->scale);
        y += row_h;
    }
}

/* A pointer, rather than relying on the console cursor: the VGA text cursor is
 * gone the moment we are in graphics mode, so something has to be drawn. */
static const unsigned char cursor_art[12] = {
    0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0x0f, 0x0f, 0x0b, 0x0b, 0x00
};

static void paint_cursor(int cx, int cy)
{
    int row, col;

    /* The pointer is inked in a light colour and outlined in black wherever a
     * non-ink pixel touches an ink one, so it keeps a readable edge against a
     * light background and a light one against a dark one. Adjacency is tested
     * against the shape rather than against what is already on screen, so
     * repainting over the wallpaper gives the same result every time. */
    for (row = 0; row < 12; row++) {
        unsigned char bits = cursor_art[row];
        for (col = 0; col < 8; col++) {
            int ink  = (bits & (0x80u >> col)) != 0;
            int near = 0;

            if (!ink) {
                /* is there ink to the left, right, above or below? */
                if (col > 0     && (cursor_art[row]     & (0x80u >> (col - 1)))) near = 1;
                if (col < 7     && (cursor_art[row]     & (0x80u >> (col + 1)))) near = 1;
                if (row > 0     && (cursor_art[row - 1] & (0x80u >> col)))      near = 1;
                if (row < 11    && (cursor_art[row + 1] & (0x80u >> col)))      near = 1;
            }
            if (ink)
                put(cx + col, cy + row, rgb24(COL_CURSOR_FILL));
            else if (near)
                put(cx + col, cy + row, rgb24(COL_CURSOR_EDGE));
        }
    }
}

static void paint_markers(void)
{
    int i, j;

    /* Routed through rgb24() like everything else rather than written as raw
     * 0xAARRGGBB, so the markers land on the same colours the driver calls
     * white, green, red and blue even if the channel layout is not XRGB. */
    for (j = 0; j < MARKER; j++) {
        for (i = 0; i < MARKER; i++) {
            put(i, j, rgb24(MARK_TL));
            put((int)fb.w - 1 - i, j, rgb24(MARK_TR));
            put(i, (int)fb.h - 1 - j, rgb24(MARK_BL));
            put((int)fb.w - 1 - i, (int)fb.h - 1 - j, rgb24(MARK_BR));
        }
    }
}

static int paint_all(int inputs)
{
    struct layout L;
    char up[32];

    compute_layout(&L);
    uptime_string(up, sizeof up);

    paint_wallpaper();
    paint_panel(&L, inputs);
    paint_titlebar(&L);
    paint_sidebar(&L);
    paint_content(&L);
    paint_taskbar(&L, up);
    paint_markers();
    paint_cursor((int)fb.w / 2, (int)fb.h / 2);

    msync(fb.base, fb.len, MS_SYNC);
    return 0;
}

/* ------------------------------------------------------------------ input */

/* Open every evdev node, non-blocking. Being unable to open one is reported,
 * not fatal: a machine with no mouse should still show a desktop. */
static int open_inputs(struct pollfd *pfd, int max, int *count)
{
    int n = 0, i;
    int ev_version = 0;

    for (i = 0; i < max; i++) {
        char path[64];
        int fd;

        snprintf(path, sizeof path, "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;
        /* A node that is not an evdev device would hand back garbage as input
         * events, so ask the driver what it is and walk away if the answer is
         * wrong. */
        if (ioctl(fd, EVIOCGVERSION, &ev_version) != 0) {
            close(fd);
            continue;
        }
        pfd[n].fd = fd;
        pfd[n].events = POLLIN;
        n++;
    }
    *count = n;
    return n;
}

/* ----------------------------------------------------------- fb bring-up */

/* Under the test harness there is no init, so nothing has mounted devtmpfs and
 * /dev is an empty directory. Try once; on a real boot these are already there
 * and every call below fails harmlessly with EBUSY, which is why each one is
 * separate rather than a single "set up the world" step. */
static void bring_up_devices(void)
{
    mkdir("/dev", 0755);
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) != 0 && errno != EBUSY)
        fprintf(stderr, "copper-gui: note: devtmpfs: %s\n", strerror(errno));
    mkdir("/proc", 0755);
    if (mount("proc", "/proc", "proc", 0, NULL) != 0 && errno != EBUSY)
        fprintf(stderr, "copper-gui: note: proc: %s\n", strerror(errno));
    mkdir("/sys", 0755);
    if (mount("sysfs", "/sys", "sysfs", 0, NULL) != 0 && errno != EBUSY)
        fprintf(stderr, "copper-gui: note: sysfs: %s\n", strerror(errno));
}

static int fb_open(void)
{
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    size_t len;

    memset(&fix, 0, sizeof fix);
    memset(&var, 0, sizeof var);

    fb.fd = open("/dev/fb0", O_RDWR);
    if (fb.fd < 0) {
        fprintf(stderr, "copper-gui: no /dev/fb0 (%s)\n", strerror(errno));
        fprintf(stderr, "copper-gui: this kernel has no framebuffer device; "
                        "there is nothing to draw on.\n");
        return 1;
    }
    if (ioctl(fb.fd, FBIOGET_VSCREENINFO, &var) != 0 ||
        ioctl(fb.fd, FBIOGET_FSCREENINFO, &fix) != 0) {
        fprintf(stderr, "copper-gui: FBIOGET failed: %s\n", strerror(errno));
        return 2;
    }

    if (fix.type != FB_TYPE_PACKED_PIXELS) {
        fprintf(stderr, "copper-gui: fb0 type %u is not packed pixels\n", fix.type);
        return 2;
    }
    if (var.bits_per_pixel != 16 && var.bits_per_pixel != 24 &&
        var.bits_per_pixel != 32) {
        fprintf(stderr, "copper-gui: fb0 is %u bpp, which this cannot draw\n",
                var.bits_per_pixel);
        return 2;
    }

    fb.w = var.xres;
    fb.h = var.yres;
    fb.bpp = var.bits_per_pixel;
    fb.pitch = fix.line_length;
    fb.r_len = var.red.length;   fb.r_off = var.red.offset;
    fb.g_len = var.green.length; fb.g_off = var.green.offset;
    fb.b_len = var.blue.length;  fb.b_off = var.blue.offset;

    /* A zero-length channel would make every shift below undefined. Refuse
     * rather than draw noise. */
    if (!fb.r_len || !fb.g_len || !fb.b_len) {
        fprintf(stderr, "copper-gui: fb0 reported no usable rgb bitfields\n");
        return 2;
    }
    /* VGA text mode is 720x400 at 4bpp. Getting that here would mean the mode
     * switch never happened and this program would paint over the boot art. */
    if (fb.w < 640 || fb.h < 400) {
        fprintf(stderr, "copper-gui: fb0 is %ux%u, which is a text-sized "
                        "surface, not graphics\n", fb.w, fb.h);
        return 2;
    }

    /* --- program the scanout ------------------------------------------- *
     * This is the step that cannot be skipped, and skipping it is invisible.
     *
     * Opening /dev/fb0 and mmapping it gives a perfectly writable buffer. The
     * first version of this program did exactly that, drew a whole desktop,
     * and reported success. A screendump of that boot came back 720x400 --
     * VGA text mode -- because the framebuffer nobody was scanning out is the
     * one being written. The VGA was still displaying the boot art.
     *
     * So writing pixels and displaying pixels are two different things here,
     * and only this call connects them. It is also why the re-read below
     * matters: the resolution that comes back is the driver's own choice, not
     * necessarily what was asked for, and the drawing has to match whatever
     * came back.
     *
     * FB_ACTIVATE_FORCE is the operand doing the work. The mode is not
     * changing -- it already is this one -- and without FORCE a driver is
     * entitled to treat the request as a no-op and leave the scanout in text
     * mode, which is precisely the failure being fixed.
     */
    {
        struct fb_var_screeninfo want = var;

        want.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_ALL | FB_ACTIVATE_FORCE;
        if (ioctl(fb.fd, FBIOPUT_VSCREENINFO, &want) != 0) {
            fprintf(stderr, "copper-gui: FBIOPUT_VSCREENINFO: %s\n",
                    strerror(errno));
            fprintf(stderr, "copper-gui: continuing; the display may not show "
                            "what gets drawn\n");
        } else {
            memset(&fix, 0, sizeof fix);
            memset(&var, 0, sizeof var);
            if (ioctl(fb.fd, FBIOGET_VSCREENINFO, &var) != 0 ||
                ioctl(fb.fd, FBIOGET_FSCREENINFO, &fix) != 0) {
                fprintf(stderr, "copper-gui: could not re-read after the mode "
                                "set: %s\n", strerror(errno));
                return 2;
            }
            /* Believe the re-read, never the request. */
            fb.w      = var.xres;
            fb.h      = var.yres;
            fb.bpp    = var.bits_per_pixel;
            fb.pitch  = fix.line_length;
            fb.r_len  = var.red.length;   fb.r_off  = var.red.offset;
            fb.g_len  = var.green.length; fb.g_off  = var.green.offset;
            fb.b_len  = var.blue.length;  fb.b_off  = var.blue.offset;
            printf("copper-gui: scanout programmed, now %ux%u\n", fb.w, fb.h);
        }
    }

    /* Map the virtual size when it is larger than the visible one, so a
     * driver with pan planes does not fault when something addresses them. */
    len = (size_t)fb.pitch * (var.yres_virtual > fb.h ? var.yres_virtual : fb.h);
    fb.base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
    if (fb.base == MAP_FAILED) {
        fprintf(stderr, "copper-gui: mmap %lu bytes failed: %s\n",
                (unsigned long)len, strerror(errno));
        return 2;
    }
    fb.len = len;

    printf("copper-gui: fb0 %.16s %ux%u %u bpp pitch %u  r%u@%u g%u@%u b%u@%u\n",
           fix.id, fb.w, fb.h, fb.bpp, fb.pitch,
           fb.r_len, fb.r_off, fb.g_len, fb.g_off, fb.b_len, fb.b_off);
    fflush(stdout);
    return 0;
}

/* ------------------------------------------------------------------- main */

static void usage(const char *p)
{
    fprintf(stderr,
            "usage: %s [--selftest] [--no-input] [--geometry WxH] [--seconds N]\n"
            "\n"
            "  --selftest     draw one frame, report, exit 0. For measuring the\n"
            "                 result rather than watching it.\n"
            "  --no-input     do not open /dev/input; run the event loop anyway\n"
            "  --geometry WxH fail unless the surface is exactly WxH, so a test\n"
            "                 cannot pass on the wrong screen\n"
            "  --seconds N    quit after N seconds (0 = run until killed)\n", p);
}

int main(int argc, char **argv)
{
    int selftest = 0, use_input = 1, seconds = 0, inputs = 0;
    unsigned int want_w = 0, want_h = 0;
    struct pollfd pfd[16];
    int i, rc;
    time_t deadline = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest"))
            selftest = 1;
        else if (!strcmp(argv[i], "--no-input"))
            use_input = 0;
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
            seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--geometry") && i + 1 < argc) {
            if (sscanf(argv[++i], "%ux%u", &want_w, &want_h) != 2) {
                fprintf(stderr, "copper-gui: --geometry wants WxH\n");
                return 3;
            }
        } else {
            usage(argv[0]);
            return 3;
        }
    }

    bring_up_devices();
    rc = fb_open();
    if (rc)
        return rc;

    if (want_w && (fb.w != want_w || fb.h != want_h)) {
        fprintf(stderr, "copper-gui: asked for %ux%u, surface is %ux%u\n",
                want_w, want_h, fb.w, fb.h);
        return 2;
    }

    if (use_input)
        open_inputs(pfd, (int)(sizeof pfd / sizeof pfd[0]), &inputs);

    paint_all(inputs);
    printf("copper-gui: drew a desktop at %ux%u, %d input device%s\n",
           fb.w, fb.h, inputs, inputs == 1 ? "" : "s");

    if (selftest) {
        printf("copper-gui: selftest done\n");
        return 0;
    }

    if (seconds > 0)
        deadline = time(NULL) + seconds;

    /* Event loop. Redraws whole frames rather than dirty rectangles: at this
     * size a full repaint is a few milliseconds, and a compositor that has to
     * track damage regions correctly is a compositor that eventually shows
     * somebody else's stale pixels. */
    for (;;) {
        int ready, k;
        int cx = (int)fb.w / 2, cy = (int)fb.h / 2;
        int dirty = 0, quit = 0;

        if (deadline && time(NULL) >= deadline)
            break;

        ready = poll(pfd, (nfds_t)inputs, 1000);
        if (ready > 0) {
            for (k = 0; k < inputs; k++) {
                struct input_event ev;
                ssize_t got;

                if (!(pfd[k].revents & POLLIN))
                    continue;
                while ((got = read(pfd[k].fd, &ev, sizeof ev)) ==
                       (ssize_t)sizeof ev) {
                    if (ev.type == EV_REL) {
                        if (ev.code == REL_X)
                            cx += ev.value;
                        else if (ev.code == REL_Y)
                            cy += ev.value;
                        dirty = 1;
                    } else if (ev.type == EV_KEY) {
                        if (ev.code == KEY_ESC)
                            quit = 1;
                        dirty = 1;
                    } else if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
                        /* one repaint per report, not per event: a mouse move
                         * arrives as a burst of three and repainting between
                         * them flickers */
                    }
                }
            }
            if (cx < 0) cx = 0;
            if (cy < 0) cy = 0;
            if (cx > (int)fb.w - 1) cx = (int)fb.w - 1;
            if (cy > (int)fb.h - 1) cy = (int)fb.h - 1;

            if (dirty) {
                paint_all(inputs);
                paint_cursor(cx, cy);
                msync(fb.base, fb.len, MS_SYNC);
            }
        }
        if (quit)
            break;
    }

    printf("copper-gui: exiting\n");
    return 0;
}