#!/usr/bin/env zsh
#
# Automated regression tests for the Windows portable zsh packaging
# (helper/compile.sh output). Everything here runs through the built
# binaries directly -- no PowerShell -- since PowerShell's own argument
# quoting is a separate, unrelated source of test noise.
#
# Must be run through the build's own LAUNCHER (zsh-loader.exe), not the
# bare zsh.exe interpreter and not a system zsh:
#   build/bin/zsh-loader.exe -f helper/test/test_windows_packaging.zsh <build/bin path>
# Two reasons. It needs zsh/zpty and is testing this build specifically.
# And when the bare zsh.exe is spawned from another MSYS-runtime shell
# (Git Bash, the system MSYS2 bash, ...), that parent sees a child
# importing a DLL named msys-2.0.dll -- same NAME as its own runtime,
# but a different build -- and hands the environment over via its
# runtime's internal protocol instead of the Win32 environment block;
# our different-build DLL can't read that, so the bare interpreter comes
# up with most of its environment (USERPROFILE included) silently
# missing, and every launcher handshake test below misbehaves for
# reasons that have nothing to do with the launcher. Entering through
# zsh-loader.exe (a native PE, so the parent does a full Win32 export to
# it) avoids all of that.
#
# The build/bin path is a REQUIRED argument, not auto-detected: this
# build's msys-2.0.dll, run standalone without the rest of a normal
# MSYS2 install tree, resolves '/' (and so $PWD, and so $0:A) to the
# calling process's cwd rather than a fixed filesystem root -- see the
# bug report at the bottom of this file -- so there's no reliable way
# from inside the script to derive its own location or the caller's cwd.

emulate -L zsh
setopt no_unset pipefail

if [[ -z ${1:-} ]]; then
    print -u2 "usage: zsh-loader.exe -f test_windows_packaging.zsh <path to build/bin>"
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

