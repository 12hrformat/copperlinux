#!/usr/bin/env bash
# Gate for copper-theme-installer.
#
# The tests are deliberately black-box: they run the same binary the desktop
# launches, against synthetic archives generated next to them.  Nothing here
# needs an X session, root, or a network.  Run: make -C apps/copper-theme-installer check
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
APP="$REPO/apps/copper-theme-installer"
BIN=${BIN:-"$APP/copper-theme-installer"}
PYTHON=${PYTHON:-python3}
DESKTOP="$APP/data/copper-theme-installer.desktop"
ICON="$APP/data/copper-theme-installer.svg"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1${2:+ -- $2}"; fail=$((fail + 1)); }

[ -x "$BIN" ] || { bad "installer binary is missing" "$BIN (run make)"; exit 1; }
command -v "$PYTHON" >/dev/null || { bad "python3 is required for the fixtures"; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/copper-theme-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

"$PYTHON" "$REPO/tests/make-theme-fixtures.py" "$work/fixtures" >/dev/null || {
    bad "could not generate fixtures"; exit 1;
}
F="$work/fixtures"

# ---------------------------------------------------------------------------
# Inspection: valid containers and component detection.
inspect_to() {
    "$BIN" --inspect "$1" >"$work/out.json" 2>"$work/err.txt"
    echo $?
}

expect_valid() {
    local archive=$1 label=$2
    local rc; rc=$(inspect_to "$F/$archive")
    if [ "$rc" -eq 0 ] && grep -q '"valid": true' "$work/out.json"; then
        ok "$label is accepted"
    else
        bad "$label is rejected" "rc=$rc $(head -c 200 "$work/err.txt")"
    fi
}

for spec in \
    "good.tar:uncompressed TAR" \
    "good.tar.gz:TAR.GZ" \
    "good.tar.bz2:TAR.BZ2" \
    "good.tar.xz:TAR.XZ" \
    "good.zip:ZIP" \
    "nested.tar.gz:TAR.GZ with a nested layout" \
    "icons.tar.gz:TAR.GZ icon theme" \
    "icons.zip:ZIP icon theme" \
    "cursors.tar.gz:cursor theme" \
    "fonts.tar.gz:font archive" \
    "symlink-safe.tar.gz:archive with a safe internal symlink" \
    "scripted.tar.gz:archive containing a script" \
    "combined.tar.gz:combined theme archive"; do
    expect_valid "${spec%%:*}" "${spec#*:}"
done

# Component detection, not just "valid".
inspect_to "$F/good.tar.gz" >/dev/null
grep -q '"kind": "gtk"' "$work/out.json" && grep -q '"kind": "xfwm4"' "$work/out.json" \
    && ok "GTK and XFWM4 components are detected in one theme directory" \
    || bad "GTK/XFWM4 detection failed"

inspect_to "$F/cursors.tar.gz" >/dev/null
grep -q '"kind": "cursors"' "$work/out.json" \
    && ok "cursor theme is detected by cursors/ and metadata" \
    || bad "cursor theme was not detected"

inspect_to "$F/icons.zip" >/dev/null
grep -q '"kind": "icons"' "$work/out.json" \
    && ok "icon theme is detected from index.theme" \
    || bad "icon theme was not detected"

inspect_to "$F/fonts.tar.gz" >/dev/null
grep -q '"kind": "fonts"' "$work/out.json" \
    && ok "fonts are detected by extension and magic" \
    || bad "font component was not detected"

inspect_to "$F/scripted.tar.gz" >/dev/null
grep -q '"skipped_scripts": 1' "$work/out.json" \
    && ok "bundled scripts are reported and will not be run" \
    || bad "bundled script was not reported"

inspect_to "$F/gtk4-only.tar" >/dev/null
if grep -q '"valid": false' "$work/out.json" && grep -q 'GTK 4' "$work/out.json"; then
    ok "GTK 4-only archive is refused with an honest explanation"
else
    bad "GTK 4-only archive was not handled honestly"
fi

# ---------------------------------------------------------------------------
# Inspection: hostile and malformed archives must fail closed.
for archive in \
    bad-traversal.tar bad-absolute.tar bad-backslash.tar \
    bad-symlink-absolute.tar bad-symlink-dotdot.tar bad-hardlink.tar \
    bad-fifo.tar bad-duplicate.tar bad-long-path.tar bad-garbage.tar.gz \
    bad-zip-traversal.zip empty.tar; do
    rc=$(inspect_to "$F/$archive")
    if [ "$rc" -ne 0 ] && grep -q '"valid": false' "$work/out.json"; then
        ok "$archive is rejected"
    else
        bad "$archive was accepted" "rc=$rc"
    fi
done

if [ ! -e /tmp/evil ] && [ ! -e "$F/../evil" ]; then
    ok "inspection created no files outside the archive"
else
    bad "inspection escaped its staging area"
fi

# ---------------------------------------------------------------------------
# Installation, conflicts, replacement and per-user permissions.
export HOME="$work/home"
export XDG_DATA_HOME="$work/home/.local/share"
mkdir -p "$HOME"
DATA="$XDG_DATA_HOME"

if "$BIN" --install "$F/combined.tar.gz" --no-cache >"$work/install.json" 2>"$work/install.err"; then
    ok "archive installs without root"
else
    bad "archive did not install" "$(cat "$work/install.err")"
fi
grep -q '"ok": true' "$work/install.json" \
    && ok "install reports success as JSON" || bad "install result JSON is wrong"

for f in \
    "themes/Combined/index.theme" \
    "themes/Combined/gtk-3.0/gtk.css" \
    "themes/Combined/xfwm4/themerc" \
    "icons/CombinedIcons/index.theme" \
    "icons/CombinedIcons/48x48/apps/test.png" \
    "fonts/combined/Combined.ttf"; do
    if [ -f "$DATA/$f" ]; then
        ok "installed $f"
    else
        bad "missing $f"
    fi
done

badmode=$(find "$DATA/themes/Combined" "$DATA/icons/CombinedIcons" "$DATA/fonts/combined" \
    -type f ! -perm 0644 -print -quit)
[ -z "$badmode" ] && ok "installed files are mode 0644" \
    || bad "installed file has unexpected mode" "$badmode"

# A second install must not silently overwrite.
if "$BIN" --install "$F/combined.tar.gz" --component gtk:Combined --no-cache \
        >"$work/conflict.json" 2>"$work/conflict.err"; then
    bad "a conflicting install succeeded without --replace"
else
    grep -qi 'already installed' "$work/conflict.err" \
        && ok "conflict is refused with a clear message" \
        || bad "conflict message is unclear" "$(cat "$work/conflict.err")"
fi

# Replace is a whole-directory transaction: stale files disappear.
touch "$DATA/themes/Combined/STALE"
if "$BIN" --install "$F/combined.tar.gz" --replace --no-cache \
        >"$work/replace.json" 2>"$work/replace.err"; then
    ok "an existing theme can be replaced explicitly"
else
    bad "explicit replace failed" "$(cat "$work/replace.err")"
fi
[ ! -e "$DATA/themes/Combined/STALE" ] \
    && ok "replace removes stale files from the old theme" \
    || bad "replace left a stale file behind"

# Component selection installs only what was asked for.
rm -rf "$DATA"
if "$BIN" --install "$F/combined.tar.gz" --component gtk:Combined --no-cache \
        >"$work/partial.json" 2>"$work/partial.err"; then
    if [ -d "$DATA/themes/Combined" ] && [ ! -e "$DATA/icons/CombinedIcons" ] \
       && [ ! -e "$DATA/fonts/combined" ]; then
        ok "--component installs only the selected component"
    else
        bad "--component installed more than requested"
    fi
else
    bad "component-selective install failed" "$(cat "$work/partial.err")"
fi

# Scripts inside an accepted archive are never executed.
rm -f /tmp/copper-theme-was-run
rm -rf "$DATA"
"$BIN" --install "$F/scripted.tar.gz" --no-cache >/dev/null 2>&1
if [ ! -e /tmp/copper-theme-was-run ] && [ ! -e "$DATA/themes/Scripted/gtk-3.0/payload.sh" ]; then
    ok "bundled script is neither run nor installed"
else
    bad "bundled script was run or installed"
fi

# Safe internal symlinks are installed as links, not followed.
rm -rf "$DATA"
"$BIN" --install "$F/symlink-safe.tar.gz" --no-cache >/dev/null 2>&1
link="$DATA/themes/Linked/gtk-3.0/alias.css"
if [ -L "$link" ] && [ "$(readlink "$link")" = "gtk.css" ]; then
    ok "safe internal symlink is preserved as a relative link"
else
    bad "safe internal symlink was not preserved" "$(ls -l "$link" 2>&1)"
fi

# Invalid font data is skipped, valid font data installed.
rm -rf "$DATA"
"$BIN" --install "$F/fonts.tar.gz" --no-cache >"$work/fonts.json" 2>/dev/null
if [ -f "$DATA/fonts/fonts/Test.ttf" ] && [ ! -e "$DATA/fonts/fonts/Fake.ttf" ]; then
    ok "font magic decides what is installed (fake .ttf skipped)"
else
    bad "font validation did not filter fake fonts"
fi

# A symlink placed where the installer must create a directory is refused.
outside="$work/outside"
mkdir -p "$outside"
mkdir -p "$work/linkhome/.local/share"
ln -s "$outside" "$work/linkhome/.local/share/themes"
if HOME="$work/linkhome" XDG_DATA_HOME="$work/linkhome/.local/share" \
        "$BIN" --install "$F/good.tar.gz" --no-cache >/dev/null 2>"$work/link.err"; then
    bad "install followed a symlinked data directory"
else
    if [ -z "$(ls -A "$outside")" ]; then
        ok "a symlinked themes directory is refused and left untouched"
    else
        bad "install escaped through the symlinked themes directory"
    fi
fi

# ---------------------------------------------------------------------------
# Non-root installation.  When the suite itself runs as a normal user this is
# already proven above; as root, re-run the install as nobody when the tools
# for dropping privileges are available.
nonroot_result=""
if [ "$(id -u)" -ne 0 ]; then
    nonroot_result="skipped: the suite is already running unprivileged"
else
    unpriv=""
    if command -v setpriv >/dev/null 2>&1; then
        unpriv="setpriv --reuid=65534 --regid=65534 --clear-groups"
    elif command -v runuser >/dev/null 2>&1 && id -u nobody >/dev/null 2>&1; then
        unpriv="runuser -u nobody --"
    fi
    if [ -n "$unpriv" ]; then
        nrhome="$work/nrhome"
        mkdir -p "$nrhome"
        chown 65534:65534 "$nrhome" 2>/dev/null || true
        chmod -R a+rX "$work/fixtures" 2>/dev/null || true
        chmod a+rx "$work"
        cp "$BIN" "$work/copper-theme-installer"
        chmod 0755 "$work/copper-theme-installer"
        if $unpriv env HOME="$nrhome" XDG_DATA_HOME="$nrhome/.local/share" \
                "$work/copper-theme-installer" --install "$F/good.tar.gz" \
                --no-cache >/dev/null 2>"$work/nr.err"; then
            if [ -f "$nrhome/.local/share/themes/Good/gtk-3.0/gtk.css" ] \
               && [ "$(stat -c %u "$nrhome/.local/share/themes/Good/gtk-3.0/gtk.css")" = "65534" ]; then
                nonroot_result="ok"
            else
                nonroot_result="wrong files or owner"
            fi
        else
            nonroot_result="$(cat "$work/nr.err")"
        fi
    else
        nonroot_result="skipped: no setpriv/runuser"
    fi
fi
case "$nonroot_result" in
    ok) ok "installation works as an unprivileged user (uid 65534)" ;;
    skipped:*) ok "non-root installation: ${nonroot_result#skipped: }" ;;
    *) bad "unprivileged installation failed" "$nonroot_result" ;;
