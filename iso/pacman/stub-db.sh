#!/usr/bin/env bash
# Make the fake packages that stop Arch from replacing the libraries this
# image already ships.
#
# Usage: stub-db.sh <image root>
#
# Every package listed below exists in Copper already. If they were not in
# pacman's database, an install would pull Arch's copies over the top of the
# working ones. The version numbers are set well above anything Arch ships,
# and pacman.conf says the same thing again under IgnorePkg: leave these
# alone.
set -eu

root="$1"
db="$root/var/lib/pacman/local"

mkdir -p "$db" "$root/var/lib/pacman/sync" \
         "$root/var/cache/pacman/pkg" "$root/var/log" \
         "$root/etc/pacman.d/gnupg" \
         "$root/usr/share/libalpm/hooks" "$root/etc/pacman.d/hooks"

# pacman 6 reads the local database's format version from this file on
# every open. Without it, a non-empty database is "incorrect version".
printf '9\n' > "$db/ALPM_DB_VERSION"

stub() {  # stub <name> <version> <description>
  local dir="$db/$1-$2"
  mkdir -p "$dir"
  {
    echo "%NAME%";    echo "$1"
    echo
    echo "%VERSION%"; echo "$2"
    echo
    echo "%DESC%";    echo "$3"
    echo
    echo "%ARCH%";    echo "x86_64"
  } > "$dir/desc"
}

stub glibc      2.99-1      "GNU C Library"
stub gcc-libs   15.99-1     "Runtime libraries from GCC"
stub bash       5.99-1      "GNU Bourne Again shell"
stub filesystem 2099.1.1-1  "Base Copper Linux files"
stub coreutils  9.99-1      "Core file, shell and text utilities"
stub ncurses    6.99-1      "Terminal handling library"
stub readline   8.99-1      "Command line editing library"
stub zlib       1.99-1      "Compression library"
stub openssl    3.99-1      "Cryptography and TLS library"
stub pacman     6.99-1      "The Pacman package manager"

echo "stub database: $(find "$db" -mindepth 1 -maxdepth 1 -type d | wc -l) packages in $db"
