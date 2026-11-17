#!/bin/sh
# config-gate.sh -- the image-wide choices are real switches, not prose.
#
# One ISO ships both inits, both shells and both audio servers. What picks one
# is a string agreed on by two files that are never compiled together:
#
#   init    the GRUB entry writes copper.init=systemd; iso/live/init reads it
#           and execs /lib/systemd/systemd (else /sbin/init). With nothing on
#           the command line, /etc/copper-init -- the wizard's answer -- decides.
#   shell   /etc/copper.conf's shell=bash|zsh; copper-init exports it as SHELL,
#           the wizard records it in passwd, and kitty execs $SHELL.
#   audio   /etc/copper.conf's audio=pulseaudio|pipewire; both launchers read it
#           and start that server.
#
# A rename on one side of any of those is silent: the image still boots, it just
# ignores the user's answer and starts the default. Nothing else in the suite
# reads both ends of every switch, so this gate does.
#
# Rootless and buildless: it asserts the shipped text on both sides.
#
# Run: tests/config-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
fail=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

has() {   # has <file> <literal> <description>
    if grep -qF -- "$2" "$REPO/$1" 2>/dev/null; then
        ok "$3"
    else
        bad "$3 (no '$2' in $1)"
    fi
}

hasre() { # hasre <file> <extended-regex> <description>
    if grep -qE -- "$2" "$REPO/$1" 2>/dev/null; then
        ok "$3"
    else
        bad "$3 (nothing matching /$2/ in $1)"
    fi
}

hasnt() { # hasnt <file> <literal> <description>
    if grep -qF -- "$2" "$REPO/$1" 2>/dev/null; then
        bad "$3 ('$2' is still in $1)"
    else
        ok "$3"
    fi
}

echo "config: the shipped defaults"
if grep -qx 'shell=bash' "$REPO/iso/rootfs-overlay/etc/copper.conf" 2>/dev/null; then
    ok "/etc/copper.conf defaults shell=bash"
else
    bad "/etc/copper.conf does not default shell=bash"
fi
if grep -qx 'audio=pulseaudio' "$REPO/iso/rootfs-overlay/etc/copper.conf" 2>/dev/null; then
    ok "/etc/copper.conf defaults audio=pulseaudio"
else
    bad "/etc/copper.conf does not default audio=pulseaudio"
fi
has iso/rootfs-overlay/etc/copper.conf 'shell=bash|zsh' \
    "/etc/copper.conf names the shell choices where a user reads them"
has iso/rootfs-overlay/etc/copper.conf 'audio=pulseaudio|pipewire' \
    "/etc/copper.conf names the audio choices where a user reads them"
if [ "$(cat "$REPO/iso/rootfs-overlay/etc/copper-init" 2>/dev/null)" = busybox ]; then
    ok "/etc/copper-init defaults to busybox"
else
    bad "/etc/copper-init does not say busybox"
fi

echo
echo "config: the GRUB menu is the init switch"
has iso/boot/grub.cfg 'menuentry "Copper Linux (systemd init)"' \
    "GRUB offers a systemd-init entry"
hasre iso/boot/grub.cfg 'linux .*copper\.init=systemd' \
    "the systemd entry passes copper.init=systemd"
# The default entry must not name either init: "no switch" is what makes
# /etc/copper-init, and then copper-init itself, the default.
if sed -n '12,44p' "$REPO/iso/boot/grub.cfg" | grep -qE 'copper\.init='; then
    bad "the default GRUB entry names an init (it must leave the choice to /etc/copper-init)"
else
    ok "the default GRUB entry names no init"
fi

echo
echo "config: /init agrees with GRUB"
has iso/live/init 'copper.init=systemd' "/init reads copper.init=systemd"
has iso/live/init 'copper.init=busybox' "/init reads copper.init=busybox"
has iso/live/init '/etc/copper-init' "/init falls back to the wizard's saved init"
has iso/live/init '/lib/systemd/systemd' "/init execs systemd at the merged-usr path"
has iso/live/init 'switch_root /mnt/merged /sbin/init' "/init execs /sbin/init for the default"
# The initramfs is not a rootfs: build_initramfs packs busybox and /init and
# nothing else, so there is no cat, grep or sed in it. A bare external command
# fails silently under `2>/dev/null`, which is how `$(cat /proc/cmdline)`
# made copper.init=systemd look like no arguments at all.
has iso/live/init 'read -r cmdline < /proc/cmdline' \
    "the initramfs reads the command line with the read builtin"
has iso/live/init 'for arg in $cmdline; do' \
    "the init choice parses the command line already read"
hasnt iso/live/init 'cat /proc/cmdline' \
    "the initramfs does not call cat, which is not in it"

echo
echo "config: the wizard asks for all three and writes both files"
has iso/firstboot/copper-firstboot.c 'Which shell, bash or zsh?' \
    "the wizard asks the shell question"
