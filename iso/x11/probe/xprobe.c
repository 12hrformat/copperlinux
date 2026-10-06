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
    uint8_t  depth;
    uint8_t  pad0;
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
        unsigned char tail[4096];
        uint32_t extra = (uint32_t)rd16((unsigned char *)&rep.length) * 4u;
        uint32_t bodybytes = (uint32_t)sizeof body;
        uint32_t rest = extra > bodybytes ? extra - bodybytes : 0;
        uint16_t vendor_len = rd16((unsigned char *)&body.vendor_len);
        uint8_t roots_len = body.roots_len;
        const unsigned char *p;
        const char *vendor;
        uint32_t i2;

        if (rest > sizeof tail) {
            fprintf(stderr, "xprobe: setup reply is %u bytes, too big for this "
                            "probe\n", rest);
            close(fd);
            return 1;
        }
        if (rest && read_all(fd, tail, rest) < 0) {
            fprintf(stderr, "xprobe: truncated setup reply\n");
            close(fd);
            return 1;
        }

        printf("resource_id_base=0x%x\n", rd32((unsigned char *)&body.resource_id_base));
        printf("resource_id_mask=0x%x\n", rd32((unsigned char *)&body.resource_id_mask));
        printf("max_request_length=%u\n",
               rd16((unsigned char *)&body.maximum_request_length));

        vendor = (const char *)tail;
        printf("vendor=%.*s\n", (int)vendor_len, vendor);

        /* First screen: root at the head of the SCREEN record, 40 bytes of
           fixed fields then the allowed-depths list. */
        p = tail + ((vendor_len + 3u) & ~3u);
        printf("screen.count=%u\n", roots_len);
        for (i2 = 0; i2 < roots_len && p + 40 <= tail + rest; i2++) {
            uint32_t root = rd32(p + 0);
            uint32_t white = rd32(p + 8);
            uint32_t black = rd32(p + 12);
            uint32_t cmap = rd32(p + 16);
            uint16_t w = rd16(p + 20);
            uint16_t h = rd16(p + 22);
            uint16_t mmw = rd16(p + 24);
            uint16_t mmh = rd16(p + 26);
            uint8_t depths_len = p[38];
            uint8_t root_depth = p[39];

            printf("screen[%u].width=%u\n", i2, w);
            printf("screen[%u].height=%u\n", i2, h);
            printf("screen[%u].root=0x%x\n", i2, root);
            printf("screen[%u].root_depth=%u\n", i2, root_depth);
            printf("screen[%u].depths=%u\n", i2, depths_len);
            printf("screen[%u].white_pixel=0x%x\n", i2, white);
            printf("screen[%u].black_pixel=0x%x\n", i2, black);
            printf("screen[%u].colormap=0x%x\n", i2, cmap);
            printf("screen[%u].mm_width=%u\n", i2, mmw);
            printf("screen[%u].mm_height=%u\n", i2, mmh);
            p += 40u + ((uint32_t)depths_len * 8u);
        }

        /* ---- GetGeometry on the root, so this is a round trip and not
           just a parse of what the server already sent. If the server has a
           live output, this returns the same numbers; if it accepted the
           connection and then died, this is where that shows. ---- */
        if (roots_len >= 1) {
            uint32_t root;
            struct get_geometry_request g;
            struct get_geometry_reply gr;

            p = tail + ((vendor_len + 3u) & ~3u);
            root = rd32(p + 0);

            memset(&g, 0, sizeof g);
            g.opcode = 14;
            g.length = 0;
            g.drawable = root;
            if (write_all(fd, &g, sizeof g) < 0 ||
                read_all(fd, &gr, sizeof gr) < 0) {
                fprintf(stderr, "xprobe: GetGeometry did not come back\n");
                close(fd);
                return 1;
            }
            if (gr.sequence == 0) {
                printf("getgeometry.status=error\n");
                fprintf(stderr, "xprobe: server sent an error for GetGeometry\n");
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