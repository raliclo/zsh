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
# Normalize backslashes to forward slashes: run_all_tests.bat passes a
# Windows-form path (C:\Users\...\build\bin), and any test that
# interpolates $BINDIR into an inner `-c` string would otherwise have the
# backslashes eaten as escapes by the nested shell (C:\Users -> C:Users).
# Forward-slash drive paths resolve fine in the Cygwin runtime.
BINDIR=${1//\\//}
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

# --- the child must start in the caller's working directory, so a
# relative path resolves at startup (before any explicit cd). The loader
# derives this from its OWN inherited cwd (GetCurrentDirectoryW) and hands
# it to the child via ZSH_START_CWD, which .zshenv cd's into; it must NOT
# rely on the caller's PWD env var, which an MSYS parent (Git Bash) mangles
# into "<msys-root>/cygdrive/c/..." when spawning a native child. Without
# this, `cat some/relative/file` fails with "No such file or directory"
# even though the prompt shows the right directory. Runs WITHOUT -f so the
# .zshenv ZSH_START_CWD handoff is exercised. -------------------------
test_startup_cwd() {
    local tmp out
    # A path under $BINDIR, not /tmp: the standalone MSYS runtime resolves
    # a fresh process's POSIX absolute paths (/tmp, /cygdrive/c/...)
    # unreliably, but a Windows-form path derived from $BINDIR (which it
    # already resolves as the runtime's own location) works.
    tmp=$BINDIR/.cwd-test.$$
    mkdir -p -- $tmp || { fail_test "startup cwd" "could not create $tmp"; return }
    : > $tmp/cwd-marker-file
    # Spawn the launcher with the subshell's cwd = $tmp; the child must
    # start there, so the relative path to the marker resolves.
    out=$(cd -- $tmp && "$LAUNCHER" -c 'ls cwd-marker-file' 2>&1)
    rm -rf -- $tmp
    if [[ $out == *cwd-marker-file* && $out != *"No such file"* && $out != *"not access"* ]]; then
        pass_test "child inherits the caller's cwd (relative paths resolve at startup)"
    else
        fail_test "child inherits the caller's cwd (relative paths resolve at startup)" "got: ${(qq)out}"
    fi
}

# --- bundled GNU tar must win over BusyBox/Scoop shims and System32 tools --
test_tar_bundled() {
    local out
    out=$("$LAUNCHER" -f -c 'print -r -- TAR=$(command -v tar); tar --version' 2>&1)
    if [[ $out == *"TAR="*"/tar"* && $out == *"GNU tar"* && $out != *"busybox"* && $out != *"System32"* ]]; then
        pass_test "bundled GNU tar takes priority over BusyBox/System32 tar"
    else
        fail_test "bundled GNU tar takes priority over BusyBox/System32 tar" "got: ${(qq)out}"
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
        # $BINDIR-derived temp, not /tmp: the standalone MSYS runtime
        # resolves a fresh process cwd from POSIX absolute paths (/tmp)
        # unreliably; a Windows-form path under the runtime dir works.
        tmp='$BINDIR'/.utf8-test.$$
        mkdir -p -- $tmp || exit 1
        cd -- $tmp || exit 2
        name=$(printf "\347\276\216\345\234\213\345\267\245\344\275\234\350\226\252\350\263\207\347\250\205\345\213\231\350\251\246\347\256\227\350\241\250.xlsx")
        : > $name || exit 3
        ls_out=$(command ls)
        rm -f -- $name
        cd -- '$BINDIR' || exit 4
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
    # Invoke the nested launcher by its absolute path: in an in-place
    # build/bin the top dir maps to a flaky "/" for command lookup (a real
    # install resolves the bare name fine), and the point here is the
    # launcher's env handshake, not PATH resolution.
    local nested_inner='zmodload zsh/zle && print nested_loader_ok; print -r -- ORIG=$ZSH_ORIG_ZDOTDIR'
    out=$("$LAUNCHER" -c "${(q)LAUNCHER} -c ${(q)nested_inner}" 2>&1)
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
# NOT a real Windows PID and cannot be handed to tasklist/taskkill; the
# WINPID column is. This test proves it against the LIVE shell itself:
# $$ is this zsh's cygwin PID, so `ps -W -p $$` yields its WINPID (col 4),
# and tasklist -- native Windows tooling -- must list a process with that
# exact PID. Using the running shell (rather than a backgrounded sleep,
# whose PID is muddied by cygwin's fork() emulation spawning a transient
# helper) guarantees the process is present in both ps and tasklist for
# the whole check, so there is no race and nothing to reap afterwards.
test_pid_is_real_winpid() {
    local out
    out=$("$LAUNCHER" -f -c '
        line=$(ps -W -p $$ 2>/dev/null | tail -n 1)
        winpid=${${(z)line}[4]}
        if [[ -z $winpid || $winpid != <-> ]]; then
            print -r -- "NO_WINPID line=[$line]"; exit
        fi
        print -r -- "WINPID=$winpid"
        if tasklist 2>/dev/null | grep -qw -- $winpid; then
            print MATCH
        else
            print NOMATCH
        fi
    ' 2>&1)
    if [[ $out == *"WINPID="<->* && $out == *MATCH* ]]; then
        pass_test "ps -W's WINPID column is a real Windows PID (tasklist lists this shell)"
    else
        fail_test "ps -W's WINPID column is a real Windows PID (tasklist lists this shell)" "got: ${(qq)out}"
    fi
}

# --- multibyte cursor movement / deletion must treat one multibyte
# character as a single editing unit, not step/delete byte-by-byte.
# Drives a real interactive session over a pty via zsh/zpty so it
# exercises the actual ZLE code path (inccs/deccs, forward-char/
# backward-char/backward-delete-char), not just string-length arithmetic.
# Ctrl-A/Ctrl-F/Ctrl-B are used instead of arrow keys so the test doesn't
# depend on terminfo escape-sequence details -- they call the same
# INCCS()/DECCS() primitives arrow keys do.
#
# The character used is U+4E2D (中), a CJK ideograph in the Basic
# Multilingual Plane -- 3 UTF-8 bytes, one wchar_t. NON-BMP characters
# (emoji, e.g. U+1F389) are DELIBERATELY not used here: this build's
# Cygwin runtime mis-decodes them (verified: the typed bytes
# f0 9f 8e 89 come back as the two wchar_t values U+17B3 and U+FFFF, not
# the UTF-16 surrogate pair D83C/DF89), so the surrogate-pair handling in
# Src/Zle/zle_move.c can never engage on this runtime -- the corruption
# is below ZLE, in mbrtowc, and no ZLE-level fix reaches it. See
# helper/README-win.md "Known limitations". BMP multibyte editing (the
# common case: CJK, accented Latin, etc.) works correctly and is what
# this test locks in.
#
# Reading the result reliably is the hard part: ZLE repaints the whole
# input line on every keystroke, so the pty stream is full of prompt
# redraws and ANSI escapes. Rather than sync on the prompt (which a
# redraw also matches, so a naive wait returns before the keystrokes are
# even processed), we drain the pty until it goes idle and then pull the
# value out of a sentinel-wrapped echo: after the edit we run
#   print -r -- ">>>$X<<<"
# The command line the terminal echoes back contains a literal "$X"
# (a '$'), while the command's actual OUTPUT contains the expanded value
# and appears LAST in the stream -- so the text between the final ">>>"
# and its following "<<<" is the value, and never collides with the echo.
#
# The inner session needs TERM/TERMINFO set to something that actually
# resolves (this build's bundled terminfo db is hashed by the first
# letter's hex code, e.g. xterm -> 78/xterm; "dumb" was not enough to
# avoid a startup error, xterm was), ZSH_PORTABLE_DIR/ZDOTDIR set the
# same way zsh.cmd/zsh-loader.exe do (this spawns zsh.exe directly), and
# LC_ALL=C.utf8 -- a locale that ACTUALLY appears in `locale -a`, unlike
# "C.UTF-8"/"POSIX.UTF-8" -- so ZLE decodes the input as wide characters
# instead of raw bytes.

# Read from the pty until it has produced no new data for a short idle
# window (or a hard cap is hit), then return everything seen. zpty -r
# without -t blocks forever on a wrong pattern, so this only ever uses
# the non-blocking -t form.
zpty_drain() {
    local session=$1
    local -i max_idle=${2:-8} hard_cap=${3:-200}
    local -i idle=0 total=0
    local chunk buf=""
    while (( idle < max_idle && total < hard_cap )); do
        if zpty -r -t $session chunk 2>/dev/null; then
            buf+=$chunk
            idle=0
        else
            (( idle++ ))
            sleep 0.05
        fi
        (( total++ ))
    done
    print -r -- $buf
}

# Send an edit keystroke sequence that ends by assigning $X and pressing
# Enter, then echo $X wrapped in sentinels and extract the value.
mb_probe() {
    local session=$1 keystrokes=$2 buf val
    zpty -w -n $session $keystrokes
    zpty_drain $session >/dev/null           # let the assignment settle
    zpty -w -n $session $'print -r -- ">>>$X<<<"\r'
    buf=$(zpty_drain $session)
    val=${buf##*>>>}                          # after the LAST >>> (the output)
    val=${val%%<<<*}                          # up to the next <<<
    print -r -- ${val//$'\r'/}
}

test_multibyte_cursor_and_delete() {
    zmodload zsh/zpty 2>/dev/null

    local session=zsh_mb_test
    zpty -d $session 2>/dev/null

    # ZSH_ORIG_ZDOTDIR is pinned to $BINDIR so the forwarding stubs see
    # user-dir == portable-dir and skip sourcing the developer's real
    # ~/.zshrc into the pty session (slow, noisy, and it would redefine
    # the prompt this test synchronizes on).
    local spawn_cmd="LC_ALL=C.utf8 TERMINFO='$BINDIR/share/terminfo' ZDOTDIR='$BINDIR' ZSH_ORIG_ZDOTDIR='$BINDIR' ZSH_PORTABLE_DIR='$BINDIR' TERM=xterm PS1='%% ' '$INTERP' -i"
    if ! zpty $session $spawn_cmd; then
        fail_test "multibyte cursor/delete test setup" "could not start pty session"
        return
    fi
    if [[ $(zpty_drain $session) != *'% '* ]]; then
        fail_test "multibyte cursor/delete test setup" "shell did not reach a prompt"
        zpty -d $session 2>/dev/null
        return
    fi

    # Insertion: type X=A<中>B, jump to line start (^A), step over "X=A"
    # with three forward-chars (^F), then ONE MORE forward-char -- if the
    # 3-byte character is one editing unit this lands right after it
    # (before B); if ZLE stepped byte-by-byte it would land inside the
    # character and inserting Y there would corrupt it.
    local insert_result=$(mb_probe $session $'X=A\xe4\xb8\xadB\x01\x06\x06\x06\x06Y\r')

    # Deletion: type X=A<中>B, back up one char (^B, now right after the
    # character), then one backward-delete-char (DEL) -- should remove the
    # whole 3-byte character, not just its last byte.
    local delete_result=$(mb_probe $session $'X=A\xe4\xb8\xadB\x02\x7f\r')

    zpty -d $session 2>/dev/null

    local expect_insert=$'A\xe4\xb8\xadYB'
    local expect_delete=$'AB'

    if [[ $insert_result == $expect_insert ]]; then
        pass_test "forward-char treats a multibyte char as one unit (insert-after stays clean)"
    else
        fail_test "forward-char treats a multibyte char as one unit (insert-after stays clean)" "got: ${(qq)insert_result}"
    fi
    if [[ $delete_result == $expect_delete ]]; then
        pass_test "backward-delete-char removes a whole multibyte char, not one byte"
    else
        fail_test "backward-delete-char removes a whole multibyte char, not one byte" "got: ${(qq)delete_result}"
    fi
}

test_multiline_c
test_pipe_in_quotes
test_embedded_quotes
test_find_bundled
test_xargs_bundled
test_startup_cwd
test_tar_bundled
test_portable_usr_bin_tools
test_utf8_filename_roundtrip
test_modules_load
test_nested_zsh
test_user_rc_forwarding
test_path_system32_last
test_pid_is_real_winpid
test_multibyte_cursor_and_delete

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
