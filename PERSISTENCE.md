# Persistence — how Copper should save your work

Status: **design + patch plan.** The mechanism works today (boot-verified,
bugs 20/24 closed on a real persistence boot); what this document changes is
*when Copper asks*, so a virtual machine — where there is no data to protect —
behaves like an installed OS instead of a live USB.

Written because the current behaviour is confusing on the one machine most
people test on. "Do you have a spare disk attached?" is a reasonable question on
a laptop and a stupid one in a VM.

---

## 1. The problem in one paragraph

A live ISO is designed to touch nothing: it boots from a read-only image and
puts your writes in RAM, so unplugging it leaves the machine exactly as it was.
That safety costs you your work on reboot. Copper's answer is a disk labelled
`COPPER`: the first-boot wizard writes that label, `/init` mounts the labelled
disk as the overlay's writable layer, and from then on every save lands on the
disk. The steady state is already "installed-OS like" — the wizard says
*"Already on: your files are kept on /dev/sda"* and asks nothing.

The friction is all on the *first* boot, and it has a sharp edge in a VM:

- a **truly empty** disk is already claimed automatically (no question);
- a disk with **any** filesystem — including one Copper itself formatted on a
  previous run — falls through to the "pick a disk and type ERASE" path;
- on a VM the disk almost always has *something* on it (a leftover partition
  table, an old filesystem), so the "installed OS" case degrades into a
  destructive prompt that has no reason to exist there.

So the fix is narrow: **a disk that is empty, or that already carries the
`COPPER` label, is claimed with no prompt.** A disk holding somebody's data
still stops and asks. That single rule gives the VM the behaviour people expect
without ever being more dangerous than it is now.

---

## 2. How persistence actually works (the mechanism, unchanged)

This part is not being changed. It is written down because the rest of the
document is only meaningful against it.

### 2.1 The label is the contract

`iso/live/init` runs first, before any init system, and decides the writable
layer. Its rule is one line of shell:

```sh
find_upper() {
    for dev in /dev/sd* /dev/vd* /dev/nvme*n* /dev/mmcblk*; do
        info=$(/bin/busybox blkid "$dev") || continue
        case "$info" in
            *'LABEL="COPPER"'*) UPPER_DEV="$dev"; return 0 ;;
        esac
    done
    ...
}
```

- **A disk carrying `LABEL="COPPER"` → mounted read-write at `/mnt/upper`**, and
  `upper/` + `work/` are created inside it for the overlay.
- **No such disk → a `tmpfs` at `/mnt/upper`**, and the session lives in RAM.

Then `/init` mounts the overlay
(`lowerdir=/mnt/root,upperdir=/mnt/upper/upper,workdir=/mnt/upper/work`) and
writes the live-boot marker:

```
/var/lib/copper/live-boot
    media=/dev/sr0
    upper=/dev/sda          # or "ram" when nothing was found
```

`upper=` is the authority on what is carrying the session. It is written
**after** the mount succeeded, so it cannot miss a layer the way reading
`/proc/mounts` can — that distinction is bug 35.

### 2.2 The wizard is a separate program

`iso/firstboot/copper-firstboot.c` is the first-boot wizard (also the console
dialogue). Its job with respect to persistence is only ever to **write the
label**, then carry the user's earlier answers onto the new disk and reboot so
the next boot comes up on it.

Relevant pieces, all in that one file:

| function | what it does |
| --- | --- |
| `read_boot_marker()` | reads `/var/lib/copper/live-boot`; sets `boot_upper_disk` to a **bare disk name** (`/dev/` stripped, `ram` → empty) |
| `list_spare_disks()` | the candidate disks: `is_disk_name`, not the boot medium, not `is_upper_disk`, not `disk_in_use` |
| `disk_has_fs()` | `blkid` on the whole disk; true if it prints `TYPE=` or `UUID=` |
| `format_persistence_disk()` | `mkfs.ext4 -q -F -L COPPER`, then `sync` |
| `offer_persistence()` | the page: what to claim, what to ask, what to say |

### 2.3 Why the question exists at all

Because `mkfs.ext4` is destructive and the wizard can be run on a machine that
already has an OS. The whole design is "never format a disk nobody said was
yours." Everything below preserves that; it only stops asking in the cases where
the answer is already known.

---

