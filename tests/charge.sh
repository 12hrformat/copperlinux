#!/bin/bash
# Exercise the charge/rollback cycle end to end in a sandbox, including the
# case that started this: a machine where nothing needs patching, so the old
# code made no backups and "rollback" had nothing to restore.
#
# Runs the real scripts, unmodified, by pointing them at a sandbox config. The
# scripts treat a hotfix "file" value as absolute-from-root, so the sandbox
# paths are written that way.
#
# Needs root, because the tools insist on it -- which is itself part of what
# is being checked, so this is not worked around.
#
# Usage: sudo ./tests/charge.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T=/tmp/charge-test

if [ "$(id -u)" -ne 0 ]; then
    echo "charge.sh: must run as root (sudo ./tests/charge.sh)"
    exit 77        # 77 is autoconf's "skipped"; this script is not autoconf,
                   # but the convention is the clearest way to say "not run"
fi

rm -rf "$T"
mkdir -p "$T/etc/copper" "$T/bin" "$T/var/backups/copper" "$T/var/log"

# Named exactly as they are installed, with no .sh: the dispatcher looks for
# copper-charge and copper-rollback beside itself.
cp "$REPO/iso/copper.sh" "$T/bin/copper"
cp "$REPO/iso/copper-charge.sh" "$T/bin/copper-charge"
cp "$REPO/iso/copper-rollback.sh" "$T/bin/copper-rollback"
chmod +x "$T/bin"/*

# The demo hotfix from the repo, retargeted at the sandbox.
cat > "$T/etc/copper/hotfixes.json" <<'JSON'
{
  "hotfixes": [
    {
      "id": "demo-banner",
      "file": "tmp/charge-test/etc/copper/demo.txt",
      "fail_code": "THIS LINE IS BROKEN",
      "new_code": "THIS LINE IS FIXED BY COPPER CHARGE",
      "description": "demo hotfix"
    },
    {
      "id": "not-here",
      "file": "tmp/charge-test/etc/copper/absent.txt",
      "fail_code": "WHATEVER",
      "new_code": "SOMETHING",
      "description": "targets a file that is not installed"
    }
  ]
}
JSON

printf 'line one\nTHIS LINE IS BROKEN\nline three\n' > "$T/etc/copper/demo.txt"

cat > "$T/etc/copper/config" <<EOF
HOTFIX_DB=$T/etc/copper/hotfixes.json
BACKUP_DIR=$T/var/backups/copper
LOG_FILE=$T/var/log/copper-charge.log
# No network on this box; the local database must be enough.
HOTFIX_URL=http://127.0.0.1:1/nothing.json
EOF

export COPPER_CONFIG="$T/etc/copper/config"
CU="$T/bin/copper"

fails=0
step() { printf '\n=== %s\n' "$1"; }
check() {
    if [ "$1" = "$2" ]; then
        printf '  PASS  %s\n' "$3"
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$3" "$2" "$1"
        fails=$((fails + 1))
    fi
}
contains() {
    case "$1" in
        *"$2"*) printf '  PASS  %s\n' "$3" ;;
        *)      printf '  FAIL  %s\n        wanted to contain: %s\n        got: %s\n' "$3" "$2" "$1"
               fails=$((fails + 1)) ;;
    esac
}

demo() { cat "$T/etc/copper/demo.txt"; }
broken() { grep -q "THIS LINE IS BROKEN" "$T/etc/copper/demo.txt" && echo yes || echo no; }
fixed()  { grep -q "THIS LINE IS FIXED"  "$T/etc/copper/demo.txt" && echo yes || echo no; }
snaps()  { ls -1 "$T/var/backups/copper" 2>/dev/null | grep -c '^[0-9]'; }

step "1. the reported case: rollback before any charge has ever run"
out=$("$CU" rollback --latest 2>&1); rc=$?
contains "$out" "nothing to restore" "says plainly that there is nothing to restore"
contains "$out" "copper charge" "and says what to do about it"
check "$rc" 1 "exits non-zero rather than pretending to succeed"

step "2. rollback with no arguments on an empty backup dir"
out=$("$CU" rollback 2>&1); rc=$?
contains "$out" "nothing to roll back" "explains the empty state"
check "$rc" 1 "exits non-zero"

step "3. --status must change nothing and take no backup"
out=$("$CU" charge --status 2>&1); rc=$?
contains "$out" "would apply demo-banner" "reports the pending hotfix"
contains "$out" "no backup was taken" "says it took no backup"
contains "$out" "not-here" "reports the entry whose file is absent"
check "$rc" 0 "exits 0"
check "$(broken)" yes "demo.txt untouched"
check "$(snaps)" 0 "no snapshot created"

step "4. --backup takes a restore point and applies nothing"
out=$("$CU" charge --backup 2>&1); rc=$?
contains "$out" "backed up 1 file(s)" "reports how many files were saved"
contains "$out" "nothing was applied" "says it applied nothing"
check "$rc" 0 "exits 0"
check "$(broken)" yes "demo.txt untouched"
check "$(snaps)" 1 "one snapshot exists"

step "5. --list shows what can be restored"
out=$("$CU" rollback --list 2>&1); rc=$?
contains "$out" "$T/etc/copper/demo.txt" "names the file it holds"
check "$rc" 0 "exits 0"

step "6. a real charge applies and leaves a restore point"
out=$("$CU" charge 2>&1); rc=$?
contains "$out" "applied demo-banner" "reports the apply"
contains "$out" "restore point:" "tells you how to undo it"
contains "$out" "1 hotfix(es) applied" "counts only this run"
contains "$out" "not-here" "mentions the entry it skipped"
check "$rc" 0 "exits 0"
check "$(fixed)" yes "demo.txt is patched"
check "$(snaps)" 2 "a second snapshot exists"

step "7. rollback --latest puts the broken file back"
out=$("$CU" rollback --latest 2>&1); rc=$?
contains "$out" "restored 1 file(s)" "reports what it restored"
contains "$out" "just before this rollback" "says the reversal is itself reversible"
check "$rc" 0 "exits 0"
check "$(broken)" yes "demo.txt is broken again"
check "$(fixed)" no "the fix is gone"

step "8. charge again, and rollback again -- the cycle must repeat"
"$CU" charge >/dev/null 2>&1
check "$(fixed)" yes "second charge applies"
out=$("$CU" rollback --latest 2>&1)
check "$(broken)" yes "second rollback restores"
"$CU" charge >/dev/null 2>&1
check "$(fixed)" yes "third charge applies"

step "9. THE REPORTED CASE: charge when nothing needs patching"
# Nothing needs patching when the fail_code is NOT in the file, so get there by
# charging until it is fixed. Rolling back first would land on the broken
# version, which is the opposite of the state this step is about.
before=$(snaps)
out=$("$CU" charge 2>&1); rc=$?
check "$(fixed)" yes "the file is now in the patched state"
out=$("$CU" charge 2>&1); rc=$?
contains "$out" "already up to date" "says honestly that nothing needed patching"
contains "$out" "does not need it" "names the entry it skipped"
check "$(fixed)" yes "demo.txt untouched"
after=$(snaps)
check "$after" "$((before + 2))" "both runs took a snapshot -- this is the fix"
check "$rc" 0 "exits 0"

step "10. and rollback now has something to work with"
out=$("$CU" rollback --latest 2>&1); rc=$?
contains "$out" "restored 1 file(s)" "restores from the no-op charge's snapshot"
check "$rc" 0 "exits 0"

step "11. --latest must not pick a pre-rollback directory"
"$CU" charge >/dev/null 2>&1
"$CU" rollback --latest >/dev/null 2>&1
"$CU" rollback --latest >/dev/null 2>&1
out=$("$CU" rollback --list 2>&1)
contains "$out" "restore points in" "listing survives two rollbacks"
if echo "$out" | grep -q '^[0-9].*pre-rollback'; then
    printf '  FAIL  a pre-rollback directory is being offered as a restore point\n'
    fails=$((fails + 1))
else
    printf '  PASS  pre-rollback directories are not offered as restore points\n'
fi

step "12. an old single-file backup still restores"
printf 'OLD CONTENT\n' > "$T/var/backups/copper/tmp_charge-test_etc_copper_demo.txt"
printf 'CURRENT\n' > "$T/etc/copper/demo.txt"
out=$("$CU" rollback tmp_charge-test_etc_copper_demo.txt 2>&1); rc=$?
contains "$out" "restored" "restores a loose file"
check "$(cat "$T/etc/copper/demo.txt")" "OLD CONTENT" "the loose backup's contents are back"
check "$rc" 0 "exits 0"
rm -f "$T/var/backups/copper/tmp_charge-test_etc_copper_demo.txt"

step "13. a bad snapshot name is refused, not guessed at"
out=$("$CU" rollback 1999-01-01_00-00-00 2>&1); rc=$?
contains "$out" "no such snapshot" "says what is wrong"
check "$rc" 1 "exits non-zero"

step "14. the dispatcher still refuses a command it does not have"
out=$("$CU" wat 2>&1); rc=$?
contains "$out" "unknown command" "unknown commands are named"
check "$rc" 1 "exits non-zero"

step "15. --dump-entries needs no root and shows every field"
out=$(COPPER_CONFIG=/dev/null HOTFIX_DB="$T/etc/copper/hotfixes.json" \
        HOTFIX_URL="http://127.0.0.1:1/x" BACKUP_DIR="$T/var/backups/copper" \
        LOG_FILE="$T/var/log/x" "$T/bin/copper-charge" --dump-entries 2>/dev/null)
lines=$(printf '%s' "$out" | grep -c . || true)
check "$lines" 2 "both entries are visible, one per line"
contains "$out" "demo-banner" "the first entry is named"
contains "$out" "not-here"    "the second entry is named"

# Keep the sandbox when something failed -- it is the evidence -- and clear it
# when everything passed.
if [ "$fails" -eq 0 ]; then
    rm -rf "$T"
    printf '\n=== ALL CHECKS PASSED (sandbox removed)\n'
else
    printf '\n=== %s CHECK(S) FAILED -- sandbox left at %s\n' "$fails" "$T"
fi
exit $fails
