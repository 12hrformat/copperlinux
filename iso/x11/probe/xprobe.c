/*
 * xprobe -- connect to an X server and read its geometry, with no X client
 * library at all.
 *
 * Why not xdpyinfo: proving the server works means proving a client can do the
 * X11 handshake and read state back. xdpyinfo would do that, but it lives in
 * x11-utils, which is not in this image and is another build to trust. This
 * speaks the wire protocol directly, so the thing under test is the server and
 * nothing else: no Xlib, no libX11, no xcb. The only library it needs is libc.
 *
 * The handshake is the part that matters. A server that started and printed
 * "listening on /tmp/.X11-unix/X7" has told you almost nothing -- it opens that
 * socket before it has a driver. A completed ConnectionSetup reply carries the
 * protocol version, the vendor string, the resource-id base and mask, and the
 * screen list with its root window and dimensions. You cannot get that without
 * the server having a real output.
 *
 * Output is one line per fact, "name=value", so a test can grep for a value
 * rather than match prose.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* X11 core protocol, little-endian, from Xproto.h. Only the fields read here. */

#define X_TCP_PORT 6000

struct setup_request {
    uint8_t  byte_order;      /* 0x6c = 'l', little endian */
    uint8_t  pad0;
    uint16_t protocol_major;   /* 11 */
    uint16_t protocol_minor;   /* 0 */
    uint16_t auth_name_len;
    uint16_t auth_data_len;
    uint16_t pad1;
} __attribute__((packed));

struct setup_reply {
    uint8_t  success;          /* 1 = success, 0 = failed, 2 = authenticate */
    uint8_t  pad0;
    uint16_t protocol_major;
    uint16_t protocol_minor;
    uint16_t length;           /* in 4-byte units, of everything after this */
    /* ... on failure: reason_len then the reason string, padded. */
} __attribute__((packed));

struct setup_success_body {
    uint32_t release_number;
    uint32_t resource_id_base;
    uint32_t resource_id_mask;
    uint32_t motion_buffer_size;
    uint16_t vendor_len;
    uint16_t maximum_request_length;
    uint8_t  roots_len;
    uint8_t  pixmap_formats_len;
    uint8_t  image_byte_order;
    uint8_t  bitmap_format_bit_order;
    uint8_t  bitmap_format_scanline_unit;
    uint8_t  bitmap_format_scanline_pad;
    uint8_t  min_keycode;
    uint8_t  max_keycode;
    uint32_t pad0;
    /* vendor string, roots_len screens, pixmap_formats_len formats */
} __attribute__((packed));

/* GetGeometry, opcode 14. */
struct get_geometry_request {
    uint8_t  opcode;
    uint8_t  pad;
    uint16_t length;
    uint32_t drawable;
} __attribute__((packed));

struct get_geometry_reply {
    uint8_t  reply_type;     /* 1 = reply, 0 = error, in which case byte 1
                                holds the error code rather than a depth */
    uint8_t  depth;
    uint16_t sequence;
    uint32_t length;
    uint32_t root;
    int16_t  x, y;
    uint16_t width, height;
    uint16_t border_width;
    uint16_t pad1;
} __attribute__((packed));

static int write_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = write(fd, c, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        c += w;
        n -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *p, size_t n) {
    char *c = p;
    while (n) {
        ssize_t r = read(fd, c, n);
        if (r == 0)
            return -1;          /* closed: truncated reply */
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        c += r;
        n -= (size_t)r;
    }
    return 0;
}

static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Read and throw away. The setup reply carries the vendor string, the pixmap
   formats, and every screen; this probe only wants the first screen, and a
   server is free to announce more of that than fits in any fixed buffer. */
static int skip_bytes(int fd, uint32_t n) {
    unsigned char buf[512];
    while (n > 0) {
        size_t want = n < (uint32_t)sizeof buf ? (size_t)n : sizeof buf;
        if (read_all(fd, buf, want) < 0)
            return -1;
        n -= (uint32_t)want;
    }
    return 0;
}

