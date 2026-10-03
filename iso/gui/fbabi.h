/*
 * fbabi.h — the Linux framebuffer and evdev ABI, as copper-gui needs it.
 *
 * Why these structs are declared here instead of included from <linux/fb.h>:
 * musl-gcc, which is the compiler the Copper ISO is built with, does not put
 * /usr/include on its search path at all. Its include list is
 * /usr/include/x86_64-linux-musl plus gcc's own directory, so <linux/fb.h>
 * cannot be reached — even on a machine where the header is sitting right
 * there in /usr/include/linux/fb.h. Adding -I/usr/include to work around it
 * would put glibc's headers back on the include path of a musl compile, which
 * trades one build problem for a subtler one.
 *
 * So copper-gui carries its own copy of the handful of definitions it uses.
 * That is a frozen, stable ABI — these structs have not changed in years — and
 * it removes a dependency on whatever kernel headers happen to be installed on
 * the machine doing the build. The ISO is meant to be reproducible; a build
 * that depends on the host's kernel headers is not.
 *
 * Field names, order and types are copied verbatim from the 6.12.10 uapi
 * headers. Getting the order wrong would not fail to compile; it would hand the
 * kernel a struct laid out differently from the one it writes into, and the
 * numbers that came back would be quietly meaningless. The sizes below were
 * measured rather than assumed:
 *
 *     sizeof(struct fb_fix_screeninfo) = 80
 *     sizeof(struct fb_var_screeninfo) = 160
 *     sizeof(struct fb_bitfield)       = 12
 *     sizeof(struct input_event)       = 24   (x86_64)
 *
 * ioctl numbers are computed with the same _IOC encoding the kernel uses, not
 * written as literals, so they are right by construction rather than by luck.
 * Measured results, for checking against this file by hand:
 *
 *     FBIOGET_VSCREENINFO = 0x4600    FBIOGET_FSCREENINFO = 0x4602
 *     EVIOCGVERSION       = 0x80044501
 *
 * Do not include this alongside <linux/fb.h> or <linux/input.h>; the type names
 * would collide.
 */
#ifndef COPPER_GUI_FBABI_H
#define COPPER_GUI_FBABI_H

#include <stdint.h>

typedef uint32_t __u32;
typedef uint16_t __u16;

/* ---- ioctl encoding ------------------------------------------------------ *
 * musl's <sys/ioctl.h> already provides _IOC/_IOR/_IOW, and it is included
 * before this header, so these are only supplied when the C library has not
 * done it. Redefining them unconditionally is an error, not a warning, and
 * musl -Werror would rightly refuse the build.
 *
 * musl's definition is the standard asm-generic one and gives EVIOCGVERSION =
 * _IOR('E', 0x01, int) = 0x80044501, which matches what the kernel expects.
 */
#ifndef _IOC
#define _IOC_NRBITS     8
#define _IOC_TYPEBITS   8
#define _IOC_SIZEBITS   14
#define _IOC_DIRBITS    2
#define _IOC_NRSHIFT    0
#define _IOC_TYPESHIFT  (_IOC_NRSHIFT + _IOC_NRBITS)
#define _IOC_SIZESHIFT  (_IOC_TYPESHIFT + _IOC_TYPEBITS)
#define _IOC_DIRSHIFT   (_IOC_SIZESHIFT + _IOC_SIZEBITS)

#define _IOC_NONE   0U
#define _IOC_WRITE  1U
#define _IOC_READ   2U

#define _IOC(dir, type, nr, size)                                        \
    (((dir) << _IOC_DIRSHIFT)  | ((type) << _IOC_TYPESHIFT) |            \
     ((nr)  << _IOC_NRSHIFT)   | ((size) << _IOC_SIZESHIFT))
#endif

#ifndef _IOR
#define _IOR(type, nr, size)  _IOC(_IOC_READ,  (type), (nr), sizeof(size))
#endif
#ifndef _IOW
#define _IOW(type, nr, size)  _IOC(_IOC_WRITE, (type), (nr), sizeof(size))
#endif

/* ---- framebuffer --------------------------------------------------------- */

#define FBIOGET_VSCREENINFO  0x4600
#define FBIOPUT_VSCREENINFO  0x4601
#define FBIOGET_FSCREENINFO  0x4602

/* Only the types this kernel's uapi actually declares. Several older ones
 * (FB_TYPE_PACKED_BITS, FB_TYPE_DIRECT, FB_VISUAL_TRUECOLOR_GRAB,
 * FB_VISUAL_INDEXED, FB_VISUAL_NONE, FB_ACTIVATE_NOVL, fix.msr_right) were
 * removed upstream, and naming them here would be naming things that no longer
 * exist. */
#define FB_TYPE_PACKED_PIXELS       0
#define FB_TYPE_PLANES              1
#define FB_TYPE_INTERLEAVED_PLANES  2
#define FB_TYPE_TEXT                3
#define FB_TYPE_VGA_PLANES          4
#define FB_TYPE_FOURCC              5