## 3. The rule (what this change makes true)

`offer_persistence()`, in order:

| situation | today | after |
| --- | --- | --- |
| `upper=` names a real disk | say "Already on", return | **same** |
| no candidate disks | "nothing is saved", return | **same** |
| **exactly one disk, no filesystem** | auto-format, countdown, no ERASE | **same** |
| **exactly one disk, `LABEL="COPPER"`** | *fall through to the ERASE prompt* | **claim it, no prompt** |
| exactly one disk, foreign filesystem | ERASE prompt | **same** |
| two or more candidates | list + ERASE | **same** |

The one changed row is the whole feature. A VM you have booted Copper on once
has a `COPPER` disk; every boot after that, and every *re-run* of the ISO
against that VM, is quiet. A laptop whose spare disk holds someone's files still
stops and demands `ERASE`.

### 3.1 What "already COPPER" means for the overlay

If the disk already carries the label, it is *already* a valid overlay upper
(`/mnt/upper/upper`, `/mnt/upper/work` are created by `/init`, not by mkfs), so
there is nothing to format. The wizard should:

1. not run `mkfs.ext4` at all (keep whatever is on it — it is Copper's own
   filesystem and may already hold the user's previous session);
2. still call `carry_firstboot_answers()` (the marker is rewritten on the next
   boot anyway, but carrying answers keeps a re-run from re-asking);
3. still `reboot_into_persistence()` so the session comes up on the disk.

This is the case that makes re-running the ISO on the same VM "just work."

---

## 4. The code

### 4.1 A new helper: `disk_is_copper()`

Next to `disk_has_fs()`, same shell-out shape (so a test bench can stub `blkid`
in front of it):

```c
/* Does this disk already carry the COPPER label -- i.e. is it a disk Copper
   formatted on a previous boot? /init's find_upper() mounts exactly this label
   as the writable layer, so a disk that answers yes is already a valid
   persistence disk and needs no mkfs. Searched the same way blkid is in
   disk_has_fs(), and matched on the same output, for the same reason: the
   wizard's PATH is whatever copper-init handed down. */
static int disk_is_copper(const char *disk) {
    char dev[PERSIST_NAME + 8];
    snprintf(dev, sizeof dev, "/dev/%s", disk);
    char out[256];
    run_capture(out, sizeof out,
                "if command -v blkid >/dev/null 2>&1; then blkid %s; "
                "elif [ -x /sbin/blkid ]; then /sbin/blkid %s; "
                "elif [ -x /usr/sbin/blkid ]; then /usr/sbin/blkid %s; "
                "elif [ -x /bin/busybox ]; then /bin/busybox blkid %s; "
                "fi", dev, dev, dev, dev);
    return strstr(out, "LABEL=\"COPPER\"") != NULL;
}
```

### 4.2 The branch in `offer_persistence()`

Replace the single-disk arm:

```c
    /* One disk is an ordinary first boot, and there are two ways it can be
       already safe to take without a question:

         - it is empty (nothing on it to lose), or
         - it carries the COPPER label, i.e. Copper formatted it on an earlier
           boot and is being run again.

       The second case is why this branch changed: on a VM, re-running the ISO
       against a disk it had already claimed used to fall through to the ERASE
       prompt, even though the only thing on the disk was the previous Copper
       session. Already-COPPER is not offered for erasure, it is reused.

       Anything else -- two candidates, or one disk holding foreign data -- is
       still a choice only the person in front of the machine can make. */
    if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {
        char sz[32];
        disk_size_str(disks[0], sz, sizeof sz);
        int already = disk_is_copper(disks[0]);

        if (already) {
            /* Nothing to format: the disk is already a persistence disk. */
            printf("  Already on: your files are kept on /dev/%s and are still\n",
                   disks[0]);
            printf("  here after a reboot. Nothing to set up.\n");
        } else {
            int secs = persist_seconds();
            printf("  Copper is running live, so nothing is saved when you reboot. One\n");
            printf("  empty disk is attached, so Copper formats it and keeps your files\n");
            printf("  on it from now on.\n");
            printf("\n");
            printf("      %-12s %s\n", disks[0], sz);
            printf("\n");
            printf("  Formatting /dev/%s in %d seconds — press Enter to skip.\n",
                   disks[0], secs);
            fflush(stdout);
            if (wait_key(secs)) {
                char skip[8];
                read_line(skip, sizeof skip);
                printf("\nSkipped — this session stays in RAM.\n");
                return 1;
            }
            printf("\n");
            if (format_persistence_disk(disks[0]) != 0) return 1;
            printf("\nDone. /dev/%s is labeled COPPER.\n", disks[0]);
        }

        carry_firstboot_answers(disks[0]);
        reboot_into_persistence();
        return 1;
    }
```

Note the shape: the **empty** path keeps its countdown and its "press Enter to
skip" escape (that is the safety on a first boot); the **already-COPPER** path
has neither, because there is nothing destructive happening and no decision to
make. Both still record answers and reboot.

### 4.3 What is deliberately NOT changed

- `format_persistence_disk()` — same `mkfs.ext4 -F -L COPPER`, same `sync`.
- The foreign-filesystem path and its `ERASE` confirmation.
- `list_spare_disks()`'s refusals (`is_boot_medium`, `is_upper_disk`,
  `disk_in_use`).
