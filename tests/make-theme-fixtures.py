#!/usr/bin/env python3
"""Create the synthetic theme archives used by tests/theme-installer.sh.

Everything here is generated, so the tests do not depend on a download or on
a real third-party theme.  The malicious cases are real archives with real
hostile entries, not mocks: the inspector and installer see exactly what a
downloaded file would give them.
"""
import io
import os
import sys
import tarfile
import zipfile

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

FONT = b"\x00\x01\x00\x00" + b"\x00" * 60
BAD_FONT = b"#!/bin/sh\necho this is not a font\n"


def path(name):
    return os.path.join(OUT, name)


def add_bytes(tf, name, data, mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    ti.mtime = 1700000000
    tf.addfile(ti, io.BytesIO(data))


def add_text(tf, name, text, mode=0o644):
    add_bytes(tf, name, text.encode("utf-8"), mode)


def add_symlink(tf, name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    tf.addfile(ti)


def add_hardlink(tf, name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.LNKTYPE
    ti.linkname = target
    tf.addfile(ti)


def add_fifo(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.FIFOTYPE
    ti.mode = 0o644
    tf.addfile(ti)


def add_dir(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    tf.addfile(ti)


GTK_CSS = "/* synthetic copper test theme */\n* { color: #b45f2d; }\n"
GTKRC = 'gtk-theme-name = "Good"\n'
THEMERC = "active_text_color=#ffffff\n"


def add_good_theme(tf, root="Good"):
    add_dir(tf, root)
    add_dir(tf, root + "/gtk-2.0")
    add_dir(tf, root + "/gtk-3.0")
    add_dir(tf, root + "/xfwm4")
    add_text(tf, root + "/index.theme",
             "[Desktop Entry]\nType=X-GNOME-Metatheme\nName=Good\n")
    add_text(tf, root + "/gtk-2.0/gtkrc", GTKRC)
    add_text(tf, root + "/gtk-3.0/gtk.css", GTK_CSS)
    add_text(tf, root + "/xfwm4/themerc", THEMERC)


def tar(name, builder, compression=""):
    mode = "w:" + compression
    with tarfile.open(path(name), mode) as tf:
        builder(tf)


# ---- valid archives in every supported container -------------------------
def good_tar(tf):
    # A leading "./" root marker is what GNU tar writes by default and must not
    # be mistaken for an unsafe empty path.
    add_dir(tf, ".")
    add_good_theme(tf)


tar("good.tar", good_tar)
for suffix, comp in (("good.tar.gz", "gz"), ("good.tar.bz2", "bz2"),
                     ("good.tar.xz", "xz")):
    tar(suffix, good_tar, comp)


def good_zip(zf):
    zf.writestr("Good/index.theme",
                "[Desktop Entry]\nType=X-GNOME-Metatheme\nName=Good\n")
    zf.writestr("Good/gtk-3.0/gtk.css", GTK_CSS)
    zf.writestr("Good/xfwm4/themerc", THEMERC)


with zipfile.ZipFile(path("good.zip"), "w", zipfile.ZIP_DEFLATED) as zf:
    good_zip(zf)


def nested(tf):
    add_dir(tf, "Pack")
    add_good_theme(tf, "Pack/ThemeNested")


tar("nested.tar.gz", nested, "gz")


def icons(tf):
    add_text(tf, "GoodIcons/index.theme",
             "[Icon Theme]\nName=Good Icons\nInherits=hicolor\n")
    add_text(tf, "GoodIcons/16x16/apps/test.png", "png")
    add_text(tf, "GoodIcons/48x48/apps/test.png", "png")


tar("icons.tar.gz", icons, "gz")
with zipfile.ZipFile(path("icons.zip"), "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("GoodIcons/index.theme",
                "[Icon Theme]\nName=Good Icons\nInherits=hicolor\n")
    zf.writestr("GoodIcons/16x16/apps/test.png", "png")


def fonts(tf):
    add_bytes(tf, "fonts/Test.ttf", FONT)
    add_bytes(tf, "fonts/sub/Another.otf", b"OTTO" + b"\x00" * 40)
    add_bytes(tf, "fonts/Fake.ttf", BAD_FONT)


tar("fonts.tar.gz", fonts, "gz")


def scripts(tf):
    add_good_theme(tf, "Scripted")
    add_text(tf, "Scripted/gtk-3.0/payload.sh",
             "#!/bin/sh\ntouch /tmp/copper-theme-was-run\n", 0o755)


tar("scripted.tar.gz", scripts, "gz")


def safe_link(tf):
    add_good_theme(tf, "Linked")
    add_symlink(tf, "Linked/gtk-3.0/alias.css", "gtk.css")


tar("symlink-safe.tar.gz", safe_link, "gz")


def cursor_theme(tf):
    add_text(tf, "GoodCursors/index.theme",
             "[Icon Theme]\nName=Good Cursors\nInherits=hicolor\n")
    add_text(tf, "GoodCursors/cursor.theme",
             "[Icon Theme]\nName=Good Cursors\n")
    add_text(tf, "GoodCursors/cursors/left_ptr", "Xcur")


tar("cursors.tar.gz", cursor_theme, "gz")


def combined(tf):
    add_good_theme(tf, "Combined")
    add_text(tf, "CombinedIcons/index.theme",
             "[Icon Theme]\nName=Combined Icons\nInherits=hicolor\n")
    add_text(tf, "CombinedIcons/48x48/apps/test.png", "png")
    add_bytes(tf, "Fonts/Combined.ttf", FONT)


tar("combined.tar.gz", combined, "gz")


# ---- hostile archives ----------------------------------------------------
def traversal(tf):
    add_text(tf, "../evil/gtk-3.0/gtk.css", GTK_CSS)


tar("bad-traversal.tar", traversal)


def absolute(tf):
    add_text(tf, "/tmp/evil/gtk-3.0/gtk.css", GTK_CSS)


tar("bad-absolute.tar", absolute)


def backslash(tf):
    add_text(tf, "Bad\\gtk-3.0\\gtk.css", GTK_CSS)


tar("bad-backslash.tar", backslash)


def symlink_absolute(tf):
    add_good_theme(tf, "EvilLink")
    add_symlink(tf, "EvilLink/gtk-3.0/passwd", "/etc/passwd")


tar("bad-symlink-absolute.tar", symlink_absolute)


def symlink_dotdot(tf):
    add_good_theme(tf, "EvilLink2")
    add_symlink(tf, "EvilLink2/gtk-3.0/passwd", "../../../../etc/passwd")


tar("bad-symlink-dotdot.tar", symlink_dotdot)


def hardlink(tf):
    add_good_theme(tf, "Hard")
    add_hardlink(tf, "Hard/gtk-3.0/alias.css", "Hard/gtk-3.0/gtk.css")


tar("bad-hardlink.tar", hardlink)


def fifo(tf):
    add_good_theme(tf, "Fifo")
    add_fifo(tf, "Fifo/gtk-3.0/pipe")


tar("bad-fifo.tar", fifo)


def duplicate(tf):
    add_text(tf, "Dup/gtk-3.0/gtk.css", GTK_CSS)
    add_text(tf, "Dup/gtk-3.0/gtk.css", "/* second copy */\n")


tar("bad-duplicate.tar", duplicate)


def long_path(tf):
    add_text(tf, "Long/" + ("a" * 5000) + "/gtk-3.0/gtk.css", GTK_CSS)


tar("bad-long-path.tar", long_path)


def gtk4_only(tf):
    add_text(tf, "OnlyFour/gtk-4.0/gtk.css", GTK_CSS)


tar("gtk4-only.tar", gtk4_only)


with tarfile.open(path("empty.tar"), "w"):
    pass

with open(path("bad-garbage.tar.gz"), "wb") as f:
    f.write(b"\x1f\x8b\x08\x00" + b"not actually gzip" * 20)

# A ZIP with an entry that escapes after the archive's own prefix.  ZIP has no
# directory objects here, which also exercises the flat-layout path.
with zipfile.ZipFile(path("bad-zip-traversal.zip"), "w") as zf:
    zf.writestr("../outside/gtk-3.0/gtk.css", GTK_CSS)

print("fixtures written to " + OUT)