#define FB_VISUAL_MONO01            0
#define FB_VISUAL_MONO10            1
#define FB_VISUAL_TRUECOLOR         2
#define FB_VISUAL_PSEUDOCOLOR       3
#define FB_VISUAL_DIRECTCOLOR       4
#define FB_VISUAL_STATIC_PSEUDOCOLOR 5
#define FB_VISUAL_FOURCC            6

/* Note FB_ACTIVATE_NOW is 0, not 1. Writing "FB_ACTIVATE_NOW | something" is
 * therefore a no-op for that flag, and the only thing doing any work is the
 * other operand. FB_ACTIVATE_FORCE exists for exactly the case where the mode
 * being requested is the one already current: without it a driver is entitled
 * to treat the request as a no-op and leave the scanout alone. */
#define FB_ACTIVATE_NOW       0
#define FB_ACTIVATE_NXTOPEN   1
#define FB_ACTIVATE_TEST      2
#define FB_ACTIVATE_MASK      15
#define FB_ACTIVATE_VBL       16
#define FB_ACTIVATE_ALL       64
#define FB_ACTIVATE_FORCE     128
#define FB_ACTIVATE_INV_MODE  256
#define FB_ACTIVATE_KD_TEXT   512

struct fb_bitfield {
    __u32 offset;      /* beginning of bitfield                          */
    __u32 length;      /* length of bitfield                             */
    __u32 msb_right;   /* != 0: most significant bit is to the right      */
};

struct fb_fix_screeninfo {
    char     id[16];           /* identification string, e.g. "TT Builtin" */
    unsigned long smem_start;  /* start of framebuffer memory (physical)   */
    __u32    smem_len;         /* length of framebuffer memory              */
    __u32    type;             /* FB_TYPE_*                                 */
    __u32    type_aux;         /* interleave for interleaved planes         */
    __u32    visual;           /* FB_VISUAL_*                               */
    __u16    xpanstep;         /* zero if no hardware panning               */
    __u16    ypanstep;
    __u16    ywrapstep;        /* zero if no hardware ywrap                 */
    __u32    line_length;      /* length of a line in bytes                 */
    unsigned long mmio_start;  /* start of memory mapped I/O (physical)     */
    __u32    mmio_len;
    __u32    accel;
    __u16    capabilities;     /* FB_CAP_*                                  */
    __u16    reserved[2];
};

struct fb_var_screeninfo {
    __u32 xres;            /* visible resolution                             */
    __u32 yres;
    __u32 xres_virtual;    /* virtual resolution                             */
    __u32 yres_virtual;
    __u32 xoffset;         /* offset from virtual to visible resolution       */
    __u32 yoffset;

    __u32 bits_per_pixel;
    __u32 grayscale;       /* 0 = colour, 1 = greyscale, >1 = FOURCC         */
    struct fb_bitfield red;
    struct fb_bitfield green;
    struct fb_bitfield blue;
    struct fb_bitfield transp;

    __u32 nonstd;          /* != 0: non-standard pixel format                */

    __u32 activate;        /* FB_ACTIVATE_*                                 */

    __u32 height;          /* height of picture in mm                        */
    __u32 width;           /* width of picture in mm                         */
    __u32 accel_flags;     /* (OBSOLETE) see fb_info.flags                   */

    /* Timing: all values in pixclocks except pixclock itself. */
    __u32 pixclock;
    __u32 left_margin;
    __u32 right_margin;
    __u32 upper_margin;
    __u32 lower_margin;
    __u32 hsync_len;
    __u32 vsync_len;
    __u32 sync;            /* FB_SYNC_*                                      */
    __u32 vmode;           /* FB_VMODE_*                                     */
    __u32 rotate;          /* angle we rotate counter-clockwise              */
    __u32 colorspace;      /* colorspace for FOURCC-based modes              */
    __u32 reserved[4];
};

/* ---- evdev --------------------------------------------------------------- */

#define EVIOCGVERSION   _IOR('E', 0x01, int)

#define EV_SYN          0x00
#define EV_KEY          0x01
#define EV_REL          0x02
#define EV_ABS          0x03

#define SYN_REPORT      0

#define REL_X           0x00
#define REL_Y           0x01
#define REL_WHEEL       0x08

#define KEY_ESC         1
#define KEY_ENTER       28

#define BTN_LEFT        0x110
#define BTN_RIGHT       0x111

/* On x86_64 the kernel writes two unsigned longs rather than a struct timeval;
 * the sizes agree, but the field types do not, and reading them into the wrong
 * ones would reinterpret the microseconds field as part of the event code. */
struct input_event {
    unsigned long  __sec;
    unsigned long  __usec;
    __u16          type;
    __u16          code;
    int32_t        value;
};

#endif /* COPPER_GUI_FBABI_H */