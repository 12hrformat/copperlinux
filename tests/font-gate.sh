#!/usr/bin/env bash
# Gate for the console font, and for the glyphs the tools actually print.
#
# Why this exists
# ---------------
# Copper's console showed a screen of question marks where fastfetch's
# separators -- and every other non-ASCII glyph -- should have been. It was
# not the locale this time: the kernel console draws from ONE bitmap font with
# no per-glyph fallback, so a codepoint the font does not carry is printed as a
# literal "?". xfce4-terminal never shows that bug, because VTE asks fontconfig
# for each missing glyph and the console cannot.
#
# The fix is a 512-glyph console font (Uni2-VGA16) loaded by copper-init through
# the busybox setfont applet, plus the terminal fonts and a fontconfig fallback
# chain for the GUI half. Every one of those pieces is a file that can go
# missing in a cleanup or a rebase and nothing else would notice until somebody
# booted the image and looked at the screen -- so this gate reads the shipped
# files and fails if any of them stops doing its job.
#
# What it asserts
# ---------------
#   * the font in the overlay is a PSF1 with a 512-glyph unicode table (the
#     form busybox setfont reads without CONFIG_FEATURE_LOADFONT_PSF2), and it
#     carries box drawing, blocks, shades, arrows and the solid shapes;
#   * every non-ASCII codepoint the shipped fastfetch config prints is in that
#     font -- including the colors module's symbol, which is resolved from its
#     config name rather than hard-coded;
#   * copper-init loads the font in run_session() BEFORE the wizard can draw;
#   * the build enables and asserts the setfont applet, and stages the extra
#     terminal fonts + fontconfig;
#   * fontconfig prefers a monospace face that exists and keeps the symbol
#     fonts as fallbacks;
#   * the font's provenance note ships with it (it is public domain, but the
#     image should say where a binary blob came from).
#
# It also proves the font parser is not vacuous: a copy with a smashed magic
# number must be rejected, and a copy with one glyph removed must be reported
# as missing that glyph.
#
# handcrafted by 12hrformat (bug 55: a console of question marks)
#
# Ten kilobytes of public-domain font, one afternoon of "why is every dash a
# question mark", and the kernel still cannot fall back per glyph. Worth it.
#
# Run: bash tests/font-gate.sh   (no root needed; needs python3)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO/iso/rootfs-overlay"
FONT="$OVERLAY/usr/share/consolefonts/Uni2-VGA16.psf"
CONF="$OVERLAY/etc/fonts/conf.d/61-copper-fonts.conf"
NOTE="$OVERLAY/usr/share/doc/copper-console-font/README"
INIT="$REPO/iso/src-init/copper-init.c"
BUILD="$REPO/iso/build.sh"
FFCONF="$OVERLAY/etc/fastfetch/config.jsonc"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1${2:+ -- $2}"; fail=$((fail + 1)); }

[ -f "$FONT" ] || { bad "console font is missing" "$FONT"; exit 1; }
[ -f "$BUILD" ] || { bad "build.sh is missing" "$BUILD"; exit 1; }
[ -f "$INIT" ] || { bad "copper-init.c is missing" "$INIT"; exit 1; }

# ---------------------------------------------------------------------------
# The font itself, and the characters the shipped fastfetch config can print.
# python3 does the binary parsing; it reports in the same ok/FAIL shape as the
# shell so branch-gate can count it without knowing which language failed.
python3 - "$FONT" "$FFCONF" "$OVERLAY/usr/share/copper/fastfetch-logo.txt" "$CONF" <<'PY'
import re
import struct
import sys
import tempfile
import os
import xml.etree.ElementTree as ET

font_path, ff_path, logo_path, conf_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
failed = 0


def ok(msg):
    print("  ok    " + msg)


def bad(msg, detail=""):
    global failed
    failed += 1
    print("  FAIL  " + msg + ((" -- " + detail) if detail else ""))


