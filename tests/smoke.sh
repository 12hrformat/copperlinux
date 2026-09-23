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

if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "all good"