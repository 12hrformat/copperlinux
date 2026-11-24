# GRUB bootloader provider for the Copper live ISO.
# build.sh sources the provider named by COPPER_BOOTLOADER (default: grub) and
# calls two hooks: bootloader_configure <staged-root> writes this bootloader's
# menu before hashing, and bootloader_make_iso <tgt> <iso> <work> packages the media.
# A replacement provider only supplies those two functions; the menu comes from
# iso/boot/entries, so adding an init or session entry is not a bootloader edit.

# Render the shared entries into GRUB's menu; comments there are docs, not menu text.
bootloader_configure() { # bootloader_configure <tgt>
  local tgt=$1
  mkdir -p "$tgt/boot/grub"
  awk -F'|' '
    BEGIN {
      print "# Copper Linux"
      print "set timeout=5"
      print "set default=0"
      print ""
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 3 { next }
    {
      printf "menuentry \"%s\" {\n", $2
      print "    insmod all_video"
      print "    insmod iso9660"
      print "    insmod part_msdos"
      print "    search --set=root --file /boot/grub/grub.cfg"
      printf "    linux /boot/vmlinuz %s\n", $3
      print "    initrd /boot/initrd.img"
      print "}"
      print ""
    }
  ' "$ROOT/boot/entries" > "$tgt/boot/grub/grub.cfg"
}

# grub-mkrescue reaches xorriso through PATH and hardcodes -r ("rationalised" Rock
# Ridge): modes flatten to 444/555, uid/gid to 0, setuid stripped -- that is how
# sudo lost its setuid bit. Put a one-job -r -> -R filter first; no switch exists.
bootloader_make_iso() { # bootloader_make_iso <tgt> <iso> <work>
  local tgt=$1 iso=$2 wrk=$3
  local real xw
  real=$(command -v xorriso) || { echo "iso: xorriso not found" >&2; exit 1; }
  xw="$wrk/iso-xorriso"
  rm -rf "$xw"; mkdir -p "$xw"
  cat > "$xw/xorriso" <<'WRAP'
#!/bin/sh
# Exec the real xorriso with grub-mkrescue's -r turned into -R. COPPER_REAL_XORRISO
# is set by the caller so this does not recursively find itself on PATH.
real=${COPPER_REAL_XORRISO:?}
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    a=$1; shift
    [ "$a" = "-r" ] && a="-R"
    set -- "$@" "$a"
done
exec "$real" "$@"
WRAP
  chmod 0755 "$xw/xorriso"
  echo "==> grub-mkrescue"
  PATH="$xw:$PATH" COPPER_REAL_XORRISO="$real" \
    grub-mkrescue -o "$iso" "$tgt"
  [ -s "$iso" ] || { echo "grub-mkrescue failed"; exit 1; }
}

# Read the menu back off the disc (bug 25/7): the splash entry needs the plymouth
# switches, quiet, and tty0 LAST so /dev/console is not a serial port the VM lacks.
bootloader_check() { # bootloader_check <iso> <extract-dir>
  local iso=$1 ex=$2
  xorriso -osirrox on -indev "$iso" \
      -extract /boot/grub/grub.cfg "$ex/grub.cfg" >/dev/null 2>&1 || true
  if [ ! -f "$ex/grub.cfg" ]; then
    echo "iso: no /boot/grub/grub.cfg in the ISO -- nothing would boot" >&2
    exit 1
  fi
  local cl badsw=""
  cl=$(sed -n '/^[[:space:]]*linux .*splash/p' "$ex/grub.cfg" | head -n1)
  local sw
  for sw in splash plymouth.ignore-udev plymouth.ignore-serial-consoles \
            quiet loglevel=3 systemd.show_status=1; do
    case " $cl " in
      *" $sw "*) ;;
      *) badsw="$badsw $sw" ;;
    esac
  done
  if [ -z "$cl" ] || [ -n "$badsw" ]; then
    echo "iso: the splash entry's kernel command line is wrong (missing:$badsw):" >&2
    echo "iso:   $cl" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$cl" | grep -o 'console=[^ ]*' | tail -n1)" != "console=tty0" ]; then
    echo "iso: the last console= on the splash entry is not tty0:" >&2
    echo "iso:   $cl" >&2
    echo "iso: /dev/console is the LAST one; the screen would go quiet (bug 7)" >&2
    exit 1
  fi
  echo "  iso: splash switches, quiet, and tty0-last console order on the disc's grub.cfg"
}
