#!/bin/sh
# msys2_scoop_shims.sh - repoint selected Scoop shims to MSYS2 executables.
#
# This repairs shims left behind by packages such as busybox after uninstall,
# while keeping Scoop's shim runner .exe files in place. It writes only the
# companion .shim metadata files and .cmd boundary wrappers under ~/scoop/shims.
#
# Usage:
#   sh helper/msys2_scoop_shims.sh
#   sh helper/msys2_scoop_shims.sh diff grep sed awk sort find tar bash
#   sh helper/msys2_scoop_shims.sh dirname date mv head tr cut sha256sum sh which mkdir
#   sh helper/msys2_scoop_shims.sh autoconf autom4te autoheader autoreconf m4 perl

# Keep this script POSIX-style, but intentionally avoid external basics such
# as dirname/sed/chmod/cygpath: this helper is meant to repair broken shims,
# and those names may currently point at stale shims.
#
# Do not point Scoop shim metadata directly at MSYS2 executables. Launching
# "Scoop shim -> MSYS2 exe" from this portable zsh crosses between two
# Cygwin/MSYS runtime families and can fail before main() with
# "couldn't create signal pipe". Point the shim at native cmd.exe instead,
# then let cmd.exe start the MSYS2 tool from a tiny .cmd wrapper.

set -e

if [ "$#" -eq 0 ]; then
    # Use positional parameters for the default list. zsh does not split
    # scalar variables on spaces by default, so TOOLS="diff grep ..." would
    # become one literal tool name when this helper is sourced from zsh.
    set -- '[' ar arch ash awk base32 base64 basename bash cal cat chattr \
        chmod cksum clear cmp comm cp cut date dd df diff dirname du env file \
        echo expand expr factor false find flock fold getopt grep groups gzip \
        head hexdump id install join kill killall less link ln locale logname ls \
        lsattr lzcat lzma m4 make man md5sum mkdir mktemp mv nl nproc od \
        nc openssl paste perl pgrep pidof pkill printenv printf ps pwd readlink realpath reset rev rm \
        rmdir sed seq sh sha1sum sha256sum sha384sum sha512sum shred shuf \
        sleep sort split stat strings stty sum sync tac tail tar tee test \
        time timeout touch tr true truncate tset tsort uname unexpand uniq \
        unlink unlzma unxz uuidgen wc wget which whoami xargs xxd xzcat yes \
        infocmp tput \
        autoconf autoconf-2.13 autoconf-2.69 autoconf-2.71 autoconf-2.72 \
        autoconf-2.73 autoheader autoheader-2.13 autoheader-2.69 \
        autoheader-2.71 autoheader-2.72 autoheader-2.73 autom4te \
        autom4te-2.69 autom4te-2.71 autom4te-2.72 autom4te-2.73 \
        autoreconf autoreconf-2.13 autoreconf-2.69 autoreconf-2.71 \
        autoreconf-2.72 autoreconf-2.73 autoscan autoscan-2.13 \
        autoscan-2.69 autoscan-2.71 autoscan-2.72 autoscan-2.73 \
        autoupdate autoupdate-2.13 autoupdate-2.69 autoupdate-2.71 \
        autoupdate-2.72 autoupdate-2.73 ifnames ifnames-2.13 \
        ifnames-2.69 ifnames-2.71 ifnames-2.72 ifnames-2.73
fi

scoop_home() {
    if [ -n "${SCOOP:-}" ]; then
        printf '%s\n' "$SCOOP"
        return 0
    fi
    printf '%s\n' "$HOME/scoop"
}

# Case-mapped with a case statement rather than `tr`: to_windows_path runs
# once per shimmed tool, and this script's whole point is that external
# basics may be broken shims -- spawning one per call is both a dependency
# it does not need and, on Windows, a per-process cost paid ~150 times.
upper_drive() {
    case "$1" in
        a) printf 'A\n' ;; b) printf 'B\n' ;; c) printf 'C\n' ;; d) printf 'D\n' ;;
        e) printf 'E\n' ;; f) printf 'F\n' ;; g) printf 'G\n' ;; h) printf 'H\n' ;;
        i) printf 'I\n' ;; j) printf 'J\n' ;; k) printf 'K\n' ;; l) printf 'L\n' ;;
        m) printf 'M\n' ;; n) printf 'N\n' ;; o) printf 'O\n' ;; p) printf 'P\n' ;;
        q) printf 'Q\n' ;; r) printf 'R\n' ;; s) printf 'S\n' ;; t) printf 'T\n' ;;
        u) printf 'U\n' ;; v) printf 'V\n' ;; w) printf 'W\n' ;; x) printf 'X\n' ;;
        y) printf 'Y\n' ;; z) printf 'Z\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# The .cmd wrappers and .shim metadata written below are read by native
