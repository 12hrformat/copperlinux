# Copper Theme Installer

A native GTK 3 application for Copper Linux that reviews a downloaded theme
archive and installs the parts Copper can actually use, per user, without root.

It is the handler Copper offers in Firefox's **Open With** menu for ZIP and
TAR archives. It is intentionally **not** the default archive handler: the
existing archive manager keeps that role, and this application only appears as
an additional choice.

## What it installs

| Component | Installed under | Applied through |
| --- | --- | --- |
| GTK 2 / GTK 3 theme | `~/.local/share/themes/<name>/` | `xfconf` `xsettings /Net/ThemeName` |
| XFWM4 decorations | `~/.local/share/themes/<name>/` | `xfconf` `xfwm4 /general/theme` |
| Icon theme | `~/.local/share/icons/<name>/` | `xfconf` `xsettings /Net/IconThemeName` |
| Cursor theme | `~/.local/share/icons/<name>/` | `xfconf` `xsettings /Net/CursorThemeName` |
| Fonts | `~/.local/share/fonts/<archive-name>/` | fontconfig (`fc-cache`) |

The XDG data directory is respected, so a user with a custom
`XDG_DATA_HOME` gets the theme in the matching location. The installer never
writes to `/usr`, never runs `sudo`, and never needs root.

Archive containers accepted: **ZIP**, **TAR**, **TAR.GZ**, **TAR.BZ2**,
**TAR.XZ**, including the `.tgz`, `.tbz2` and `.txz` spellings. Nested layouts
(`Pack/MyTheme/gtk-3.0/...`) are detected the same way as flat ones.

## Interface

* Drag a theme archive onto the window, or use **Open Archive…**.
* The review screen lists each detected component with its size, file count
  and warnings. Only complete components can be ticked.
* **Replace existing themes** must be ticked before an existing directory is
  overwritten.
* **Apply to my desktop after installing** is off by default. Ticking it is
  the only way the installer changes XFCE settings.
* On success the window offers **Appearance Settings** and **Window Settings**
  so the user can review the change themselves.

The command line shares the same implementation:

```sh
copper-theme-installer --inspect theme.tar.gz
copper-theme-installer --install theme.tar.gz --replace --no-cache
copper-theme-installer --install theme.tar.gz --component gtk:MyTheme
copper-theme-installer --install theme.tar.gz --apply
```

`--inspect` and `--install` print JSON and work without X11, which is how the
security tests run. `copper-theme-installer ARCHIVE` opens the review window.

## Security model

The archive is treated as hostile input at every stage:

* Absolute paths, `..`, backslashes, control characters, invalid UTF-8 and
  drive-qualified paths (`C:`) are rejected.
* Hard links, device nodes, FIFOs and sockets are rejected.
* Symlinks are accepted only when the target is relative and contains no `..`
  segment. They are created **after** every regular file, so no write can ever
  follow a link.
* Duplicate archive paths and two entries mapping to the same destination are
  rejected.
* Only TAR and ZIP formats are accepted. 7z, RAR and other optional libarchive
  backends are refused instead of silently depending on them.
* Size limits: 1 GiB archive, 8 GiB expanded, 512 MiB per file, 250,000
  entries, 4 KiB path length.
* Bundled scripts and executables (`.sh`, shebang, ELF, `.exe`, …) are listed
  in the warnings and are never run or installed.
* Fonts are checked by magic number, not just by extension, before being
  copied into the font directory.
* The installer re-normalises every path during extraction; the inspection
  pass is not treated as a security boundary.
* Files are written with `O_EXCL | O_NOFOLLOW` and committed by renaming a
  private staging directory into place. A failure rolls back replaced themes.
* A pre-existing symlink in `~/.local`, `~/.local/share` or `~/.local/share/themes`
  is refused rather than followed.
* The application never executes code from an archive and makes no network
  requests.

