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
if [[ $BINDIR == [A-Za-z]:/* ]]; then
    BINDIR="/${(L)BINDIR[1]}/${BINDIR[4,-1]}"
else
    BINDIR=${BINDIR:A}
fi
TEST_REPO_ROOT=${2:-}
if [[ -n $TEST_REPO_ROOT ]]; then
    TEST_REPO_ROOT=${TEST_REPO_ROOT//\\//}
    if [[ $TEST_REPO_ROOT == [A-Za-z]:/* ]]; then
        TEST_REPO_ROOT="/${(L)TEST_REPO_ROOT[1]}/${TEST_REPO_ROOT[4,-1]}"
    else
        TEST_REPO_ROOT=${TEST_REPO_ROOT:A}
    fi
fi
LAUNCHER=$BINDIR/zsh-loader.exe
PUBLIC_EXE=$BINDIR/zsh.exe
INTERP=$BINDIR/usr/bin/zsh.exe
ZSHCMD=$BINDIR/zsh.cmd

# This script itself runs with -f (no rcs), so .zshenv never sets
# module_path -- do it directly for the zpty-based test below.
module_path=($BINDIR $module_path)

typeset -i pass=0 fail=0 skip=0

pass_test() { print -P "%F{green}PASS%f: $1"; (( ++pass )) }
fail_test() { print -P "%F{red}FAIL%f: $1 -- $2"; (( ++fail )) }
# A test whose PRECONDITION is absent is neither a pass nor a failure. Counting
# it as a pass is the shape this suite exists to catch -- a green line for
# something that never ran -- and counting it as a failure would report a
# machine without WSL as a broken package. It is reported with its reason and
# counted separately, so "0 skipped" is what says the run was complete.
skip_test() { print -P "%F{yellow}SKIP%f: $1 -- $2"; (( ++skip )) }

for f in $LAUNCHER $PUBLIC_EXE $INTERP $ZSHCMD; do
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

# --- users may bypass the Scoop shim and call apps/zsh/current/zsh.exe
# directly. That public root executable must be the native launcher too,
# otherwise PowerShell/MSYS argv boundaries can leak '|' from quoted regexes
# inside a -c script into real pipelines. ---------------------------------
test_public_zsh_exe_preserves_pipe_regex() {
    local out
    out=$("$PUBLIC_EXE" -lc 'print -r -- "^@@|RGB1|zstd|ZSTD|WriteBackend|ensureDir|TarCodec|level|--rgb1|--zstd|-1\.\.-22"' 2>&1)
    if [[ $out == '^@@|RGB1|zstd|ZSTD|WriteBackend|ensureDir|TarCodec|level|--rgb1|--zstd|-1\.\.-22' ]]; then
        pass_test "public zsh.exe preserves quoted pipe-heavy regex arguments"
    else
        fail_test "public zsh.exe preserves quoted pipe-heavy regex arguments" "got: ${(qq)out}"
    fi
}

# --- the launcher preserves the -c script, but zsh still evaluates that
# script as shell syntax. Nested Perl/AWK/etc. snippets with $variables must
# be single-quoted inside the zsh script (or escape each $) so zsh does not
# expand them before the tool sees them. -----------------------------------
test_nested_perl_dollars_survive_with_shell_quoting() {
    local tmp out script
    tmp=$BINDIR/.perl-dollar-test.$$
    mkdir -p -- $tmp || { fail_test "nested Perl dollar variables survive with shell quoting" "could not create $tmp"; return }
    print -r -- alpha > $tmp/lines.txt
    print -r -- beta >> $tmp/lines.txt

    script=$'cat "'$tmp$'/lines.txt" | perl -ne \'if (/\\r\\n$/) { $crlf++ } elsif (/\\n$/) { $lf++ } END { print qq(parent_crlf=$crlf parent_lf=$lf\\n) }\'; perl -ne \'if (/\\r\\n$/) { $crlf++ } elsif (/\\n$/) { $lf++ } END { print qq(work_crlf=$crlf work_lf=$lf\\n) }\' "'$tmp$'/lines.txt"'
    out=$("$PUBLIC_EXE" -lc "$script" 2>&1)
    rm -rf -- $tmp
    if [[ $out == $'parent_crlf= parent_lf=2\nwork_crlf= work_lf=2' ]]; then
        pass_test "nested Perl dollar variables survive with shell quoting"
    else
        fail_test "nested Perl dollar variables survive with shell quoting" "got: ${(qq)out}"
    fi
}

# --- zsh arithmetic commands return false when the expression evaluates to
# zero. With ERR_EXIT enabled, `(( applied++ ))` therefore exits the script on
# the first increment because post-increment evaluates to the old value (0).
# Use pre-increment or assignment increments in helper/test scripts. --------
test_arithmetic_increment_is_err_exit_safe() {
    local out
    out=$("$PUBLIC_EXE" -fc '
        setopt err_exit
        integer applied=0
        (( ++applied ))
        print -r -- applied=$applied
    ' 2>&1)
    if [[ $out == 'applied=1' ]]; then
        pass_test "pre-increment counters survive ERR_EXIT"
    else
        fail_test "pre-increment counters survive ERR_EXIT" "got: ${(qq)out}"
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

# --- Windows/POSIX scripts often pass regex groups such as
# (run_round|encode-win|...) to grep/rg/PowerShell. In stock zsh, an
# unmatched glob-like token aborts with "no matches found"; the portable
# Windows environment keeps those arguments literal for script compatibility.
test_nomatch_disabled_for_regex_args() {
    local out
    out=$("$LAUNCHER" -c '
        print -r -- (run_round|encode-win|decode-win|rss-win|lzfse|swift_tar)
        print -r -- rss-win | grep -E (run_round|encode-win|decode-win|rss-win|lzfse|swift_tar)
    ' 2>&1)
    if [[ $out == $'(run_round|encode-win|decode-win|rss-win|lzfse|swift_tar)\nrss-win' ]]; then
        pass_test "unmatched regex-like grouped args pass through literally"
    else
        fail_test "unmatched regex-like grouped args pass through literally" "got: ${(qq)out}"
    fi
}

# --- Arguments AFTER the script name are the script's operands, and the
# launcher must not reinterpret them as its own options. protect_command_arg
# used to scan the whole of argv for a -c to protect, so a single-dash
# operand that merely contained a 'c' (`-backup` -> b,a,c,k,u,p) looked like
# an option cluster and the argument after it was overwritten with the
# loader's internal eval string -- silent corruption, exit status unchanged.
# `--profile` was never hit only because a leading "--" is rejected, which is
# why the damage looked arbitrary. Reference behavior confirmed against Linux
# zsh 5.9: all three arguments arrive untouched. ------------------------
test_script_args_not_reinterpreted() {
    local script=$BINDIR/argv-operands-test.$$.zsh
    print -r -- 'print -r -- "$1|$2|$3"' > $script || {
        fail_test "script arguments are not reinterpreted as launcher options" \
            "could not create $script"
        return
    }
    # Third argument is deliberately NOT path-like. A POSIX-looking path here
    # would be rewritten by MSYS argument conversion in the calling shell
    # (/tmp/x -> C:/.../tmp/x) before the launcher ever sees it -- expected
    # behavior, unrelated to this bug, and it would make the assertion fail
    # for the wrong reason.
    local out
    out=$("$LAUNCHER" -f $script -backup --profile value3 2>&1)
    rm -f $script
    if [[ $out == '-backup|--profile|value3' ]]; then
        pass_test "script arguments are not reinterpreted as launcher options"
    else
        fail_test "script arguments are not reinterpreted as launcher options" "got: ${(qq)out}"
    fi
}

# --- A Windows drive path is absolute on this platform -- the runtime opens
# it fine -- but it does not start with '/', so zsh's path modifiers used to
# treat it as relative and prepend the cwd, turning C:/Users/x into
# <cwd>/C:/Users/x. Scripts then created directories literally named 'C:'.
# The patch normalizes drive paths to POSIX form rather than merely accepting
# them as absolute: realpath() hands a drive path straight back unchanged, so
# otherwise :A would echo back whichever spelling it was given and two paths
# naming the same file would not compare equal.
#
# :A, :a and :P are all covered because the "prepend cwd" test is written out
# twice in the source -- chabspath() in hist.c serves :A and :a, while the 'P'
# case in subst.c has its own copy -- so a fix to one does not imply the other.
test_drive_path_modifiers() {
    local out
    out=$("$LAUNCHER" -f -c '
        cd /
        for p in "C:/Users" "C:\\Users" ; do
            print -r -- "${p:A} ${p:a} ${p:P}"
        done
        # a colon that is not a drive letter must stay relative
        cd /tmp && print -r -- "${${:-foo:bar}:A}"
    ' 2>&1)
    local expected=$'/c/Users /c/Users /c/Users\n/c/Users /c/Users /c/Users\n/tmp/foo:bar'
    if [[ $out == $expected ]]; then
        pass_test "drive paths are absolute and normalized for :A, :a and :P"
    else
        fail_test "drive paths are absolute and normalized for :A, :a and :P" "got: ${(qq)out}"
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
# into "<msys-root>/c/..." when spawning a native child. Without
# this, `cat some/relative/file` fails with "No such file or directory"
# even though the prompt shows the right directory. Runs WITHOUT -f so the
# .zshenv ZSH_START_CWD handoff is exercised. -------------------------
test_startup_cwd() {
    local tmp out
    # A path under $BINDIR, not /tmp: the standalone MSYS runtime resolves
    # a fresh process's POSIX absolute paths (/tmp, /c/...)
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

# --- packaged runtime paths should use MSYS2's short drive mount form. -----
test_msys_drive_prefix() {
    local out
    out=$("$LAUNCHER" -c '
        test -r /etc/fstab || exit 4
        grep -q "none / cygdrive" /etc/fstab || exit 5
        test -d /c || exit 1
        [[ $PWD == /c/* ]] || exit 2
        [[ $TERMINFO == /c/* ]] || exit 3
        print -r -- msys_drive_ok
    ' 2>&1)
    if [[ $out == *msys_drive_ok* ]]; then
        pass_test "packaged runtime drive paths use /<drive> and resolve"
    else
        fail_test "packaged runtime drive paths use /<drive> and resolve" "got: ${(qq)out}"
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
        tmp='$BINDIR'/.packaging-tool-test.$$ || exit 1
        mkdir -p -- $tmp || { print mkdir_tmp_failed; exit 20; }
        cd -- $tmp || { print cd_tmp_failed; exit 21; }
        test -x /usr/bin/env || { print env_missing; exit 22; }
        for tool in ls locale stty reset tset infocmp tput du file mkdir cp rm mv nc openssl xxd which make sha256sum pgrep pkill pidof killall m4 perl autoconf autom4te autoheader autoreconf; do
            whence -p "$tool" | grep -E "(/zsh/current|build/bin|usr/bin)" >/dev/null || { print -r -- "missing_or_shadowed:$tool"; exit 10; }
        done &&
        autoconf --version >/dev/null || { print autoconf_failed; exit 26; }
        command -v -- "[" >/dev/null || { print bracket_lookup_failed; exit 23; }
        test -x "/usr/bin/[" || { print bracket_exe_missing; exit 24; }
        "/usr/bin/[" -x /usr/bin/env "]" || { print bracket_exe_failed; exit 25; }
        du -s . >/dev/null &&
        : > file &&
        cp file copy &&
        mv copy moved &&
        test -f moved &&
        cd -- '$BINDIR' &&
        rm -rf -- $tmp &&
        which sh >/dev/null &&
        print test | sha256sum >/dev/null &&
        print tools_ok
    ' 2>&1)
    if [[ $out == *tools_ok* ]]; then
        pass_test "/usr/bin/env, du, and terminal helpers resolve from the portable runtime"
    else
        fail_test "/usr/bin/env, du, and terminal helpers resolve from the portable runtime" "got: ${(qq)out}"
    fi
}

# --- version.txt must identify the zsh build and the versions of bundled
# tools copied into the portable runtime, so package contents are auditable. --
test_version_txt_records_bundled_tools() {
    local version_file=$BINDIR/version.txt
    local missing=()
    if [[ ! -r $version_file ]]; then
        fail_test "version.txt records bundled tool versions" "missing $version_file"
        return
    fi
    if ! grep -qx 'bundled tools:' $version_file; then
        fail_test "version.txt records bundled tool versions" "missing bundled tools section"
        return
    fi
    local tool
    for tool in grep find tar perl autoconf ps file nc openssl xxd; do
        if ! grep -qE "^${tool}"$'\t' $version_file; then
            missing+=($tool)
        fi
    done
    if (( $#missing == 0 )); then
        pass_test "version.txt records bundled tool versions"
    else
        fail_test "version.txt records bundled tool versions" "missing tools: ${(j:,:)missing}"
    fi
}

# --- terminfo must be present and usable for common terminals. If the
# packaged app is missing share/terminfo, zsh starts with
# "can't find terminal definition for xterm-256color" and every tput call
# from user startup files repeats the error. -------------------------------
test_xterm_terminfo_bundled() {
    local out
    out=$(TERM=xterm-256color "$LAUNCHER" -c '
        [[ -d $TERMINFO ]] || { print -r -- "missing_TERMINFO=$TERMINFO"; exit 1; }
        [[ -f $TERMINFO/78/xterm-256color || -f $TERMINFO/x/xterm-256color ]] || {
            print -r -- "missing_xterm_256color_in=$TERMINFO"
            exit 2
        }
        tput colors >/dev/null || exit 3
        print terminfo_ok
    ' 2>&1)
    if [[ $out == *terminfo_ok* ]]; then
        pass_test "xterm-256color terminfo is bundled and tput can read it"
    else
        fail_test "xterm-256color terminfo is bundled and tput can read it" "got: ${(qq)out}"
    fi
}

# --- `[` is both shell syntax and an executable named "[.exe". Ensure tests
# and scripts can resolve and invoke the executable by quoting it explicitly;
# unquoted `[` in generated one-liners can leave zsh waiting for syntax that
# never arrives, which looks like a hang. ----------------------------------
test_bracket_tool_lookup() {
    local out
    out=$("$LAUNCHER" -c '
        command -v -- "[" &&
        "/usr/bin/[" -x /usr/bin/env "]" &&
        print bracket_tool_ok
    ' 2>&1)
    if [[ $out == *"bracket_tool_ok"* ]]; then
        pass_test "quoted '[' command lookup and /usr/bin/[ execution work"
    else
        fail_test "quoted '[' command lookup and /usr/bin/[ execution work" "got: ${(qq)out}"
    fi
}

# --- default Windows executable wrappers. MSYS `kill` takes the
# internal Cygwin/MSYS PID column, not `ps -eW`'s WINPID column, so the
# portable environment exposes safe taskkill wrappers and killwin.
# `wsl.exe` also needs conversion disabled so /mnt/c/... and --cd paths
# are passed to WSL unchanged instead of being rewritten by MSYS. -------
test_windows_exe_wrappers() {
    local out
    out=$("$LAUNCHER" -c 'whence -w taskkill taskkill.exe killwin wsl wsl.exe; functions taskkill taskkill.exe killwin wsl wsl.exe' 2>&1)
    if [[ $out == *"taskkill: function"* && $out == *"taskkill.exe: function"* &&
          $out == *"MSYS2_ARG_CONV_EXCL"* && $out == *"command taskkill.exe"* &&
          $out == *"killwin: function"* && $out == *"taskkill /PID"* && $out == *"/F"* &&
          $out == *"wsl: function"* && $out == *"wsl.exe: function"* &&
          $out == *"command wsl.exe"* ]]; then
        pass_test "Windows executable wrappers bypass MSYS option-to-path conversion"
    else
        fail_test "Windows executable wrappers bypass MSYS option-to-path conversion" "got: ${(qq)out}"
    fi
}

# --- wsl.exe hands its arguments to the WSL LOGIN SHELL, even when no shell
# was asked for: `wsl.exe -- printf '%s' '[$HOME]'` answers
# `zsh:1: no matches found: [/home/lowei]` -- printf expands nothing, so both
# the substitution and the glob came from a shell nobody invoked. The damage is
# silent whenever the metacharacter resolves: '/etc/hostn*me' arrives as
# '/etc/hostname', and '$p' for an unset p arrives empty, which reads as "the
# tool is not installed". --exec skips that shell, and is the fix.
#
# Asserted through the real wsl.exe rather than by grepping a script, because
# the claim is about what CROSSES the boundary; a source-level check would pass
# on a machine where the behaviour had changed underneath it. -------------
test_wsl_exec_preserves_argv() {
    local out
    if ! MSYS2_ARG_CONV_EXCL='*' wsl.exe --exec true >/dev/null 2>&1; then
        skip_test "wsl.exe --exec passes arguments through unexpanded" \
            "no working WSL on this machine"
        return
    fi
    # Three metacharacters, one call: a dollar that would be emptied, a glob
    # that would silently MATCH something real, and brackets that would glob.
    out=$(MSYS2_ARG_CONV_EXCL='*' wsl.exe --exec printf '%s|%s|%s' \
            'A$pB' '/etc/hostn*me' '[$HOME]' 2>&1)
    if [[ $out == 'A$pB|/etc/hostn*me|[$HOME]' ]]; then
        pass_test "wsl.exe --exec passes arguments through unexpanded"
    else
        fail_test "wsl.exe --exec passes arguments through unexpanded" "got: ${(qq)out}"
    fi
}

# --- the packaged environment exposes that as `exec-wsl`. Asserted by RUNNING
# it, not by checking the function is defined: a wrapper that exists and
# forwards to plain `wsl.exe` would satisfy a `whence` check while losing every
# argument, which is the failure this helper exists to prevent. -------------
test_exec_wsl_helper_preserves_argv() {
    local out
    if ! MSYS2_ARG_CONV_EXCL='*' wsl.exe --exec true >/dev/null 2>&1; then
        skip_test "exec-wsl preserves arguments" "no working WSL on this machine"
        return
    fi
    out=$("$LAUNCHER" -c "exec-wsl printf '%s|%s' 'A\$pB' '/etc/hostn*me'" 2>&1)
    if [[ $out == 'A$pB|/etc/hostn*me' ]]; then
        pass_test "exec-wsl preserves arguments"
    else
        fail_test "exec-wsl preserves arguments" "got: ${(qq)out}"
    fi
}

# --- `winhelp` is where a user finds the helpers above. It is asserted to
# NAME each one, because the failure mode of a hand-written list is that a
# helper is added and the list is not updated -- and a list that omits the
# thing you are looking for is worse than no list, since it reads as "this
# port does not have that". Also asserts nothing is printed at STARTUP: a
# banner would contaminate the output of every non-interactive zsh. --------
test_winhelp_lists_the_helpers() {
    local out startup
    out=$("$LAUNCHER" -c 'winhelp' 2>&1)
    if [[ $out == *exec-wsl* && $out == *killwin* && $out == *taskkill* ]]; then
        pass_test "winhelp names exec-wsl, killwin and taskkill"
    else
        fail_test "winhelp names exec-wsl, killwin and taskkill" "got: ${(qq)out}"
    fi
    startup=$("$LAUNCHER" -c 'true' 2>&1)
    if [[ -z $startup ]]; then
        pass_test "startup prints nothing (winhelp is opt-in, not a banner)"
    else
        fail_test "startup prints nothing (winhelp is opt-in, not a banner)" \
            "got: ${(qq)startup}"
    fi
}

# --- usr/bin/zsh.exe is the REAL interpreter; the root zsh.exe is a launcher
# that forwards to it. It must therefore run on its own, without the bundle
# root already on PATH to supply libzsh.
#
# This exists because the whole suite passed while it was broken. compile.sh
# copied the runtime libraries into usr/bin with a `bin/*.dll` glob, and
# libzsh is named with configure's DL_EXT -- which became .so when an MSYS2
# update changed what config.guess reports. The glob then matched nothing,
# usr/bin/zsh.exe could not find its core library, and it printed NOTHING and
# exited 0. Every existing test went through the launcher, by which point the
# bundle root was on PATH and the library resolved, so 43 tests passed with
# the real interpreter unable to start. Exercise it the way a bare
# `#!/usr/bin/zsh` shebang would. ------------------------------------------
test_usr_bin_zsh_runs_standalone() {
    local out
    # env -i would also drop the variables MSYS itself needs; narrowing PATH to
    # the system directory is enough to remove the bundle root that was hiding
    # the fault, while leaving the process otherwise ordinary.
    out=$(PATH=/c/Windows/System32 "$BINDIR/usr/bin/zsh.exe" -f -c 'printf "ZSHOK %s\n" $ZSH_VERSION' 2>&1)
    if [[ $out == ZSHOK* ]]; then
        pass_test "usr/bin/zsh.exe runs without the bundle root on PATH"
    else
        fail_test "usr/bin/zsh.exe runs without the bundle root on PATH" \
            "got: ${(qq)out} -- libzsh missing from usr/bin? (compile.sh copies it by \$DL_EXT)"
    fi
}

# --- ...but "bypass" must not mean the blanket '*'. Excluding everything also
# suppresses MSYS's own //x -> /x collapse, so the Git Bash idiom
# `taskkill //F //IM foo` arrived as a literal '//F' and was rejected: exit 1
# with the target process still ALIVE. A kill that reports failure but is read
# as done is the expensive shape -- see helper/bugs/bugs.md. The wrapper now
# excludes only the tools' own option prefixes, which keeps the single-slash
# Microsoft form safe from conversion AND lets the double-slash form collapse.
# Assert BOTH spellings parse. A nonexistent image name is used so nothing is
# killed: "not found" proves the option was understood, whereas
# "Invalid argument/option" is the regression being guarded against. ---------
test_taskkill_accepts_both_slash_forms() {
    local out desc spec
    for desc spec in \
        "taskkill /F /IM"    'taskkill /F /IM zz_no_such_proc_xyz.exe' \
        "taskkill //F //IM"  'taskkill //F //IM zz_no_such_proc_xyz.exe' \
        "taskkill /PID /F"   'taskkill /PID 999999 /F' \
        "taskkill //PID //F" 'taskkill //PID 999999 //F' \
        "tasklist /FI"       'tasklist /FI "IMAGENAME eq zz_no_such_proc_xyz.exe"' \
        "tasklist //FI"      'tasklist //FI "IMAGENAME eq zz_no_such_proc_xyz.exe"'
    do
        out=$("$LAUNCHER" -c "$spec" 2>&1)
        if [[ $out == *"Invalid argument"* || $out == *[A-Za-z]:/*FI* ]]; then
            fail_test "$desc is understood (MSYS did not rewrite the option)" "got: ${(qq)out}"
        else
            pass_test "$desc is understood (MSYS did not rewrite the option)"
        fi
    done
}

# --- MSYS rewrites slash-prefixed argv for native Windows programs, so
# e-invoice barcode test data such as /AB12+-. can be corrupted before Node
# receives it. Keep JavaScript runtime/test entry points under the same
# package-level no-conversion wrapper policy. -----------------------------
test_javascript_wrappers_preserve_slash_prefixed_argv() {
    local out
    out=$("$LAUNCHER" -c '
        whence -w node node.exe npm npx pnpm yarn bun bun.exe deno deno.exe
        functions zsh_portable_no_msys_arg_conv node node.exe npm npx pnpm yarn bun bun.exe deno deno.exe
        if whence -p node.exe >/dev/null; then
            node.exe -e "console.log(JSON.stringify(process.argv.slice(1)))" /AB12+-.
        else
            print node_missing_skip
        fi
    ' 2>&1)
    if [[ $out == *"node: function"* && $out == *"node.exe: function"* &&
          $out == *"MSYS2_ARG_CONV_EXCL"* &&
          ( $out == *'["/AB12+-."]'* || $out == *"node_missing_skip"* ) ]]; then
        pass_test "JavaScript wrappers preserve slash-prefixed argv for native runtimes"
    else
        fail_test "JavaScript wrappers preserve slash-prefixed argv for native runtimes" "got: ${(qq)out}"
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

# --- User startup files must not override the Cygwin locale required by ZLE.
# LC_ALL has priority over LC_CTYPE; if ~/.zshrc exports a non-C.utf8 LC_ALL,
# ZLE can display the typed line correctly while executing a corrupted buffer
# after bracketed paste or other multibyte input activity. ----------------
test_user_lc_all_is_sanitized() {
    local tmp out
    tmp=$BINDIR/.locale-rc-test.$$
    mkdir -p -- $tmp || {
        fail_test "user LC_ALL cannot override portable ZLE locale" "could not create temp dir"
        return
    }
    print -r -- 'export LC_ALL=en_US.UTF-8' > $tmp/.zshrc

    out=$(ZDOTDIR=$tmp "$LAUNCHER" -ic '
        print -r -- "LC_ALL=${LC_ALL-}"
        print -r -- "LC_CTYPE=$LC_CTYPE"
        print -r -- "LANG=$LANG"
    ' 2>&1)
    rm -f -- $tmp/.zshrc
    rmdir -- $tmp

    if [[ $out == *"LC_ALL="* && $out != *"LC_ALL=en_US.UTF-8"* &&
          $out == *"LC_CTYPE=C.utf8"* ]]; then
        pass_test "user LC_ALL cannot override portable ZLE locale"
    else
        fail_test "user LC_ALL cannot override portable ZLE locale" "got: ${(qq)out}"
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

test_default_zshrc_sh_is_packaged_and_loaded() {
    local scratch out
    if [[ ! -r $BINDIR/zshrc.sh ]]; then
        fail_test "portable zshrc.sh is packaged" "missing $BINDIR/zshrc.sh"
        return
    fi

    scratch=$BINDIR/default-zshrc-test.$$
    mkdir -p $scratch || {
        fail_test "portable zshrc.sh is loaded before user .zshrc" "could not create scratch dir $scratch"
        return
    }
    print 'print -r -- user_zshrc_ran' > $scratch/.zshrc
    out=$(ZDOTDIR=$scratch "$LAUNCHER" -i -c '
        (( $+functions[zsh_portable_fix_keys] )) && print -r -- default_zshrc_loaded
        print -r -- "prompt=$PROMPT"
        print -r -- session_ok
    ' 2>&1)
    rm -rf $scratch

    if [[ $out == *default_zshrc_loaded* &&
          $out == *"prompt=%n@%~%# "* &&
          $out == *user_zshrc_ran* &&
          $out == *session_ok* ]]; then
        pass_test "portable zshrc.sh is packaged and loaded before user .zshrc"
    else
        fail_test "portable zshrc.sh is packaged and loaded before user .zshrc" "got: ${(qq)out}"
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
# letter's hex code, e.g. vt100 -> 76/vt100; "dumb" is too limited for
# cursor-motion editing, while xterm emits active terminal queries under zpty),
# ZSH_PORTABLE_DIR/ZDOTDIR set the
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
            (( ++idle ))
            sleep 0.05
        fi
        (( ++total ))
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
    local -a spawn_cmd=(
        env LC_ALL=C.utf8 TERMINFO=$BINDIR/share/terminfo
        ZDOTDIR=$BINDIR ZSH_ORIG_ZDOTDIR=$BINDIR ZSH_PORTABLE_DIR=$BINDIR
        TERM=vt100 'PS1=%% ' $INTERP -f -i
    )
    if ! zpty $session "${spawn_cmd[@]}"; then
        fail_test "multibyte cursor/delete test setup" "could not start pty session"
        return
    fi
    zpty_drain $session >/dev/null
    zpty -w -n $session $'print -r -- __zsh_mb_ready__\r'
    local startup_buf
    startup_buf=$(zpty_drain $session 20 300)
    if [[ $startup_buf != *__zsh_mb_ready__* ]]; then
        fail_test "multibyte cursor/delete test setup" "shell did not accept a readiness command; got: ${(qq)startup_buf}"
        zpty -d $session 2>/dev/null
        return
    fi
    zpty -w -n $session "module_path=($BINDIR "'$module_path); zmodload zsh/zle; bindkey -e; bindkey -M emacs "^M" accept-line; bindkey -M emacs "^J" accept-line; bindkey -M emacs "^A" beginning-of-line; bindkey -M emacs "^F" forward-char; bindkey -M emacs "^B" backward-char; bindkey -M emacs "^?" backward-delete-char; bindkey -M emacs "^[[200~" bracketed-paste'$'\r'
    zpty_drain $session >/dev/null

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

    # Terminals wrap pasted text in bracketed-paste markers. Keep those
    # markers bound after user keymap changes so a fast paste is inserted
    # literally instead of being interpreted as editing commands.
    zpty -w -n $session $'bindkey -M emacs "^[[200~" bracketed-paste\r'
    zpty_drain $session >/dev/null
    local paste_result=$(mb_probe $session $'X=\e[200~git@github.com:raliclo/zsh.git\e[201~\r')

    zpty -d $session 2>/dev/null

    local expect_insert=$'A\xe4\xb8\xadYB'
    local expect_delete=$'AB'
    local expect_paste='git@github.com:raliclo/zsh.git'

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
    if [[ $paste_result == $expect_paste ]]; then
        pass_test "bracketed paste preserves a Git SSH URL exactly"
    else
        fail_test "bracketed paste preserves a Git SSH URL exactly" "got: ${(qq)paste_result}"
    fi
}

# --- MSYS2 bash prints "bash.exe: warning: could not find /tmp" at startup
# when its root /tmp is missing (scoop's MSYS2 does not always create it).
# compile.sh must create $MSYS2_ROOT/tmp from the OUTER shell BEFORE launching
# bash -- the TMPDIR/mkdir inside the -lc script runs after bash has already
# warned. Guard the fix two ways: the ordering in compile.sh, and (when MSYS2
# is present) that creating that /tmp does suppress the startup warning. ------
test_msys2_tmp_startup() {
    local repo
    if [[ -n $TEST_REPO_ROOT ]]; then
        repo=$TEST_REPO_ROOT
    else
        repo=${BINDIR:h:h}
    fi
    local compile=$repo/helper/compile.sh
    if [[ ! -f $compile ]]; then
        fail_test "compile.sh creates \$MSYS2_ROOT/tmp before launching bash" "compile.sh not found at $compile"
        return
    fi
    # Ordering guard: the mkdir of the MSYS2 root /tmp must come before the
    # first `"$MSYS2_BASH"` invocation of any kind, else bash warns before it
    # runs. Matching any '-' switch rather than a specific one: the build
    # script is handed over as a file ("-l <file>") rather than a -c string
    # (the cross-runtime command line truncates at ~8KB), and the /tmp probe
    # ahead of it spawns bash as "-c" -- both must come after the mkdir.
    local mkdir_ln bash_ln
    mkdir_ln=$(grep -nE 'mkdir -p "\$MSYS2_ROOT/tmp"' $compile | head -1 | cut -d: -f1)
    bash_ln=$(grep -nE '"\$MSYS2_BASH" -' $compile | head -1 | cut -d: -f1)
    if [[ -n $mkdir_ln && -n $bash_ln && $mkdir_ln -lt $bash_ln ]]; then
        pass_test "compile.sh creates \$MSYS2_ROOT/tmp before launching bash (line $mkdir_ln < $bash_ln)"
    else
        fail_test "compile.sh creates \$MSYS2_ROOT/tmp before launching bash" "mkdir line='$mkdir_ln' bash line='$bash_ln'"
    fi

    # The assembled build script must be handed to MSYS2 bash as a FILE, never
    # as a -c string. Git Bash spawning MSYS2's bash.exe crosses an
    # msys-2.0.dll boundary that silently truncates the command line at ~8KB;
    # the script is well past that, so bash would run only the prefix. It
    # surfaced as a bare "syntax error: unexpected end of file from `for'"
    # once the bundled-tool list grew, after quietly packaging a partial
    # runtime. Guarding statically because a truncated build still exits 0.
    if grep -qE '"\$MSYS2_BASH" -lc "\$_msys_build_script"' $compile; then
        fail_test "compile.sh hands the build script to bash as a file" \
            "found a -c string handover, which truncates at ~8KB"
    else
        pass_test "compile.sh hands the build script to bash as a file, not a -c string"
    fi

    # Functional check: reach MSYS2 bash through a NATIVE intermediary
    # (cmd.exe), the way a PowerShell / Git Bash / real-MSYS2 parent does --
    # the supported way to run compile.sh. That path initializes the mount
    # table cleanly, so bash must start without the /tmp warning.
    #
    # (Spawning MSYS2 bash *directly* from here would instead reproduce the
    # foreign-runtime bug: this test itself runs under the packaged zsh, whose
    # msys-2.0.dll is a different build of the same name, so its handover
    # corrupts the child's mount table and bash cannot find /tmp. That is the
    # documented limitation -- run the build from a native parent -- not
    # something compile.sh can paper over, so we don't assert on it.)
    local root=$HOME/scoop/apps/msys2/current
    [[ -e $root/usr/bin/bash.exe ]] || root=/c/msys64
    local msys_bash=$root/usr/bin/bash.exe
    if [[ ! -e $msys_bash ]]; then
        pass_test "MSYS2 bash (via native cmd.exe) starts without a /tmp warning (skipped: MSYS2 not installed)"
        return
    fi
    mkdir -p "$root/tmp" 2>/dev/null
    local warn
    warn=$(cmd /c "$msys_bash" -lc 'true' 2>&1 >/dev/null)
    if [[ $warn != *"could not find /tmp"* ]]; then
        pass_test "MSYS2 bash (via native cmd.exe) starts without a /tmp warning"
    else
        fail_test "MSYS2 bash (via native cmd.exe) starts without a /tmp warning" "got: ${(qq)warn}"
    fi
}

test_compile_runs_msys2_upgrade_helper() {
    local compile=$TEST_REPO_ROOT/helper/compile.sh
    if [[ -z $TEST_REPO_ROOT || ! -f $compile ]]; then
        fail_test "compile.sh runs the MSYS2 upgrade helper" "compile.sh not found at $compile"
        return
    fi
    if grep -q 'helper/msys2_upgrade.sh' $compile &&
       grep -q 'ZSH_SKIP_MSYS2_UPGRADE' $compile; then
        pass_test "compile.sh runs the MSYS2 upgrade helper"
    else
        fail_test "compile.sh runs the MSYS2 upgrade helper" "missing helper invocation or skip flag"
    fi
}

test_scoop_install_uses_github_release_assets() {
    local installer=$TEST_REPO_ROOT/helper/scoop_install.sh
    local manifest=$TEST_REPO_ROOT/bucket/zsh.json
    if [[ -z $TEST_REPO_ROOT || ! -f $installer || ! -f $manifest ]]; then
        fail_test "scoop install flow uses GitHub Release assets" "missing installer or manifest"
        return
    fi
    # The archive name is matched through $ARCHIVE_NAME rather than spelled
    # literally: the format moved from .zip to .tar.zst on 2026-08-29, and a
    # hardcoded name here fails the moment it moves again while saying nothing
    # about whether the Release flow is intact, which is what this test is for.
    if grep -q 'build/release' $installer $manifest 2>/dev/null ||
       grep -q 'raw\.githubusercontent.*zsh\.\(zip\|tar\)' $installer $manifest 2>/dev/null; then
        fail_test "scoop install flow uses GitHub Release assets" "found old branch/release-folder artifact reference"
    elif grep -q 'gh release' $installer &&
         grep -q '^ARCHIVE_NAME=' $installer &&
         grep -q 'build/package/\$ARCHIVE_NAME' $installer &&
         grep -q 'ZSH_RELEASE_TAG:-zsh-portable' $installer &&
         grep -q -- '--clobber' $installer &&
         grep -q '/releases/download/' $manifest; then
        pass_test "scoop install flow uses GitHub Release assets"
    else
        fail_test "scoop install flow uses GitHub Release assets" "missing GitHub Release upload or URL"
    fi
}

test_multiline_c
test_public_zsh_exe_preserves_pipe_regex
test_nested_perl_dollars_survive_with_shell_quoting
test_arithmetic_increment_is_err_exit_safe
test_pipe_in_quotes
test_embedded_quotes
test_nomatch_disabled_for_regex_args
test_script_args_not_reinterpreted
test_drive_path_modifiers
test_find_bundled
test_xargs_bundled
test_startup_cwd
test_msys_drive_prefix
test_tar_bundled
test_portable_usr_bin_tools
test_version_txt_records_bundled_tools
test_xterm_terminfo_bundled
test_bracket_tool_lookup
test_windows_exe_wrappers
test_wsl_exec_preserves_argv
test_exec_wsl_helper_preserves_argv
test_winhelp_lists_the_helpers
test_usr_bin_zsh_runs_standalone
test_taskkill_accepts_both_slash_forms
test_javascript_wrappers_preserve_slash_prefixed_argv
test_utf8_filename_roundtrip
test_user_lc_all_is_sanitized
test_modules_load
test_nested_zsh
test_user_rc_forwarding
test_default_zshrc_sh_is_packaged_and_loaded
test_path_system32_last
test_pid_is_real_winpid
test_multibyte_cursor_and_delete
test_msys2_tmp_startup
test_compile_runs_msys2_upgrade_helper
test_scoop_install_uses_github_release_assets

print
print "Results: $pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