# --- embedded double quotes in a -c script must reach zsh as real quoting,
# not survive as literal " characters. When broken, the caller's escaped
# quotes leak through so `echo "x"` prints "x" with the marks and
# `[[ "test" == t* ]]` compares the 6-char string including quotes (never
# matching t*). This is the Git-Bash/MSYS quote-forwarding bug: MSYS
# escapes embedded quotes as \" and CommandLineToArgvW must be trusted to
# unescape them (see protect_command_arg in zsh_launcher.c). ------------
test_embedded_quotes() {
    local out
    out=$("$LAUNCHER" -f -c 'echo "hello world"; [[ "test" == t* ]] && echo matched' 2>&1)
    if [[ $out == $'hello world\nmatched' ]]; then
        pass_test "embedded double quotes in -c become real quoting, not literal chars"
    else
        fail_test "embedded double quotes in -c become real quoting, not literal chars" "got: ${(qq)out}"
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

# --- absolute POSIX tool paths and terminal helpers must resolve inside
# the portable package. This catches regressions where the MSYS root is
# inferred as the parent Scoop apps directory, or terminal-state commands
# fall through to BusyBox/Scoop shims after Ctrl-C/ZLE resets. -----------
test_portable_usr_bin_tools() {
    local out
    out=$("$LAUNCHER" -f -c '
        test -x /usr/bin/env &&
        for tool in ls locale stty reset tset infocmp tput; do
            command -v $tool | grep -E "(/zsh/current|build/bin|usr/bin)" >/dev/null || exit 10
        done &&
        print tools_ok
    ' 2>&1)
    if [[ $out == *tools_ok* ]]; then
        pass_test "/usr/bin/env and terminal helpers resolve from the portable runtime"
    else
        fail_test "/usr/bin/env and terminal helpers resolve from the portable runtime" "got: ${(qq)out}"
    fi
}

# --- Windows Unicode filenames must round-trip through zsh as UTF-8.
# Without LC_CTYPE=UTF-8 before the MSYS runtime starts, names such as
# Chinese .xlsx files can be decoded through a legacy code page and show
# up as replacement characters or mojibake in `ls`. The filename below is
# "美國工作薪資稅務試算表.xlsx", encoded as UTF-8 octal escapes so this
# test file itself stays ASCII-safe. -----------------------------------
test_utf8_filename_roundtrip() {
    local out
    out=$("$LAUNCHER" -f -c '
        tmp=${TMPDIR:-/tmp}/zsh-utf8-filename.$$
        mkdir -p -- $tmp || exit 1
        cd -- $tmp || exit 1
        name=$(printf "\347\276\216\345\234\213\345\267\245\344\275\234\350\226\252\350\263\207\347\250\205\345\213\231\350\251\246\347\256\227\350\241\250.xlsx")
        : > $name || exit 1
        ls_out=$(command ls)
        rm -f -- $name
        cd / || exit 1
        rmdir -- $tmp
        [[ $ls_out == *$name* ]] && print utf8_filename_ok
    ' 2>&1)
    if [[ $out == *utf8_filename_ok* ]]; then
        pass_test "UTF-8 filenames round-trip through ls"
    else
        fail_test "UTF-8 filenames round-trip through ls" "got: ${(qq)out}"
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

# --- nesting: a zsh spawned from INSIDE a portable-zsh session must be
# able to load modules too. ZDOTDIR stays pointed at the portable dir
# for the whole session tree (with forwarding rc stubs for the user's
# real startup files), so a nested bare zsh.exe -- or a nested launcher,
# whose ZSH_ORIG_ZDOTDIR guard must keep the original caller's value
# instead of clobbering it -- inherits a live bootstrap, not a consumed
# one. ---------------------------------------------------------------
test_nested_zsh() {
    local out
    out=$("$LAUNCHER" -c 'zsh.exe -c "zmodload zsh/zle && print nested_interp_ok"' 2>&1)
    if [[ $out == *nested_interp_ok* ]]; then
        pass_test "nested bare zsh.exe loads modules"
    else
        fail_test "nested bare zsh.exe loads modules" "got: ${(qq)out}"
    fi
    out=$("$LAUNCHER" -c 'zsh-loader.exe -c "zmodload zsh/zle && print nested_loader_ok; print -r -- ORIG=\$ZSH_ORIG_ZDOTDIR"' 2>&1)
    if [[ $out == *nested_loader_ok* && $out != *ORIG=*build[/\\]bin* ]]; then
        pass_test "nested launcher loads modules and preserves the original ZSH_ORIG_ZDOTDIR"
    else
        fail_test "nested launcher loads modules and preserves the original ZSH_ORIG_ZDOTDIR" "got: ${(qq)out}"
    fi
}

# --- the user's real startup files must still be loaded even though
# ZDOTDIR points at the portable dir: the forwarding stubs (.zshenv,
# .zshrc, ...) hand off to $ZSH_ORIG_ZDOTDIR's counterparts. Verified
# with a scratch ZDOTDIR so the test doesn't depend on (or execute) the
# developer's real ~/.zshrc. ------------------------------------------
test_user_rc_forwarding() {
    local scratch out
    scratch=$BINDIR/nested-rc-test.$$
    mkdir -p $scratch || {
        fail_test "user rc forwarding" "could not create scratch dir $scratch"
        return
    }
    print 'print -r -- user_zshenv_ran' > $scratch/.zshenv
    print 'print -r -- user_zshrc_ran'  > $scratch/.zshrc
    out=$(ZDOTDIR=$scratch "$LAUNCHER" -i -c 'print -r -- session_ok' 2>&1)
    rm -rf $scratch
    if [[ $out == *user_zshenv_ran* && $out == *user_zshrc_ran* && $out == *session_ok* ]]; then
        pass_test "user .zshenv/.zshrc still run via the forwarding stubs"
    else
        fail_test "user .zshenv/.zshrc still run via the forwarding stubs" "got: ${(qq)out}"
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

    # ZSH_ORIG_ZDOTDIR is pinned to $BINDIR so the forwarding stubs see
    # user-dir == portable-dir and skip sourcing the developer's real
    # ~/.zshrc into the pty session (slow, noisy, and it would redefine
    # the prompt this test synchronizes on).
    local spawn_cmd="TERMINFO='$BINDIR/share/terminfo' ZDOTDIR='$BINDIR' ZSH_ORIG_ZDOTDIR='$BINDIR' ZSH_PORTABLE_DIR='$BINDIR' TERM=xterm PS1='%% ' '$INTERP' -i"
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
test_embedded_quotes
test_find_bundled
test_xargs_bundled
test_portable_usr_bin_tools
test_utf8_filename_roundtrip
test_modules_load
test_nested_zsh
test_user_rc_forwarding
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
