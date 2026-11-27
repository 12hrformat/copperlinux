#!/bin/sh
# config-gate.sh -- the image-wide choices are real switches, not prose.
# One ISO ships both inits, shells and audio servers. What picks one is a string
# agreed on by two files that are never compiled together.
# A rename on one side is silent: the image boots but ignores the user's answer,
# so this gate reads both ends of every switch. Rootless and buildless.
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
echo "config: the shared boot list is the init switch"
has iso/boot/entries 'Copper Linux (systemd init)' \
    "the boot list offers a systemd-init entry"
hasre iso/boot/entries 'copper\.init=systemd' \
    "the systemd entry passes copper.init=systemd"
# The default entry must name no init: that leaves /etc/copper-init in charge.
# Read by id, not line number; providers may add header lines.
if grep '^default|' "$REPO/iso/boot/entries" | grep -qE 'copper\.init='; then
    bad "the default boot entry names an init (it must leave the choice to /etc/copper-init)"
else
    ok "the default boot entry names no init"
fi

echo
echo "config: bootloader is a provider, not a hardcoded menu"
has iso/build.sh 'BOOTLOADER=${COPPER_BOOTLOADER:-grub}' \
    "the build selects its bootloader provider with an override"
has iso/build.sh 'bootloader_configure "$TGT"' \
    "the provider renders the menu into the staged tree"
has iso/build.sh 'bootloader_make_iso "$TGT" "$OUT/copper.iso" "$WORK"' \
    "the provider packages the boot media"
has iso/live/init '/boot/copper-media' \
    "the live init finds its medium without naming a bootloader"
has iso/bootloaders/grub/provider.sh 'bootloader_check()' \
    "the GRUB provider reads its own menu back off the disc"

echo
echo "config: /init agrees with GRUB"
has iso/live/init 'copper.init=systemd' "/init reads copper.init=systemd"
has iso/live/init 'copper.init=busybox' "/init reads copper.init=busybox"
has iso/live/init '/etc/copper-init' "/init falls back to the wizard's saved init"
has iso/live/init '/lib/systemd/systemd' "/init execs systemd at the merged-usr path"
has iso/live/init 'switch_root /mnt/merged /sbin/init' "/init execs /sbin/init for the default"
# The initramfs has no cat/grep/sed: a bare external command fails under
# 2>/dev/null, making the cmdline look empty. Use the read builtin.
has iso/live/init 'read -r cmdline < /proc/cmdline' \
    "the initramfs reads the command line with the read builtin"
has iso/live/init 'for arg in $cmdline; do' \
    "the init choice parses the command line already read"
hasnt iso/live/init 'cat /proc/cmdline' \
    "the initramfs does not call cat, which is not in it"

echo
echo "config: the wizard asks about the person, not the plumbing"
# First-boot users cannot choose plumbing before seeing the machine; defaults are still written.
for q in 'Which desktop, xfce, niri or hyprland?' 'Desktop [xfce]:' \
         'Which shell, bash or zsh?' 'Shell [bash]:' \
         'Which audio, pulseaudio or pipewire?' 'Audio [pulseaudio]:' \
         'Which init, busybox or systemd?' 'Init [busybox]:'; do
    hasnt iso/firstboot/copper-firstboot.c "$q" \
        "the wizard no longer asks: $q"
done
has iso/firstboot/copper-firstboot.c 'const char *shell_word = "bash";' \
    "the default shell is bash"
has iso/firstboot/copper-firstboot.c 'const char *audio_word = "pulseaudio";' \
    "the default audio server is PulseAudio"
has iso/firstboot/copper-firstboot.c 'const char *init_word = "busybox";' \
    "the default init is copper-init"
has iso/firstboot/copper-firstboot.c 'fprintf(d, "xfce\n");' \
    "the default desktop marker is xfce"
has iso/firstboot/copper-firstboot.c 'fprintf(c, "shell=%s\n", shell_word)' \
    "the wizard still writes shell= to /etc/copper.conf"
