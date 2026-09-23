# copper-sh

The Copper Linux shell — a tiny POSIX shell written in C.

Right now it's mostly builtins so it can do useful things before a full
coreutils is installed on the system. Everything else (`vi`, `top`, ...)
falls through to `execvp` and runs from `$PATH`.

Status: **v0.1.0-dev** — in development.

## Build & run

On a Linux box (or anywhere with a C compiler):

```sh
make
./copper-sh
```

To install it system-wide:

```sh
make install            # installs to /usr/local/bin/copper-sh
```

## Builtin commands

```
help          show this list
exit / quit   leave the shell (ctrl-d also works)
pwd           print working directory
cd            cd, cd ~, cd -, cd ..
ls            ls [-a] [-l] [path]
cat           cat [file...]
echo          echo [-n] [text...]
head          head [-n N] [file...]
tail          tail [-n N] [file...]
wc            wc [-lwc] [file...]
grep          grep [-inv] PATTERN [file...]
tee           tee [-a] FILE...
sleep         sleep SECONDS
true/false    do nothing, exit 0 / exit 1
clear         clear the screen
whoami        your username
id            uid/gid info
hostname      the machine's hostname
uname         system info
date          date and time
basename      strip dirs/suffix from a path
dirname       the directory part of a path
mkdir         make a directory
rmdir         remove an empty directory
touch         create or update a file
rm            rm [-r] [file...]
cp            cp SRC DST
mv            mv SRC DST
ln            ln [-s] TARGET LINK
chmod         chmod OCTAL FILE
history       this session's commands
type          builtin or external?
which         where on PATH?
env           print the environment
```

Also understands `# comments`, single + double quotes, backslash escapes,
pipes (`|`) and redirects (`<`, `>`, `>>`), and `Ctrl-C` won't kill the
shell (only the current command).

## What's next

- networking (`ping`-ish utilities, sockets) — the whole reason this
  project exists is to get Copper online
- `~/.bashrc`-style init file (`~/.copperrc`)
- history persisted to `~/.copper_history`
- real line editing (arrow keys, tab completion)

## Layout

```
src/main.c       shell loop, prompt, tokenizer, process launching
src/builtins.c   builtin commands + the command table helpers
src/builtins.h   the interface between them
Makefile
tests/smoke.sh   quick sanity battery
```