has iso/firstboot/copper-firstboot.c 'Which audio, pulseaudio or pipewire?' \
    "the wizard asks the audio question"
has iso/firstboot/copper-firstboot.c 'Which init, busybox or systemd?' \
    "the wizard asks the init question"
has iso/firstboot/copper-firstboot.c 'fprintf(c, "shell=%s\n", shell_word)' \
    "the wizard writes shell= to /etc/copper.conf"
has iso/firstboot/copper-firstboot.c 'fprintf(c, "audio=%s\n", audio_word)' \
    "the wizard writes audio= to /etc/copper.conf"
has iso/firstboot/copper-firstboot.c 'fprintf(i, "%s\n", init_word)' \
    "the wizard writes /etc/copper-init"
has iso/firstboot/copper-firstboot.c '-s %s %s' \
    "adduser gets the chosen login shell"
has iso/firstboot/copper-firstboot.c 'create_user_direct(user, shell_path)' \
    "the direct passwd writer gets the chosen login shell"
has iso/firstboot/copper-firstboot.c 'cp -a /etc/skel/.zshrc' \
    "the new home gets .zshrc as well as .bashrc"
has iso/firstboot/copper-firstboot.c '"/etc/copper.conf /etc/copper-init %s/etc/"' \
    "persistence carries both config files to the next boot"

echo
echo "config: copper-init boots the chosen shell"
has iso/src-init/copper-init.c 'configured_shell' \
    "copper-init has a /etc/copper.conf shell reader"
has iso/src-init/copper-init.c 'strncmp(line, "shell=", 6)' \
    "it reads the shell= key"
has iso/src-init/copper-init.c 'strcmp(v, "zsh")' "it understands zsh"
has iso/src-init/copper-init.c 'strcmp(v, "bash")' "it understands bash"
has iso/src-init/copper-init.c 'setenv("SHELL"' \
    "it exports SHELL, which kitty and installers read"
has iso/src-init/copper-init.c 'getpwuid(s->uid)' \
    "the passwd entry is the fallback when the config is silent"
has iso/src-init/copper-init.c 'execl("/usr/bin/bash", "-bash"' \
    "bash is the last resort"

echo
echo "config: both launchers read the audio= switch"
for f in iso/startniri.sh iso/startxfce.sh; do
    has "$f" 'copper_audio_backend' "$f selects the audio backend"
    has "$f" 'audio[[:space:]]*=' "$f reads the audio= key from /etc/copper.conf"
    has "$f" 'pipewire-0' "$f waits for the PipeWire graph socket"
    has "$f" 'wireplumber' "$f starts the PipeWire session manager"
    has "$f" 'pipewire-pulse' "$f starts the PulseAudio-protocol front end"
    has "$f" 'pulseaudio --start' "$f still starts PulseAudio when it is chosen"
    has "$f" 'COPPER_AUDIO' "$f keeps the COPPER_AUDIO=0 gate the tests use"
done

echo
echo "config: the mixer is raised, not just a server started"
has iso/rootfs-overlay/usr/bin/copper-audio 'cmd_init' \
    "copper-audio has an init that raises the mixer"
has iso/rootfs-overlay/usr/bin/copper-audio 'sset "$_n" 80% unmute' \
    "copper-audio unmutes and raises the playback controls"
has iso/rootfs-overlay/usr/bin/copper-audio '"$_alsactl" store' \
    "copper-audio stores the mixer state through the alsactl it found"
for f in iso/startniri.sh iso/startxfce.sh; do
    has "$f" 'copper-audio init' "$f raises the mixer after starting the server"
done

echo
echo "config: the build ships both sides of every switch"
has iso/build.sh 'for p in zsh; do' "the gui stage requires an installable zsh"
has iso/build.sh 'for p in pipewire; do' "the gui stage requires pipewire"
has iso/build.sh 'for p in pipewire-pulse; do' "the gui stage requires pipewire-pulse"
has iso/build.sh 'for p in wireplumber; do' "the gui stage requires wireplumber"
has iso/build.sh 'for p in alsa-utils; do' "the gui stage requires alsa-utils"
has iso/build.sh 'usr/bin/amixer usr/sbin/alsactl usr/bin/speaker-test' \
    "the gui stage asserts the mixer tools where alsa-utils puts them"
has iso/build.sh 'ln -s ../../bin/zsh "$TGT/usr/bin/zsh"' \
    "the gui stage creates /usr/bin/zsh, which only zsh's postinst would"
has iso/rootfs-overlay/usr/bin/copper-audio '/usr/sbin/alsactl' \
    "copper-audio finds alsactl in /usr/sbin"
has iso/build.sh 'chmod 0755 "$TGT/usr/bin/copper-audio"' \
    "the rootfs stage makes copper-audio executable"