has iso/firstboot/copper-firstboot.c 'fprintf(c, "audio=%s\n", audio_word)' \
    "the wizard still writes audio= to /etc/copper.conf"
has iso/firstboot/copper-firstboot.c 'fprintf(i, "%s\n", init_word)' \
    "the wizard still writes /etc/copper-init"
has iso/firstboot/copper-firstboot.c '-s %s %s' \
    "adduser gets the default login shell"
has iso/firstboot/copper-firstboot.c 'create_user_direct(user, shell_path)' \
    "the direct passwd writer gets the default login shell"
has iso/firstboot/copper-firstboot.c 'cp -a /etc/skel/.zshrc' \
    "the new home still gets .zshrc for later"
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
echo "config: the server's own sink is unmuted, not just the ALSA card"
# cava reads the default sink's monitor: a muted or null sink means bars move
# with no sound, so copper-audio must talk to the server, not just the codec.
has iso/rootfs-overlay/usr/bin/copper-audio 'server_unmute' \
    "copper-audio has a server-side unmute step"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl get-default-sink' \
    "it reads the server's default sink"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-default-sink' \
    "it repoints the default when it landed on the null output"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-sink-mute' \
    "it unmutes the sink the clients actually use"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-sink-volume' \
    "it raises the sink volume, not just the codec's"
has iso/rootfs-overlay/usr/bin/copper-audio 'pulse_ready' \
    "it waits for the Pulse socket before talking to the server"
has iso/build.sh 'for p in pulseaudio-utils; do' \
    "the gui stage requires pactl, so the unmute can run"
has iso/build.sh 'usr/bin/pactl' \
    "the gui stage asserts pactl landed in the tree"

echo
echo "config: the pulse graph finds hardware without udev"
# No udev daemon runs by default, so the stock detector hands every client the
# null sink; module-detect reads /proc/asound/devices and creates a real sink/source.
has iso/rootfs-overlay/etc/pulse/default.pa 'load-module module-detect' \
    "Copper's pulse config uses the detector that works with no udev"
hasnt iso/rootfs-overlay/etc/pulse/default.pa 'load-module module-udev-detect' \
    "the stock udev-only detector is not used"
has iso/build.sh 'etc/pulse/default.pa' \
    "the gui stage restores Copper's pulse config after the package lands"
has iso/build.sh 'for p in pavucontrol; do' \
    "the gui stage requires pavucontrol"
has iso/build.sh 'usr/bin/pavucontrol' \
    "the mixer shortcut's program is asserted in the image"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-default-source' \
    "it repoints the default source off a monitor/null device"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-source-mute' \
    "it unmutes the microphone"
has iso/rootfs-overlay/usr/bin/copper-audio 'pactl set-source-volume' \
    "it raises the microphone level"

echo
echo "config: VMware keeps its 3D renderer"
# niri refuses software EGL renderers. Forcing llvmpipe on a VMware machine that
# already has a render node leaves a live Wayland socket with nothing drawn.
has iso/startniri.sh 'niri ignores llvmpipe' \
    "the launcher says why the VMware render node is kept"
hasnt iso/startniri.sh 'if [ "$vmware" = 1 ] ||' \
    "VMware detection no longer switches on software rendering"

echo
echo "config: AppImages can mount themselves"
# AppImage runtimes need /dev/fuse and libfuse.so.2 plus a setuid helper;
# without either side the error is "Fuse not installed".
has iso/build.sh 'FUSE_FS' "the kernel config enables FUSE_FS"
has iso/live/init 'mknod /dev/fuse c 10 229' \
    "the live init makes /dev/fuse even if devtmpfs came up late"
has iso/build.sh 'for p in libfuse2t64 libfuse2; do' \
    "the gui stage probes both names of libfuse.so.2"
has iso/build.sh 'for p in fuse; do' \
    "the gui stage requires fusermount from the fuse package"
has iso/build.sh 'chmod 4755 "$TGT/bin/fusermount"' \
    "fusermount is setuid so a non-root user can mount an AppImage"