def unicode_table(data):
    """Return (slots, set_of_codepoints) for a PSF1/PSF2 blob."""
    if len(data) < 4:
        raise ValueError("file is shorter than a PSF header")
    if data[0] == 0x36 and data[1] == 0x04:
        mode, charsize = data[2], data[3]
        slots = 512 if mode & 1 else 256
        if not (mode & 2):
            return slots, set()
        off = 4 + slots * charsize
        codes = struct.unpack_from("<%dH" % ((len(data) - off) // 2), data, off)
        uni, cur = set(), []
        for c in codes:
            if c == 0xFFFF:
                uni.update(cur)
                cur = []
            else:
                cur.append(c)
        uni.update(cur)
        return slots, uni
    if data[:4] == b"\x72\xb5\x4a\x86":
        _, _, hdr, flags, slots, charsize, _, _ = struct.unpack_from("<IIIIIIII", data, 0)
        if not (flags & 1):
            return slots, set()
        off = hdr + slots * charsize
        codes = struct.unpack_from("<%dI" % ((len(data) - off) // 4), data, off)
        uni, cur = set(), []
        for c in codes:
            if c == 0xFFFFFFFF:
                uni.update(cur)
                cur = []
            else:
                cur.append(c)
        uni.update(cur)
        return slots, uni
    raise ValueError("neither PSF1 (36 04) nor PSF2 (72 b5 4a 86)")


data = open(font_path, "rb").read()
try:
    slots, uni = unicode_table(data)
except ValueError as e:
    bad("console font is a font busybox setfont cannot read", str(e))
    sys.exit(0)

if data[0:2] == b"\x36\x04":
    ok("console font is PSF1 (busybox setfont reads it without the PSF2 feature)")
else:
    bad("console font is PSF2", "needs CONFIG_FEATURE_LOADFONT_PSF2 in busybox")
if slots == 512:
    ok("console font uses all 512 slots")
else:
    bad("console font has %d slots, expected 512" % slots)
if uni:
    ok("console font carries a unicode table (%d codepoints)" % len(uni))
else:
    bad("console font has no unicode table", "the console maps bytes, not text")

REQUIRED = {
    0x2500: "U+2500 box drawing, fastfetch's separator",
    0x2502: "U+2502 vertical box drawing",
    0x250C: "U+250C box corner",
    0x2514: "U+2514 box corner",
    0x251C: "U+251C box tee",
    0x256D: "U+256D rounded box corner",
    0x2588: "U+2588 full block, the colors 'block' symbol",
    0x2591: "U+2591 shade",
    0x25CF: "U+25CF black circle, the colors 'circle' symbol",
    0x2190: "U+2190 left arrow",
    0x2192: "U+2192 right arrow",
    0x25B6: "U+25B6 play triangle",
    0x2022: "U+2022 bullet",
    0x00E9: "U+00E9 e-acute (Latin still has to render)",
    0x20AC: "U+20AC euro sign",
}
missing = [name for cp, name in REQUIRED.items() if cp not in uni]
if missing:
    bad("console font is missing shapes the tools use", ", ".join(missing))
else:
    ok("console font carries box drawing, blocks, arrows and Latin-1")

# Everything the shipped fastfetch config prints must be in the font. Read the
# real config: format strings, the logo file, and the colors symbol (which the
# config names, so resolve it the way fastfetch does).
SYMBOLS = {
    "circle": "\u25cf ",
    "block": "\u2588",
    "diamond": "\u25c6 ",
    "triangle": "\u25b2 ",
    "square": "\u25a0 ",
    "star": "\u2605 ",
    "background": "",
}
printed = set()
try:
    text = open(ff_path, encoding="utf-8").read()
except OSError as e:
    bad("fastfetch config is unreadable", str(e))
    text = ""
for m in re.finditer(r'"format"\s*:\s*"((?:[^"\\]|\\.)*)"', text):
    # {#34} is a colour escape, not text.
    plain = re.sub(r"\{[#a-z0-9-]+\}", "", m.group(1))
    plain = plain.replace("\\n", "").replace('\\"', '"')
    printed.update(ch for ch in plain if ord(ch) > 0x7F)
for m in re.finditer(r'"symbol"\s*:\s*"([a-z]+)"', text):
    name = m.group(1)
    if name not in SYMBOLS:
        bad("fastfetch colors symbol '%s' is unknown to this gate" % name)
        continue
    printed.update(ch for ch in SYMBOLS[name] if ord(ch) > 0x7F)
try:
    logo = open(logo_path, "rb").read()
except OSError:
    logo = b""
if any(b > 0x7F for b in logo):
    bad("fastfetch logo is not ASCII", "the console font cannot carry its art")
else:
    ok("fastfetch logo is ASCII (renders on any console font)")
if printed:
    lacking = sorted({cp for cp in map(ord, printed) if cp not in uni})
    if lacking:
        bad(
            "fastfetch prints codepoints the console font lacks",
            " ".join("U+%04X" % cp for cp in lacking),
        )
    else:
        ok(
            "every codepoint fastfetch prints is in the console font (%d)"
            % len(printed)
        )
else:
    bad("fastfetch config printed no non-ASCII text", "did the config parse?")

# Prove the parser can fail: same font with a smashed magic number, and the
# same font with one required glyph's table entry removed.
tmp = tempfile.mkdtemp()
try:
    smashed = os.path.join(tmp, "smashed.psf")
    with open(font_path, "rb") as src, open(smashed, "wb") as dst:
        blob = bytearray(src.read())
        blob[0] = 0x00
        dst.write(blob)
    try:
        unicode_table(open(smashed, "rb").read())
        bad("a smashing of the font magic was accepted")
    except ValueError:
        ok("a smashing of the font magic is rejected")

    if 0x2500 in uni:
        carved = os.path.join(tmp, "carved.psf")
        blob = bytearray(data)
        off = 4 + slots * data[3]
        # The unicode table is a run of UTF-16LE codepoints separated by
        # 0xFFFF. Turn every U+2500 into U+FFFF so that glyph maps to nothing.
        for i in range(off, len(blob) - 1, 2):
            if struct.unpack_from("<H", blob, i)[0] == 0x2500:
                struct.pack_into("<H", blob, i, 0xFFFF)
        open(carved, "wb").write(blob)
        _, carved_uni = unicode_table(open(carved, "rb").read())
        if 0x2500 in carved_uni:
            bad("a font with U+2500 removed still reports U+2500")
        else:
            ok("a font with U+2500 removed is reported as missing it")
finally:
    for name in os.listdir(tmp):
        os.unlink(os.path.join(tmp, name))
    os.rmdir(tmp)

# fontconfig drops a conf.d file it cannot parse and says so only in a log
# nobody reads, which silently loses the whole fallback chain.
try:
    tree = ET.parse(conf_path)
    root = tree.getroot()
    if root.tag != "fontconfig":
        bad("fontconfig file has the wrong root element", root.tag)
    else:
        ok("fontconfig file is well-formed XML")
    aliases = [a for a in root.findall("alias")]
    fams = [
        f.text
        for a in aliases
        for p in a.findall("prefer")
        for f in p.findall("family")
        if f.text
    ]
    if "DejaVu Sans Mono" in fams:
        ok("monospace is pinned to a face that ships (DejaVu Sans Mono)")
    else:
        bad("monospace alias does not name DejaVu Sans Mono", str(fams))
    appended = [
        s.text
        for m in root.findall("match")
        for e in m.findall("edit")
        for s in e.findall("string")
        if s.text
    ]
    for want in ("Noto Color Emoji", "Symbola", "DejaVu Sans"):
        if want in appended:
            ok("fontconfig keeps %s as a per-glyph fallback" % want)
        else:
            bad("fontconfig does not append %s" % want)
except (OSError, ET.ParseError) as e:
    bad("fontconfig file does not parse", str(e))

sys.exit(1 if failed else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# copper-init loads it, early enough to matter.
if grep -q '^static void load_console_font(void)' "$INIT"; then
    ok "copper-init has load_console_font()"
else
    bad "copper-init has no load_console_font()" "nothing loads the font"
fi
if grep -q 'setfont' "$INIT"; then
    ok "copper-init calls the setfont applet"
else
    bad "copper-init never calls setfont"
fi
if grep -q '"/dev/tty1"' "$INIT"; then
    ok "the font is loaded onto /dev/tty1 (the console the shell uses)"
else
    bad "copper-init does not pin the console to /dev/tty1"
fi
call_line=$(grep -n '^[[:space:]]*load_console_font();' "$INIT" | head -1 | cut -d: -f1)
wiz_line=$(grep -n 'if (stat("/etc/copper-firstboot.done"' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$call_line" ] && [ -n "$wiz_line" ] && [ "$call_line" -lt "$wiz_line" ]; then
    ok "the font is loaded before the wizard draws (line $call_line < $wiz_line)"
else
    bad "load_console_font() is called after the wizard" "line ${call_line:-?} vs ${wiz_line:-?}"
fi

# ---------------------------------------------------------------------------
# The build keeps the applet and the packages.
if grep -q 'SETFONT' "$BUILD" && grep -q 'set_bb_config SETFONT' "$BUILD"; then
    ok "build.sh enables and asserts CONFIG_SETFONT"
else
    bad "build.sh does not enable CONFIG_SETFONT" "busybox would have no setfont"
fi
for pkg in fonts-hack fonts-jetbrains-mono fonts-firacode \
           fonts-liberation fontconfig; do
    if grep -q "$pkg" "$BUILD"; then
        ok "build.sh stages $pkg"
    else
        bad "build.sh does not stage $pkg"
    fi
done
# fonts-noto-extra is 334 MB installed and fonts-liberation2 is a transitional
# dummy package: both look like an upgrade and are one line away from doubling
# the ISO, so their absence is a check too.
if grep -q 'fonts-noto-extra' "$BUILD"; then
    bad "build.sh stages fonts-noto-extra" "334 MB installed; fonts-noto-core already has the symbols"
else
    ok "build.sh stays away from the 334 MB fonts-noto-extra"
fi
if grep -q 'fonts-liberation2' "$BUILD"; then
    bad "build.sh stages fonts-liberation2" "transitional; the real package is fonts-liberation"
else
    ok "build.sh names the real liberation package, not the transitional one"
fi

# ---------------------------------------------------------------------------
# The fontconfig fallback chain.
for want in 'DejaVu Sans Mono' 'Noto Color Emoji' 'Symbola' 'braille'; do
    if grep -qi "$want" "$CONF" 2>/dev/null; then
        ok "fontconfig mentions $want"
    else
        bad "fontconfig never mentions $want" "$CONF"
    fi
done
if grep -q '</fontconfig>' "$CONF" 2>/dev/null; then
    ok "fontconfig file is closed"
else
    bad "fontconfig file is not closed" "$CONF"
fi

# ---------------------------------------------------------------------------
# The provenance note.
if grep -qi 'public domain' "$NOTE" 2>/dev/null; then
    ok "the font ships with its licence note"
else
    bad "no provenance note for the console font" "$NOTE"
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED: $fail console-font check(s) failed." >&2
    exit 1
fi
exit 0