hasre iso/build.sh 'usr/bin/zsh usr/bin/pipewire usr/bin/pipewire-pulse' \
    "the gui stage asserts the audio and shell binaries in the tree"
hasre iso/build.sh '^build_unified' "the unified stage exists"
has iso/build.sh 'copper.init=systemd' "the unified stage requires the GRUB systemd entry"
has iso/build.sh 'sbin/init: systemd -> copper-init' \
    "the unified stage takes the default back to copper-init"
has iso/build.sh 'make_merged_usr_bridge "$TGT"' \
    "the unified stage keeps the systemd payload reachable"
hasre iso/build.sh '^  unified\)' "the unified stage is dispatachable"
hasre iso/build.sh 'unified.*all' "default_flavour normalises a cached unified tree"

echo
echo "config: the PPA stages survive a flapping Launchpad"
# Launchpad answers 503 to some requests and 200 to the next. apt-get update
# exits 0 when one source fails, so testing its status is not enough: the
# stage must ask whether the pinned package has a candidate and retry until
# it does, or CI goes red with nothing in the image changed.
hasre iso/build.sh '^apt_update_for\(\)' "there is a shared PPA-ready retry helper"
has iso/build.sh "apt-cache \"\$@\" policy \"\$pkg\"" \
    "the helper checks for a real candidate, not just apt's exit status"
has iso/build.sh 'policy=$(apt-cache "$@" policy "$pkg" 2>/dev/null) || policy=' \
    "the candidate probe captures first, avoiding the SIGPIPE trap"
has iso/build.sh 'Acquire::Retries=5' \
    "each index fetch gets its own retries too"
has iso/build.sh 'download attempt $dltry failed' \
    "a failed .deb fetch is retried, not fatal on the first 503"
for line in \
    'apt_update_for niri' \
    'apt_update_for hyprland'; do
    has iso/build.sh "$line" "$line is used by its stage"
done
hasnt iso/build.sh 'apt-get "\$\{AOPT\[@\]\}" update -qq' \
    "no PPA stage trusts a bare apt-get update"

echo
echo "config: CI builds one image and boots both halves"
has .github/workflows/build-iso.yml 'sudo bash iso/build.sh unified' \
    "the workflow builds the unified tree"
has .github/workflows/build-iso.yml './tests/boot-gate.sh --systemd' \
    "the workflow boots the systemd half of the image"
has .github/workflows/build-iso.yml 'name: copper-iso' \
    "the workflow uploads the image as copper-iso"
if grep -qF 'name: copper-iso-systemd' "$REPO/.github/workflows/build-iso.yml"; then
    bad "the workflow still uploads a second, separately-swapped ISO"
else
    ok "there is no second, separately-swapped ISO"
fi

echo
echo "config: the tests drive the new questions"
has tests/firstboot-drive.py 'Which shell, bash or zsh?' \
    "the wizard driver answers the shell question"
has tests/firstboot-drive.py 'Which audio, pulseaudio or pipewire?' \
    "the wizard driver answers the audio question"
has tests/firstboot-drive.py 'Which init, busybox or systemd?' \
    "the wizard driver answers the init question"
has tests/account.sh 'records shell=zsh' "the account test checks the written shell"
has tests/account.sh 'records audio=pipewire' "the account test checks the written audio"
has tests/shutdown-gate.sh 'COPPER_INIT' "the shutdown gate forces the running init"
has tests/boot-gate.sh 'copper.init=systemd' "the boot gate boots the systemd branch"
# noble's systemd logs "Starting copper-firstboot.service - Copper first-boot
# wizard..." (with colour escapes around the unit name), not "Starting Copper
# ...". The gate has to wait for the names and descriptions the shipped
# .service files actually carry, or a working systemd boot fails on log shape.
has tests/boot-gate.sh 'copper-(firstboot|console)\.service' \
    "the boot gate waits for the shipped systemd unit names"
has iso/systemd/copper-firstboot.service 'Description=Copper first-boot wizard' \
    "the wizard unit carries the description the boot gate waits for"

echo
echo "config: the ISO read-back agrees with the unified power wrapper"
# power_links points every power name at /sbin/shutdown on BOTH flavours and
# the wrapper dispatches at runtime, so the disc checkout must expect the
# wrapper on the busybox half too. It used to expect /bin/busybox there, and
# the first build that got past the gui stage failed on the disc as a result.
hasnt iso/build.sh '[ "$pt" = "/bin/busybox" ]' \
    "the busybox half of the ISO check expects the wrapper, not an applet link"
has iso/build.sh 'exec /bin/busybox "$mode"' \
    "the busybox half checks the wrapper hands over to the busybox applet"

echo
if [ "$fail" -ne 0 ]; then
    echo "config: FAILED"
    exit 1
fi
echo "config: every switch agrees with itself"
