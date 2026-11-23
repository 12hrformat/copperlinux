# Bootloader providers

The ISO build does not know how to write a GRUB menu or how to turn a staged
rootfs into boot media. It knows only these two hooks, which a provider exports
from `provider.sh`:

| hook | job |
| --- | --- |
| `bootloader_configure <staged-root>` | write the provider's menu into the staged tree, before that tree is hashed |
| `bootloader_make_iso <staged-root> <iso> <work-dir>` | produce the bootable image |

The provider is selected with `COPPER_BOOTLOADER=<name>` and defaults to
`grub`. Its files must live at `iso/bootloaders/<name>/`. A provider is sourced
by `iso/build.sh`, so it can use build.sh's variables (`$ROOT`, `$WORK`,
`$TGT`, `$OUT`) but must not rely on any other stage's internals.

Every provider renders the same input, `iso/boot/entries`: one non-comment
line per boot entry, `id|menu title|kernel command line`. That file is the only
place where kernel arguments live. Adding an init, a debug mode or a session
entry means editing `entries`, not a provider.

The GRUB provider (`iso/bootloaders/grub/`) writes `boot/grub/grub.cfg` and
packages with `grub-mkrescue`, BIOS and UEFI in one image. A replacement can be
EFI-only, use a different menu format, or package with a different tool: the
read-back gates in `build_iso()` inspect the resulting ISO, not how it was made.
