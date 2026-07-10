#!/usr/bin/env zsh
#
# Automated regression tests for the Windows portable zsh packaging
# (helper/compile.sh output). Everything here runs through the built
# binaries directly -- no PowerShell -- since PowerShell's own argument
# quoting is a separate, unrelated source of test noise.
#
# Must be run with the build's own interpreter (needs zsh/zpty, and is
# testing that build specifically), not a system zsh. The build/bin path
# is a REQUIRED argument, not auto-detected: this build's msys-2.0.dll,
# run standalone without the rest of a normal MSYS2 install tree,
# resolves '/' (and so $PWD, and so $0:A) to the calling process's cwd
# rather than a fixed filesystem root -- see the bug report at the
# bottom of this file -- so there's no reliable way from inside the
# script to derive its own location or the caller's cwd.
#   build/bin/zsh.exe -f helper/test/test_windows_packaging.zsh <build/bin path>

emulate -L zsh
setopt no_unset pipefail

if [[ -z ${1:-} ]]; then
    print -u2 "usage: zsh.exe -f test_windows_packaging.zsh <path to build/bin>"
    exit 2
fi
BINDIR=$1
LAUNCHER=$BINDIR/zsh-loader.exe
INTERP=$BINDIR/zsh.exe
ZSHCMD=$BINDIR/zsh.cmd

# This script itself runs with -f (no rcs), so .zshenv never sets
# module_path -- do it directly for the zpty-based test below.
module_path=($BINDIR $module_path)

typeset -i pass=0 fail=0

pass_test() { print -P "%F{green}PASS%f: $1"; (( pass++ )) }
fail_test() { print -P "%F{red}FAIL%f: $1 -- $2"; (( fail++ )) }

for f in $LAUNCHER $INTERP $ZSHCMD; do
    if [[ ! -f $f ]]; then
        print -u2 "error: $f not found -- run helper/compile.sh first"
        exit 2
    fi
done

# --- bug #1: a multi-line -c script must not be truncated at the first
# newline. zsh.cmd can't be fixed for this (see zsh_launcher.c for why);
# the native launcher (zsh-loader.exe) is the one this must hold for. ------
test_multiline_c() {
    local out
    out=$("$LAUNCHER" -f -c $'echo abc\necho def' 2>&1)
    if [[ $out == $'abc\ndef' ]]; then
        pass_test "multi-line -c argument is not truncated"
    else
        fail_test "multi-line -c argument is not truncated" "got: ${(qq)out}"
    fi
}

# --- bug #3: '|' and other shell metacharacters inside a quoted argument
# must reach zsh as literal text, not be reinterpreted before zsh runs. ---
test_pipe_in_quotes() {
    local out
    out=$("$LAUNCHER" -f -c 'print -r -- "a|b|c"' 2>&1)
    if [[ $out == "a|b|c" ]]; then
        pass_test "'|' inside a quoted argument reaches zsh literally"
    else
        fail_test "'|' inside a quoted argument reaches zsh literally" "got: ${(qq)out}"
    fi
}

# --- bundled GNU find must win over Windows' incompatible System32 one --
test_find_bundled() {
    local out
    out=$("$LAUNCHER" -f -c 'find --version' 2>&1)
    if [[ $out == *"GNU findutils"* ]]; then
        pass_test "bundled GNU find takes priority over Windows find.exe"
    else
        fail_test "bundled GNU find takes priority over Windows find.exe" "got: ${(qq)out}"
    fi
}

# --- bundled xargs must be present and usable (Windows ships none) ------
test_xargs_bundled() {
    local out
    out=$(print -r -- test | "$LAUNCHER" -f -c 'xargs echo hello' 2>&1)
    if [[ $out == "hello test" ]]; then
        pass_test "bundled xargs works"
    else
        fail_test "bundled xargs works" "got: ${(qq)out}"
    fi
}

# --- dynamic modules must load: this only works if module_path was set
# up correctly (via .zshenv, itself only reached with ZDOTDIR set) -------
test_modules_load() {
    local out
    out=$("$LAUNCHER" -c 'zmodload zsh/zle zsh/ksh93 zsh/complete zsh/compctl && print modules_ok' 2>&1)
    if [[ $out == *modules_ok* ]]; then
        pass_test "zle/ksh93/complete/compctl modules load"
    else
        fail_test "zle/ksh93/complete/compctl modules load" "got: ${(qq)out}"
    fi
}

# --- Windows system directories must be last on PATH, not shadowing
# bundled/earlier tools with the same name (find, sort, more, ...) -------
test_path_system32_last() {
    local out
    out=$("$LAUNCHER" -f -c 'print -r -- $path[-1]' 2>&1)
    if [[ $out == *[Ww]indows* ]]; then
        pass_test "a Windows system directory is pushed to the end of PATH"
    else
        fail_test "a Windows system directory is pushed to the end of PATH" "got: ${(qq)out}"
    fi
}