# cmd.exe, which cannot resolve POSIX drive paths. Run from Git Bash or MSYS2
# -- where $HOME is typically /c/Users/... -- the paths derived from it must
# therefore be converted, or the "repaired" shim fails at execution time with
# a path that looks perfectly reasonable in the file.
#
# Forward slashes are kept rather than converted to backslashes: scoop shim
# metadata accepts C:/... and it avoids zsh interpreting sequences like \u
# and \a in the paths that pass through it.
to_windows_path() {
    case "$1" in
        [A-Za-z]:/*|[A-Za-z]:\\*)
            # Already Windows-form.
            printf '%s\n' "$1"
            ;;
        /mnt/[A-Za-z]/*|/mnt/[A-Za-z])
            _twp_rest=${1#/mnt/?}
            _twp_drive=${1#/mnt/}
            _twp_drive=${_twp_drive%%/*}
            printf '%s:%s\n' "$(upper_drive "$_twp_drive")" "${_twp_rest:-/}"
            ;;
        /[A-Za-z]/*|/[A-Za-z])
            _twp_rest=${1#/?}
            _twp_drive=${1#/}
            _twp_drive=${_twp_drive%%/*}
            printf '%s:%s\n' "$(upper_drive "$_twp_drive")" "${_twp_rest:-/}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

cmd_exe_path() {
    if [ -n "${COMSPEC:-}" ]; then
        printf '%s\n' "$COMSPEC"
        return 0
    fi
    if [ -n "${SystemRoot:-}" ]; then
        printf '%s\n' "$SystemRoot/System32/cmd.exe"
        return 0
    fi
    printf '%s\n' 'C:/Windows/System32/cmd.exe'
}

SCOOP_HOME=$(scoop_home)
MSYS2_ROOT="${MSYS2_ROOT:-$SCOOP_HOME/apps/msys2/current}"
MSYS2_BIN="$MSYS2_ROOT/usr/bin"
SHIM_DIR="$SCOOP_HOME/shims"
CMD_EXE=$(to_windows_path "$(cmd_exe_path)")

[ -d "$MSYS2_BIN" ] || {
    echo "error: MSYS2 bin directory not found: $MSYS2_BIN" >&2
    echo "       install msys2 with scoop first, or set MSYS2_ROOT" >&2
    exit 1
}
[ -d "$SHIM_DIR" ] || {
    echo "error: Scoop shim directory not found: $SHIM_DIR" >&2
    exit 1
}

echo "MSYS2 bin: $MSYS2_BIN"
echo "Scoop shims: $SHIM_DIR"

shim_runner_template=
for candidate in sh bash grep xxd nc; do
    if [ -f "$SHIM_DIR/$candidate.exe" ]; then
        shim_runner_template="$SHIM_DIR/$candidate.exe"
        break
    fi
done

for tool do
    src="$MSYS2_BIN/$tool.exe"
    src_kind=exe
    if [ ! -x "$src" ]; then
        src="$MSYS2_BIN/$tool"
        src_kind=script
    fi
    shim="$SHIM_DIR/$tool.shim"
    wrapper="$SHIM_DIR/$tool-msys2.cmd"
    compat_script="$SHIM_DIR/$tool-msys2.sh"
    ps_wrapper="$SHIM_DIR/$tool-msys2.ps1"
    runner="$SHIM_DIR/$tool.exe"

    if [ ! -x "$src" ] && [ "$tool" = pgrep ] &&
        [ -x "$MSYS2_BIN/sh.exe" ] && [ -x "$MSYS2_BIN/ps.exe" ] &&
        [ -x "$MSYS2_BIN/awk.exe" ]; then
        src="$compat_script"
        src_kind=compat_pgrep
        {
            printf '#!/bin/sh\n'
            printf 'case "${1:-}" in\n'
            printf '    ""|-*) echo "usage: pgrep PATTERN" >&2; exit 2 ;;\n'
            printf 'esac\n'
            printf 'pat=$1\n'
            printf '"%s/ps.exe" -W | "%s/awk.exe" -v pat="$pat" '\''\n' "$MSYS2_BIN" "$MSYS2_BIN"
            printf 'NR > 1 {\n'
            printf '    winpid = $4\n'
            printf '    command = ""\n'
            printf '    for (i = 8; i <= NF; i++) command = command (i == 8 ? "" : " ") $i\n'
            printf '    if (command ~ pat) { print winpid; found = 1 }\n'
            printf '}\n'
            printf 'END { exit found ? 0 : 1 }\n'
            printf '\047\n'
        } > "$compat_script"
    fi

    if [ ! -x "$src" ] && [ "$src_kind" != compat_pgrep ]; then
        echo "skip: $tool (missing $MSYS2_BIN/$tool.exe or $MSYS2_BIN/$tool)" >&2
        continue
    fi
    if [ ! -f "$runner" ]; then
        if [ -n "$shim_runner_template" ]; then
            # Prefer "$MSYS2_BIN/cp.exe" over a bare cp: this script repairs
            # broken Scoop shims, and 'cp' is itself one of the tools it
            # shims, so a bare cp resolves through PATH and could be the very
            # broken shim being repaired -- failing partway through fixing
            # the thing it needs.
            #
            # Tested with -s, not -x: a zero-byte cp.exe is executable by
            # Windows' rules but hangs rather than failing when run, so an
            # -x test would trade a clear error for a stall.
            if [ -s "$MSYS2_BIN/cp.exe" ]; then
                "$MSYS2_BIN/cp.exe" "$shim_runner_template" "$runner"
            else
                cp "$shim_runner_template" "$runner"
            fi
        else
            echo "skip: $tool (missing Scoop shim runner $runner)" >&2
            continue
        fi
    fi

    src_win=$(to_windows_path "$src")
    sh_win=$(to_windows_path "$MSYS2_BIN/sh.exe")
    msys2_bin_win=$(to_windows_path "$MSYS2_BIN")
    {
        printf '@echo off\r\n'
        printf 'setlocal\r\n'
        printf 'set "MSYS2_BIN=%s"\r\n' "$msys2_bin_win"
        printf 'set "PATH=%%MSYS2_BIN%%;%%PATH%%"\r\n'
        printf 'set "CHERE_INVOKING=1"\r\n'
        printf 'set "MSYS2_ARG_CONV_EXCL=*"\r\n'
        if [ "$src_kind" = script ] || [ "$src_kind" = compat_pgrep ]; then
            printf '"%s" "%s" %%*\r\n' "$sh_win" "$src_win"
        else
            printf '"%s" %%*\r\n' "$src_win"
        fi
        printf 'exit /b %%ERRORLEVEL%%\r\n'
    } > "$wrapper"
    {
        printf 'path = "%s"\n' "$CMD_EXE"
        # Do not quote the wrapper path here. Scoop appends user arguments
        # after this static args string; `cmd /c "wrapper" "arg"` treats the
        # second quote as part of command parsing and can turn quote-heavy sed
        # expressions into a broken command name. The Scoop shim directory has
        # no spaces in the supported layout, so an unquoted wrapper path keeps
        # the appended arguments outside the command name.
        printf 'args = /d /c %s\n' "$(to_windows_path "$wrapper")"
    } > "$shim"
    if [ -f "$ps_wrapper" ]; then
        {
            printf '# This legacy PowerShell wrapper is intentionally disabled.\n'
            printf '# Use the matching .shim -> .cmd wrapper generated by msys2_scoop_shims.sh.\n'
            printf 'Write-Error "Use the Scoop shim runner for %s, not %s directly."\n' "$tool" "$tool-msys2.ps1"
            printf 'exit 1\n'
        } > "$ps_wrapper"
    fi
    echo "ok: $tool -> cmd.exe -> $src_win"
done

if [ "${MSYS2_SCOOP_SHIMS_NO_VERIFY:-0}" != 1 ]; then
    echo
    echo "Verification:"
    for tool do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '%s -> %s\n' "$tool" "$(command -v "$tool")"
        fi
    done
fi