esac

# ---------------------------------------------------------------------------
# Desktop integration: this must be an "Open With" handler for archive types,
# never a default handler for images or documents, and never for formats the
# inspector refuses.
if [ -f "$DESKTOP" ]; then
    "$PYTHON" - "$DESKTOP" "$ICON" <<'PY'
import sys
import xml.etree.ElementTree as ET

desktop, icon = sys.argv[1], sys.argv[2]
text = open(desktop, encoding="utf-8").read()
pairs = {}
for line in text.splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        pairs[k] = v

failed = 0


def ok(msg):
    print("  ok    " + msg)


def bad(msg, detail=""):
    global failed
    failed += 1
    print("  FAIL  " + msg + ((" -- " + detail) if detail else ""))


if pairs.get("Type") == "Application":
    ok("desktop entry is an application")
else:
    bad("desktop entry has the wrong Type", pairs.get("Type", "missing"))
if pairs.get("Exec", "").endswith(" %f"):
    ok("desktop entry passes the downloaded file as %f")
else:
    bad("desktop entry does not pass %f", pairs.get("Exec", "missing"))
if pairs.get("TryExec") == "copper-theme-installer":
    ok("desktop entry has TryExec")
else:
    bad("desktop entry has no matching TryExec")
if pairs.get("Terminal", "false").lower() == "false":
    ok("desktop entry runs without a terminal")
