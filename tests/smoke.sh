#!/bin/sh
# copper-sh smoke test.
# Build first (make), then run:  ./tests/smoke.sh
set -e

SH=${SH:-./copper-sh}
fails=0

check() {
    name="$1"
    want="$2"
    got="$3"
    if printf '%s' "$got" | grep -q -- "$want"; then
        echo "ok   : $name"
    else
        echo "FAIL : $name  (wanted '$want', got: $(printf '%s' "$got" | head -1))"
        fails=$((fails + 1))
    fi
}

out=$($SH <<'EOF'
pwd
cd /tmp
pwd
echo hello copper
echo -n no-newline
echo
touch coppersmoke.txt
ls coppersmoke.txt
whoami
uname -s
date
mkdir copper-dir
rmdir copper-dir
echo redirection works > coppersmoke.txt
cat coppersmoke.txt
wc -w < coppersmoke.txt
head -n 1 coppersmoke.txt
tail -n 1 coppersmoke.txt
grep redirection coppersmoke.txt
echo piped thing | wc -w
echo multi line one > multi.txt
echo multi line two >> multi.txt
wc -l multi.txt
tee multi2.txt < multi.txt
grep line multi.txt
basename /usr/bin/copper
dirname /usr/bin/copper
chmod 600 coppersmoke.txt
rm coppersmoke.txt multi.txt multi2.txt
exit
EOF
)

check "pwd"          "/"            "$out"
check "cd"           "/tmp"         "$out"
check "echo"         "hello copper" "$out"
check "echo -n"      "no-newline"   "$out"
check "touch+ls"     "coppersmoke.txt" "$out"
check "whoami"       "$(id -un 2>/dev/null || echo .)" "$out"
check "uname"        "Linux"        "$out"
check "date"         "20"           "$out"
check "redirect+cat" "redirection works" "$out"
check "wc stdin"     "2"            "$out"
check "head"         "redirection works" "$out"
check "tail"         "redirection works" "$out"
check "grep"         "redirection works" "$out"
check "pipe+wc"      "2"            "$out"
check "append+wcl"   "2"            "$out"
check "tee"          "multi line one" "$out"
check "grep"         "multi line two" "$out"
check "basename"     "copper"       "$out"
check "dirname"      "/usr/bin"     "$out"

# copper-sh reads /etc/copperrc and ~/.copperrc before the first prompt. Point
# HOME at an empty directory so the developer's own rc file cannot change any
# answer above, then give the shell one of ours.
rc_home=${TMPDIR:-/tmp}/copper-smoke.$$
mkdir -p "$rc_home"
trap 'rm -rf "$rc_home"' EXIT
HOME=$rc_home
export HOME

cat > "$rc_home/.copperrc" <<'RC'
# what an installer writes, more or less
export COPPER_SMOKE_RC=loaded
export COPPER_SMOKE_PATH=$HOME/.opencode/bin:$PATH
RC

out=$($SH <<'EOF'
echo "rc=${COPPER_SMOKE_RC}"
echo "brace=${COPPER_SMOKE_RC}"
echo 'single=$COPPER_SMOKE_RC'
echo "literal=\$COPPER_SMOKE_RC"
echo "path=$COPPER_SMOKE_PATH"
env | grep COPPER_SMOKE_RC
EOF
)

check "rc expansion"   "rc=loaded"              "$out"
check "rc braces"      "rc=loaded"              "$out"
check "single quotes"  "single=\$COPPER_SMOKE_RC" "$out"
check "escaped dollar" "literal=\$COPPER_SMOKE_RC" "$out"
check "rc PATH"        "$rc_home/.opencode/bin:" "$out"
check "export to child" "COPPER_SMOKE_RC=loaded" "$out"

# Installers ask which shell to edit; nothing used to answer. Unset SHELL for
# this run so the fallback has to come from the passwd entry.
out=$(env -u SHELL "$SH" <<'EOF'
echo "shell=$SHELL"
EOF
)
check "SHELL fallback" "shell=/" "$out"

if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "all good"