- `/init` and `find_upper()` — the label contract is untouched, which is why
  this is safe: the mount side already understood `LABEL="COPPER"` before this
  patch existed.

---

## 5. Tests

`tests/persist.sh` is the gate, run by `tests/branch-gate.sh` and by CI. It
runs the wizard against a fake `/sys/block` and `/etc` in a mount namespace,
with stub `blkid`/`mkfs.ext4` first on `PATH`, so it asserts **decisions**, not
devices.

New cases for this change:

1. **one disk, `blkid` says `LABEL="COPPER"`** → the page says "Already on",
   **no `mkfs.ext4` call is recorded**, no list, no `ERASE`, and the wizard
   still reboots (with `COPPER_PERSIST_NO_REBOOT` set, "reboots" is observed as
   the reboot path being taken).
2. **one disk, `blkid` prints nothing** → unchanged: the empty path, with its
   countdown, formats and labels `COPPER` (existing case — must stay green).
3. **sabotage**: label check removed → case 1 goes red, proving the new
   assertion is load-bearing. `tests/systemd-gate-sabotage.sh` is the model for
   how to structure this; a small equivalent here, or an added case in an
   existing sabotage harness, is enough.
4. **foreign filesystem** (blkid prints `TYPE="ntfs"`, no label) → still the
   `ERASE` prompt and nothing formatted without it (existing case — must stay
   green).

The stub `blkid` needs a mode where it answers per-disk, since case 1 and case
4 differ only in the label. That is a change to the test bench, not the product.

---

## 6. What this does not fix (honest list)

- **A disk with a leftover foreign partition table is still offered for ERASE.**
  That is correct on hardware and mildly annoying in a VM whose disk was
  partitioned by something else. It is not being relaxed because it cannot be
  told apart from a laptop's data disk — and guessing wrong there is the one
  mistake that costs somebody their files.
- **The wizard still cannot be skipped entirely.** Turning Copper into an
  installer (partition, install, no wizard) is a different project and a
  different product decision, not a patch to this file.
- **Nothing here is boot-verified yet.** The mechanism underneath it is
  (bugs 20/24), and the wizard's decision table is covered by `tests/persist.sh`
  — but the *new* branch has not been through a real boot. Same honesty as
  SYSTEMD-MIGRATION.md: the gate says the pieces are coherent, the boot is what
  closes it.

---

## 7. Where this sits with the other in-flight work

- **Independent of the systemd migration** (`SYSTEMD-MIGRATION.md`). Persistence
  lives in `/init` and the firstboot wizard, both of which run the same way
  under either init. The systemd image inherits this unchanged.
- **Complements bug 35 and `a8ebdfa`** (farcrowx): those made the wizard stop
  lying about an already-persistent boot. This makes it stop *asking* on a disk
  it already owns.
- **Cyber-hygiene note:** the rule "empty or COPPER-labelled" is deliberately
  the narrowest one that removes the VM friction. Widening it to "any single
  non-boot disk" would be one line and would be wrong — see §6.

---

handcrafted by 12hrformat (persistence: claim a disk we already own, without
asking)

<!--
Updated-files convention: a file that already exists and is being fixed gets
"updated by <name>, <the bug>, <the line where the bug was>". This document is
new, so it takes the handcrafted line above.
-->
