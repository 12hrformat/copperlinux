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
mkdir copper-dir && rmdir copper-dir
rm coppersmoke.txt
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
check "rm"           ""             "$out"

if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "all good"