has iso/build.sh 'bin/fusermount' \
    "the gui stage asserts fusermount landed in the tree"
has iso/build.sh 'ln -s ../../bin/fusermount' \
    "the /usr/bin spelling reaches the same helper"
has iso/build.sh 'ln -s ../usr/bin/bash "$TGT/bin/bash"' \
    "the gui stage links /bin/bash for AppRun shebangs"
has iso/build.sh 'usr/bin/bash bin/bash' \
    "the gui stage asserts the /bin/bash link landed"

echo
echo "config: GTK's fallback names themes that exist"
has iso/rootfs-overlay/etc/gtk-3.0/settings.ini 'gtk-theme-name = ' \
    "the overlay supplies a GTK theme fallback"
has iso/rootfs-overlay/etc/gtk-3.0/settings.ini 'gtk-icon-theme-name = ' \
    "the overlay supplies an icon theme fallback"
has iso/rootfs-overlay/etc/gtk-3.0/settings.ini 'gtk-cursor-theme-name = ' \
    "the overlay supplies a cursor theme fallback"
hasnt iso/rootfs-overlay/etc/gtk-3.0/settings.ini 'Yaru' \
    "the fallback does not name a theme Copper does not ship"
has iso/build.sh 'usr/share/$kind/$name' \
    "the build checks each GTK fallback name against the staged tree"
has iso/build.sh '-extract /etc/gtk-3.0/settings.ini' \
    "the build reads the GTK fallback back off the disc"

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
# Launchpad answers 503 intermittently and apt-get update can still exit 0,
# so retry until the pinned package has a real candidate or CI goes red.
hasre iso/build.sh '^apt_update_for\(\)' "there is a shared PPA-ready retry helper"
has iso/build.sh "apt-cache \"\$@\" policy \"\$pkg\"" \
    "the helper checks for a real candidate, not just apt's exit status"
has iso/build.sh 'policy=$(apt-cache "$@" policy "$pkg" 2>/dev/null) || policy=' \
    "the candidate probe captures first, avoiding the SIGPIPE trap"
has iso/build.sh 'Acquire::Retries=5' \
    "each index fetch gets its own retries too"
has iso/build.sh 'download attempt $dltry failed' \
    "a failed .deb fetch is retried, not fatal on the first 503"
has iso/build.sh 'apt_update_for niri' \
    "apt_update_for niri is used by its stage"
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
echo "config: the test driver stops where the wizard does"
for q in 'Which desktop, xfce, niri or hyprland?' \
         'Which shell, bash or zsh?' \
         'Which audio, pulseaudio or pipewire?' \
         'Which init, busybox or systemd?'; do
    hasnt tests/firstboot-drive.py "$q" \
        "the driver does not wait for: $q"
done
has tests/firstboot-drive.py 'Timezone, e.g. Europe/London' \
    "the driver ends at the last question the wizard asks"
has tests/account.sh 'records shell=bash' "the account test checks the default shell"
has tests/account.sh 'records audio=pulseaudio' "the account test checks the default audio"
has tests/account.sh 'records xfce (the default)' "the account test checks the default desktop"
has tests/shutdown-gate.sh 'COPPER_INIT' "the shutdown gate forces the running init"
has tests/boot-gate.sh 'copper.init=systemd' "the boot gate boots the systemd branch"
# noble prints "Starting <unit> - <Description>..." with colour escapes, not
# "Starting Copper ..."; wait for the shipped unit names/descriptions.
has tests/boot-gate.sh 'copper-(firstboot|console)\.service' \
    "the boot gate waits for the shipped systemd unit names"
has iso/systemd/copper-firstboot.service 'Description=Copper first-boot wizard' \
    "the wizard unit carries the description the boot gate waits for"

echo
echo "config: the ISO read-back agrees with the unified power wrapper"
# power_links points every power name at the wrapper on both flavours, so the
# disc check must expect the wrapper, not an applet link, on busybox too.
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