else:
    bad("desktop entry requests a terminal")

want = {
    "application/zip",
    "application/x-tar",
    "application/x-compressed-tar",
    "application/x-bzip-compressed-tar",
    "application/x-xz-compressed-tar",
}
mimes = {m for m in pairs.get("MimeType", "").split(";") if m}
missing = want - mimes
if missing:
    bad("desktop entry is missing supported archive MIME types",
        ", ".join(sorted(missing)))
else:
    ok("desktop entry declares exactly the supported archive family")

forbidden = {
    "application/x-7z-compressed", "application/x-rar", "application/x-rar-compressed",
    "image/png", "image/jpeg", "text/plain", "application/pdf",
    "application/octet-stream",
}
bad_mimes = mimes & forbidden
if bad_mimes:
    bad("desktop entry claims unrelated or unsupported types",
        ", ".join(sorted(bad_mimes)))
else:
    ok("desktop entry claims no unrelated types")

if "NoDisplay=true" not in text:
    ok("desktop entry is visible in Open With")
else:
    bad("desktop entry is hidden")

try:
    root = ET.parse(icon).getroot()
    if root.tag.endswith("svg") and root.get("viewBox"):
        ok("application icon is a valid SVG")
    else:
        bad("application icon is not a usable SVG")
except (OSError, ET.ParseError) as e:
    bad("application icon does not parse", str(e))