The desktop entry declares only archive MIME types
(`application/zip`, `application/x-tar`, `application/x-compressed-tar`,
`application/x-bzip-compressed-tar`, `application/x-xz-compressed-tar`). It
does not claim images, text, PDFs, 7z, RAR, or generic binary files, and it
does not set itself as the default handler.

## GTK 4 and libadwaita

GTK 4 themes are not the same format as GTK 3 themes, and libadwaita
applications deliberately ignore GTK themes unless the application opts in.
Installing a `gtk-4.0/` directory would therefore create the impression that
libadwaita applications changed when they did not. The inspector reports those
files as unsupported instead of installing a broken promise. GNOME Shell,
Cinnamon, Metacity, Openbox, Plank and similar directories are likewise
reported and skipped.

## Build

Requirements on Ubuntu 24.04 / Copper's build host:

```sh
sudo apt-get install build-essential pkg-config libgtk-3-dev libarchive-dev
make -C apps/copper-theme-installer
```

Install into a staging root with:

```sh
make -C apps/copper-theme-installer install DESTDIR=/tmp/stage PREFIX=/usr
```

## Test

```sh
make -C apps/copper-theme-installer check
# or, after building:
bash tests/theme-installer.sh
```

The gate generates its own fixtures with `tests/make-theme-fixtures.py` and
covers:

* every supported container and a nested layout;
* GTK, XFWM4, icon, cursor and font components;
* traversal, absolute paths, backslash paths, absolute/`..` symlinks,
  hard links, FIFOs, duplicates, over-long paths, malformed gzip, empty
  archives and an unsupported GTK 4-only archive;
* conflicts, explicit replace, selective `--component` installs;
* scripts not being run or installed, font magic filtering, safe symlinks;
* per-user unprivileged installation and file modes;
* refusal of a symlinked `~/.local/share/themes`;
* desktop entry and icon validation (`desktop-file-validate` when present);
* the `--help`, `--version`, `--inspect` command-line surface.

The test suite needs `python3`, `tar`, `gzip`, `bzip2` and `xz`; it does not
need a display, root, or network.

## Packaging for Ingot

```sh
sh ./build-theme-installer-pkg.sh 0.1.0
```

The script builds on Ubuntu 24.04 (it refuses other distributions by default
because a newer glibc produces a binary Copper cannot start), stages the app
plus its non-GTK runtime closure, writes
`copper-theme-installer-0.1.0.tar.gz`, and prints a real Ingot package page
with the actual size and SHA-256.

Publish it honestly:

1. Upload the tarball as a GitHub Release asset in `copper-ingot-repo`
   (the `payloads-v1` release is used by the other packages).
2. Put the printed JSON page at
   `iso/copper/pkg/desktop/copper-theme-installer`.
3. Regenerate the index with `tools/index.py`; never hand-edit `index.json`.
4. Install with `ingot install copper-theme-installer` and open a theme from
   Firefox's **Open With** menu.

No page should be committed before the matching tarball exists and its SHA-256
has been computed from those exact bytes.

## Known limitations

* GTK 4 / libadwaita themes are not installed; see above.
* Applying values uses `xfconf-query`, so the XFCE settings daemon and a
  session bus must be running. Without them the files install and the window
  reports that the desktop was not changed.
* Cursor themes need a re-login or an XFCE settings refresh before every
  application picks up the new cursor.
* Icon caches are refreshed with `gtk-update-icon-cache` when available; font
  caches with `fc-cache`. Their absence produces a warning, not a failure.
* Third-party themes may reference assets or fonts they do not ship. The
  installer reports what it installed but does not repair missing assets.
* A font archive is installed into a subdirectory named after the archive, not
  flattened into `~/.local/share/fonts`.
* The GUI was built and smoke-tested under the development WSL display; the
  final interactive XFCE check on a booted Copper image remains a manual step.
* Ingot extracts payloads but does not run maintainer scripts. If Firefox's
  **Open With** list does not show the installer immediately after
  installation, run `sudo update-desktop-database /usr/share/applications`
  (or log out and back in); the desktop entry itself is installed correctly.