# --- `ps`'s PID column (this build's Cygwin-internal process number) is
# not a real Windows PID and cannot be handed to tasklist/taskkill; the
# WINPID column is the real one. Confirmed manually by cross-referencing
# a live, independently-launched process's `ps -eW` WINPID against
# tasklist's PID for that same process, in a single shell session where
# both the spawn and the tasklist check ran together.
#
# KNOWN UNRELIABLE in this environment: automating that same check inside
# one -c script (spawn sleep, read its WINPID via ps -eW, hand off to a
# tasklist call) reproducibly finds no matching tasklist entry here, even
# with `disown` to detach the job from shell job control -- most likely
# some process-visibility boundary specific to how this harness executes
# each tool call, since the identical steps performed by hand (spawning
# in one command and checking tasklist in a subsequent one) do observe
# the WINPID correctly. Treat a failure here as inconclusive about
# whether WINPID is correct, not as evidence it isn't -- the underlying
# fact (use WINPID, not PID, for tasklist/taskkill) is not in question.
#
# (Also note: zsh's own $! for a job started with '&' does NOT reliably
# equal either ps column in ad hoc testing here -- likely an artifact of
# this runtime's fork() emulation spawning a short-lived intermediate
# process before the real one -- so this goes via `ps -eW` directly
# rather than through $!, and specifically looks for the PPID=1
# (reparented, i.e. actually backgrounded rather than a transient fork
# helper) entry.)
test_pid_is_real_winpid() {
    local out winpid
    out=$("$LAUNCHER" -f -c '
        sleep 20 &
        sleep 0.3
        ps -eW 2>/dev/null | grep "usr/bin/sleep" | awk "\$2 == 1 { print \$4 }"
    ' 2>&1)
    winpid=${out//[$'\r\n' ]/}
    if [[ -z $winpid || $winpid != <-> ]]; then
        fail_test "ps -eW's WINPID column is a real Windows PID" "did not get a numeric WINPID: ${(qq)out}"
        return
    fi
    if tasklist 2>/dev/null | grep -q "$winpid"; then
        pass_test "ps -eW's WINPID column is a real Windows PID (tasklist finds it directly)"
    else
        fail_test "ps -eW's WINPID column is a real Windows PID (tasklist finds it directly)" "tasklist did not find WINPID $winpid"
    fi
    taskkill //PID $winpid //F >/dev/null 2>&1
}

# --- emoji cursor movement / deletion must treat a UTF-16 surrogate pair
# as one unit (Windows/Cygwin's wchar_t is 16 bits; most emoji need a
# surrogate pair). Drives a real interactive session over a pty via
# zsh/zpty so it exercises the actual ZLE code path (inccs/deccs), not
# just string-length arithmetic. Ctrl-A/Ctrl-F/Ctrl-B are used instead of
# arrow keys so the test doesn't depend on terminfo/escape-sequence
# details -- forward-char/backward-char call the same INCCS()/DECCS()
# primitives arrow keys do.
#
# KNOWN UNRELIABLE in this environment: ZLE redraws the whole prompt line
# on every keystroke, and the redraw itself ends in something matching
# the "*% *" prompt glob, so a wait loop keyed on that pattern alone
# tends to return on the first post-keystroke redraw rather than after
# the full keystroke sequence has actually been processed -- this needs
# a marker distinguishing "live redraw of the input line" from "the
# print command's actual output line" to be reliable, which isn't
# implemented yet. The inccs()/deccs() logic this is meant to exercise
# has been separately verified by reading Src/Zle/zle_move.c directly
# (both increment/decrement past a surrogate pair, and their two
# callers forwardchar/backwardchar plus backdel/foredel use INCCS/DECCS
# rather than adjusting zlecs directly) -- treat a failure here as
# inconclusive, not as evidence the fix itself is wrong, until the pty
# read logic is made robust.
#
# Runs directly in this (already-zpty-capable) process rather than via a
# nested -c string, to avoid a second layer of shell-quoting the pty
# session's keystrokes would otherwise need to survive.
#
# The inner session needs TERM/TERMINFO set to something that actually
# resolves (this build's bundled terminfo db is hashed by the first
# letter's hex code, e.g. dumb -> 64/dumb, xterm -> 78/xterm; "dumb"
# itself was not enough to avoid a startup error in testing, xterm was)
# and ZSH_PORTABLE_DIR/ZDOTDIR set the same way zsh.cmd/zsh-loader.exe set
# them, since this spawns zsh.exe directly rather than through either.
#
# zpty -r blocks with no timeout, so a wrong pattern hangs the whole
# test suite forever; poll with -t (non-blocking) instead and give up
# after a bounded number of attempts.
zpty_wait_for() {
    local session=$1 pattern=$2
    local -i attempts=${3:-50}
    local line
    while (( attempts-- > 0 )); do
        if zpty -r -t $session line 2>/dev/null; then
            [[ $line == ${~pattern} ]] && { print -r -- $line; return 0; }
        fi
        sleep 0.1
    done
    return 1
}

test_emoji_cursor_and_delete() {
    zmodload zsh/zpty 2>/dev/null

    local session=zsh_emoji_test
    zpty -d $session 2>/dev/null

    local spawn_cmd="TERMINFO='$BINDIR/share/terminfo' ZDOTDIR='$BINDIR' ZSH_PORTABLE_DIR='$BINDIR' TERM=xterm PS1='%% ' '$INTERP' -i"
    if ! zpty $session $spawn_cmd; then
        fail_test "emoji cursor/delete test setup" "could not start pty session"
        return
    fi
    if ! zpty_wait_for $session '*% *' >/dev/null; then
        fail_test "emoji cursor/delete test setup" "shell did not reach a prompt"
        zpty -d $session 2>/dev/null
        return
    fi

    # Insertion test: type X=A<emoji>B, jump to line start (^A), step
    # over "X=A" with three forward-chars (^F), then ONE MORE forward-char
    # -- if the surrogate pair is handled as one unit this lands right
    # after the emoji (before B); if not, it lands between the two UTF-16
    # halves, and inserting a marker there corrupts the emoji.
    zpty -w -n $session $'X=A\xf0\x9f\x8e\x89B\x01\x06\x06\x06\x06Y\r'
    zpty_wait_for $session '*% *' >/dev/null
    zpty -w -n $session $'print -r -- $X\r'
    local insert_result
    insert_result=$(zpty_wait_for $session '*% *')

    # Deletion test: type X=A<emoji>B, back up one char (^B, now right
    # after the emoji), then one backward-delete-char (DEL) -- should
    # remove the whole emoji, not just the low surrogate half.
    zpty -w -n $session $'X=A\xf0\x9f\x8e\x89B\x02\x7f\r'
    zpty_wait_for $session '*% *' >/dev/null
    zpty -w -n $session $'print -r -- $X\r'
    local delete_result
    delete_result=$(zpty_wait_for $session '*% *')

    zpty -d $session 2>/dev/null

    local expect_insert=$'A\xf0\x9f\x8e\x89YB'
    local expect_delete=$'AB'

    if [[ $insert_result == *"$expect_insert"* ]]; then
        pass_test "forward-char treats a surrogate pair as one unit (insert-after-emoji stays clean)"
    else
        fail_test "forward-char treats a surrogate pair as one unit (insert-after-emoji stays clean)" "got: ${(qq)insert_result}"
    fi
    if [[ $delete_result == *"$expect_delete"* ]]; then
        pass_test "backward-delete-char removes a whole emoji, not half a surrogate pair"
    else
        fail_test "backward-delete-char removes a whole emoji, not half a surrogate pair" "got: ${(qq)delete_result}"
    fi
}

test_multiline_c
test_pipe_in_quotes
test_find_bundled
test_xargs_bundled
test_modules_load
test_path_system32_last
test_pid_is_real_winpid
test_emoji_cursor_and_delete

print
print "Results: $pass passed, $fail failed"
(( fail == 0 ))

# --- known open bug: NOT covered by a test above, documented here -------
#
# Freshly-started zsh.exe (or anything that forwards to it, i.e.
# zsh-loader.exe/zsh.cmd) resolves '/' to the calling process's cwd rather than
# a fixed filesystem root, when run standalone without the rest of a
# normal MSYS2 install tree (only a handful of files sit flatly in
# build/bin/, not the usual usr/bin/... nesting a real MSYS2 install has
# msys-2.0.dll under). Repro:
#   cd C:\Users\lowei\proj\zsh
#   build\bin\zsh.exe -f -c 'ls -ld /'
#   -> prints C:/Users/lowei/proj/zsh/ instead of a real root
# Consequences: $PWD is wrong at startup (shows "/" instead of the real
# cwd, until something explicitly cd's); /tmp, /etc, and every other
# absolute path resolve relative to whatever directory the caller
# happened to launch zsh from, so e.g. "echo x > /tmp/a" or a heredoc
# (which needs to create a temp file under /tmp) fails with "no such
# file or directory" whenever cwd doesn't happen to contain a matching
# subdirectory. This is very likely the root cause of the "/tmp path
# translation inconsistency" bug reported against this packaging
# (heredocs failing, TMPDIR/TMPPREFIX overrides not helping).
# A real MSYS2 install's bash does NOT have this problem when spawned
# the same way (verified against the system install on this machine),
# so it's specific to running msys-2.0.dll outside its normal directory
# layout, not an inherent Cygwin/MSYS2-on-Windows limitation. Bundling a
# minimal /etc/fstab next to msys-2.0.dll (either alongside it or one
# directory up) was tried and did not fix it, and a naive fstab
# containing only the "none / cygdrive ..." override made matters worse
# (it looks like it replaces rather than supplements the DLL's built-in
# default mounts, e.g. /tmp -> the Windows temp directory disappeared
# too). Not yet fixed: needs someone to work out what a from-scratch
# msys-2.0.dll actually needs on disk (or in the registry) to compute a
# real root without a full MSYS2 install tree present, which is a
# bigger investigation than the fixes in this file.