static uint16_t rd16(const unsigned char *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

int main(int argc, char **argv) {
    const char *display_arg = NULL;
    const char *sockdir;
    int use_unix = 1;
    int display_num = -1;
    struct sockaddr_un sun;
    struct setup_request req;
    struct setup_reply rep;
    struct setup_success_body body;
    int fd;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tcp") == 0) {
            use_unix = 0;
        } else if (strncmp(argv[i], "--display=", 10) == 0) {
            display_arg = argv[i] + 10;
        } else if (argv[i][0] != '-') {
            display_arg = argv[i];
        } else {
            fprintf(stderr, "xprobe: unknown option %s\n", argv[i]);
            return 2;
        }
    }
    if (!display_arg)
        display_arg = getenv("DISPLAY");
    /* Where the socket lives. /tmp/.X11-unix is the convention and the default,
       but a server started with -nolisten and a private socket dir is a normal
       thing, and a test needs somewhere writable: under WSLg the standard
       directory is read-only. */
    sockdir = getenv("XPROBE_SOCKET_DIR");
    if (!sockdir || !*sockdir)
        sockdir = "/tmp/.X11-unix";
    if (!display_arg || !*display_arg) {
        fprintf(stderr, "xprobe: no DISPLAY, nothing to connect to\n");
        return 2;
    }

    /* DISPLAY is ":N", ":N.S", "host:N", or "unix:N". Only :N and unix:N are
       reachable without a network stack, which is all this has. */
    {
        const char *colon;
        char host[256];
        const char *rest;
        size_t hl;

        if (strncmp(display_arg, "unix:", 5) == 0) {
            colon = strchr(display_arg + 5, ':');
        } else {
            colon = strchr(display_arg, ':');
        }
        if (!colon) {
            fprintf(stderr, "xprobe: DISPLAY=%s has no display number\n",
                    display_arg);
            return 2;
        }
        hl = (size_t)(colon - display_arg);
        if (hl >= sizeof host)
            hl = sizeof host - 1;
        memcpy(host, display_arg, hl);
        host[hl] = 0;
        rest = colon + 1;

        if (host[0] && strcmp(host, "unix") != 0) {
            fprintf(stderr, "xprobe: DISPLAY=%s names a host, and this has no "
                            "network stack to reach it\n", display_arg);
            return 2;
        }
        display_num = (int)strtol(rest, NULL, 10);
        if (display_num < 0) {
            fprintf(stderr, "xprobe: DISPLAY=%s has no display number\n",
                    display_arg);
            return 2;
        }
        /* A screen suffix (.S) is legal and ignored here: the handshake
           reports every screen and picking between them is a client's job. */
        printf("display.number=%d\n", display_num);
        printf("display.transport=%s\n", use_unix ? "unix" : "tcp");
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "xprobe: socket: %s\n", strerror(errno));
        return 1;
    }
    memset(&sun, 0, sizeof sun);
    sun.sun_family = AF_UNIX;
    /* The abstract socket is /tmp/.X11-unix/XN; the filesystem path is what a
       server without abstract sockets uses. Try the filesystem path first,
       because that is the portable one, and fall back to abstract. */
    if ((size_t)snprintf(sun.sun_path, sizeof sun.sun_path, "%s/X%d",
                         sockdir, display_num) >= sizeof sun.sun_path) {
        fprintf(stderr, "xprobe: socket path for display %d does not fit in "
                        "sun_path\n", display_num);
        close(fd);
        return 2;
    }
    if (connect(fd, (struct sockaddr *)&sun, sizeof sun) < 0) {
        int saved = errno;
        memset(&sun, 0, sizeof sun);
        sun.sun_family = AF_UNIX;
        sun.sun_path[0] = 0;                 /* leading NUL: abstract */
        if ((size_t)snprintf(sun.sun_path + 1, sizeof sun.sun_path - 1,
                             "%s/X%d", sockdir, display_num) >=
            sizeof sun.sun_path - 1) {
            fprintf(stderr, "xprobe: socket path for display %d does not fit "
                            "in sun_path\n", display_num);
            close(fd);
            return 2;
        }
        if (connect(fd, (struct sockaddr *)&sun,
                    (socklen_t)(sizeof(sun.sun_family) + 1 +
                                strlen(sun.sun_path + 1))) < 0) {
            /* The filesystem path is tried first because that is the portable
               one. Report the abstract failure, which is the more informative of
               the two: "No such file" means no server ever got here, and
               "Connection refused" means one did and is now gone. */
            char path[sizeof sun.sun_path];

            snprintf(path, sizeof path, "%s/X%d", sockdir, display_num);
            fprintf(stderr, "xprobe: connect %s: %s\n", path, strerror(saved));
            fprintf(stderr, "xprobe: (abstract) %s: %s\n", sun.sun_path + 1,
                    strerror(errno));
            close(fd);
            return 1;
        }
    }
    printf("connected=yes\n");

    /* ---- the handshake -------------------------------------------------
       An empty authorisation record. A server started with -auth refuses
       this, and says so in the failure reply below rather than hanging,
       which is the behaviour being relied on. */
    memset(&req, 0, sizeof req);
    req.byte_order = 0x6c;
    req.protocol_major = 11;
    req.protocol_minor = 0;
    if (write_all(fd, &req, sizeof req) < 0) {
        fprintf(stderr, "xprobe: write setup: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    if (read_all(fd, &rep, sizeof rep) < 0) {
        fprintf(stderr, "xprobe: server closed during the handshake\n");
        close(fd);
        return 1;
    }
    printf("handshake.major=%u\n", rd16((unsigned char *)&rep.protocol_major));
    printf("handshake.minor=%u\n", rd16((unsigned char *)&rep.protocol_minor));

    if (rep.success != 1) {
        uint16_t extra16 = rd16((unsigned char *)&rep.length);
        uint32_t extra = (uint32_t)extra16 * 4u;
        unsigned char reason[256];
        uint32_t want;

        if (rep.success == 2) {
            printf("handshake.status=authenticate\n");
            fprintf(stderr, "xprobe: the server wants authorisation; start it "
                            "with -auth for a real client\n");
            close(fd);
            return 1;
        }
        printf("handshake.status=failed\n");
        want = extra < sizeof reason ? extra : (uint32_t)sizeof reason;
        if (want && read_all(fd, reason, want) == 0)
            fprintf(stderr, "xprobe: server refused the connection: %.*s\n",
                    (int)want, (const char *)reason);
        else
            fprintf(stderr, "xprobe: server refused the connection\n");
        close(fd);
        return 1;
    }
    printf("handshake.status=success\n");

    /* The rest of the reply: body, then vendor string, then screens. */
    if (read_all(fd, &body, sizeof body) < 0) {
        fprintf(stderr, "xprobe: truncated setup reply\n");
        close(fd);
        return 1;
    }
    {
        /* The setup reply is vendor string, then pixmap formats, then the
           screens. Reading all of it into a fixed buffer to find one record
           is what made this probe refuse healthy servers: XWayland announces
           more than fits. Instead the parts before the screen are consumed
           in order and the rest is drained, so only one SCREEN record is
           ever held. */
        unsigned char vendorbuf[512];
        unsigned char screenbuf[40];
        uint32_t extra = (uint32_t)rd16((unsigned char *)&rep.length) * 4u;
        uint32_t bodybytes = (uint32_t)sizeof body;
        uint32_t rest = extra > bodybytes ? extra - bodybytes : 0;
        uint16_t vendor_len = rd16((unsigned char *)&body.vendor_len);
        uint8_t roots_len = body.roots_len;
        uint32_t vendor_pad = ((uint32_t)vendor_len + 3u) & ~3u;
        uint32_t formats_bytes = (uint32_t)body.pixmap_formats_len * 8u;
        uint32_t want = vendor_pad + formats_bytes + (uint32_t)sizeof screenbuf;
        uint32_t left;
        const unsigned char *p;
        const char *vendor;
        uint32_t root;

        printf("resource_id_base=0x%x\n", rd32((unsigned char *)&body.resource_id_base));
        printf("resource_id_mask=0x%x\n", rd32((unsigned char *)&body.resource_id_mask));
        printf("max_request_length=%u\n",
               rd16((unsigned char *)&body.maximum_request_length));

        if (vendor_pad > sizeof vendorbuf || rest < want) {
            fprintf(stderr, "xprobe: setup reply is malformed (%u bytes "
                            "declared, %u needed for vendor, formats and one "
                            "screen)\n", rest, want);
            close(fd);
            return 1;
        }
        memset(vendorbuf, 0, sizeof vendorbuf);
        if (read_all(fd, vendorbuf, vendor_pad) < 0 ||
            skip_bytes(fd, formats_bytes) < 0 ||
            read_all(fd, screenbuf, sizeof screenbuf) < 0) {
            fprintf(stderr, "xprobe: truncated setup reply\n");
            close(fd);
            return 1;
        }
        /* Drain to the end of the reply, so the next read on this socket is
           the GetGeometry answer and not the tail of the handshake. */
        left = rest - want;
        if (left && skip_bytes(fd, left) < 0) {
            fprintf(stderr, "xprobe: truncated setup reply\n");
            close(fd);
            return 1;
        }

        vendor = (const char *)vendorbuf;
        printf("vendor=%.*s\n", (int)vendor_len, vendor);

        if (getenv("XPROBE_DUMP")) {
            uint32_t z;
            printf("dump.rest=%u\n", rest);
            printf("dump.vendor_pad=%u\n", vendor_pad);
            printf("dump.formats_bytes=%u\n", formats_bytes);
            printf("dump.drained=%u\n", left);
            printf("dump.screen=");
            for (z = 0; z < (uint32_t)sizeof screenbuf; z++)
                printf("%02x", screenbuf[z]);
            printf("\n");
        }

        /* SCREEN record, 40 bytes: root, default-colormap, white, black,
           input-masks, width, height, millimetres, map range, root-visual,
           backing-store, save-unders, root-depth, number-of-allowed-depths.
           Only the first screen is decoded; screen.count says how many there
           are, and choosing between them belongs to a client. */
        p = screenbuf;
        root = rd32(p + 0);
        printf("screen.count=%u\n", roots_len);
        {
            uint32_t white = rd32(p + 8);
            uint32_t black = rd32(p + 12);
            uint32_t cmap = rd32(p + 4);
            uint16_t w = rd16(p + 20);
            uint16_t h = rd16(p + 22);
            uint16_t mmw = rd16(p + 24);
            uint16_t mmh = rd16(p + 26);
            uint8_t root_depth = p[38];
            uint8_t depths_len = p[39];

            printf("screen[0].width=%u\n", w);
            printf("screen[0].height=%u\n", h);
            printf("screen[0].root=0x%x\n", root);
            printf("screen[0].root_depth=%u\n", root_depth);
            printf("screen[0].depths=%u\n", depths_len);
            printf("screen[0].white_pixel=0x%x\n", white);
            printf("screen[0].black_pixel=0x%x\n", black);
            printf("screen[0].colormap=0x%x\n", cmap);
            printf("screen[0].mm_width=%u\n", mmw);
            printf("screen[0].mm_height=%u\n", mmh);
        }

        /* ---- GetGeometry on the root, so this is a round trip and not
           just a parse of what the server already sent. If the server has a
           live output, this returns the same numbers; if it accepted the
           connection and then died, this is where that shows. ---- */
        if (roots_len >= 1) {
            struct get_geometry_request g;
            struct get_geometry_reply gr;

            memset(&g, 0, sizeof g);
            g.opcode = 14;
            /* The length counts the whole request in 4-byte units: 8 bytes
               here. Zero makes the server answer BadLength before it looks
               at the drawable. */
            g.length = 2;
            g.drawable = root;
            if (write_all(fd, &g, sizeof g) < 0 ||
                read_all(fd, &gr, sizeof gr) < 0) {
                fprintf(stderr, "xprobe: GetGeometry did not come back\n");
                close(fd);
                return 1;
            }
            /* Byte 0 is the packet kind: 1 is a reply, 0 is an error whose
               code is in byte 1. A sequence number is never zero, so testing
               that for an error accepted an error packet as a good read --
               which is how a BadDrawable on a bogus root came out as
               getgeometry.status=ok with width 0. */
            if (gr.reply_type != 1) {
                printf("getgeometry.status=error\n");
                printf("getgeometry.error=%u\n", gr.depth);
                fprintf(stderr, "xprobe: server sent error %u for GetGeometry\n",
                        gr.depth);
                close(fd);
                return 1;
            }
            printf("getgeometry.status=ok\n");
            printf("getgeometry.sequence=%u\n", rd16((unsigned char *)&gr.sequence));
            printf("getgeometry.width=%u\n", rd16((unsigned char *)&gr.width));
            printf("getgeometry.height=%u\n", rd16((unsigned char *)&gr.height));
            printf("getgeometry.depth=%u\n", gr.depth);
            printf("getgeometry.root=0x%x\n", rd32((unsigned char *)&gr.root));
        }

        }

    printf("probe=ok\n");
    close(fd);
    return 0;
}