sys.exit(1 if failed else 0)
PY
    [ $? -eq 0 ] || fail=$((fail + 1))

    if command -v desktop-file-validate >/dev/null 2>&1; then
        if desktop-file-validate "$DESKTOP" >/dev/null 2>&1; then
            ok "desktop-file-validate accepts the entry"
        else
            bad "desktop-file-validate rejects the entry"
        fi
    else
        ok "desktop-file-validate not installed; structural checks used above"
    fi
else
    bad "desktop entry is missing" "$DESKTOP"
fi

# ---------------------------------------------------------------------------
# Command line surface used by the desktop entry and by administrators.
"$BIN" --help >/dev/null 2>&1 && ok "--help works" || bad "--help failed"
"$BIN" --version >/dev/null 2>&1 && ok "--version works" || bad "--version failed"
"$BIN" --inspect "$F/good.tar.gz" >/dev/null 2>&1 \
    && ok "CLI can inspect the exact file a browser hands over" \
    || bad "CLI inspection of a downloaded file failed"

# The window is optional on a headless machine, but it must fail with a clear
# message instead of hanging or opening a broken window.
if env -u DISPLAY -u WAYLAND_DISPLAY "$BIN" "$F/good.tar.gz" \
        >/dev/null 2>"$work/headless.err"; then
    bad "GUI started without a display"
else
    grep -qi 'no graphical display' "$work/headless.err" \
        && ok "GUI reports a missing display instead of hanging" \
        || bad "headless GUI error is unclear" "$(cat "$work/headless.err")"
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED: $fail theme-installer check(s) failed." >&2
    exit 1
fi
echo "all theme-installer checks passed."
exit 0
