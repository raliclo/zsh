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
        chmod cksum clear cmp comm cp cut date dd df diff dirname du env \
        expand expr factor false find flock fold getopt grep groups gzip \
        head hexdump id install join kill less link ln logname ls lsattr \
        lzcat lzma make man md5sum mkdir mktemp mv nl nproc od paste \
        printenv ps pwd readlink realpath reset rev rm rmdir sed seq sh \
        sha1sum sha256sum sha384sum sha512sum shred shuf sleep sort split \
        stat strings stty sum sync tac tail tar tee test time timeout touch \
        tr true truncate tsort uname unexpand uniq unlink unlzma unxz \
        uuidgen wc wget which whoami xargs xzcat yes
fi

scoop_home() {
    if [ -n "${SCOOP:-}" ]; then
        printf '%s\n' "$SCOOP"
        return 0
    fi
    printf '%s\n' "$HOME/scoop"
}

to_windows_path() {
    case "$1" in
        [A-Za-z]:/*)
            # Scoop shim metadata accepts C:/... paths; keep forward slashes
            # to avoid zsh interpreting backslash sequences like \u and \a.
            printf '%s\n' "$1"
            ;;
        [A-Za-z]:\\*)
            printf '%s\n' "$1"
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

for tool do
    src="$MSYS2_BIN/$tool.exe"
    shim="$SHIM_DIR/$tool.shim"
    wrapper="$SHIM_DIR/$tool-msys2.cmd"
    runner="$SHIM_DIR/$tool.exe"

    if [ ! -x "$src" ]; then
        echo "skip: $tool (missing $src)" >&2
        continue
    fi
    if [ ! -f "$runner" ]; then
        echo "skip: $tool (missing Scoop shim runner $runner)" >&2
        continue
    fi

    src_win=$(to_windows_path "$src")
    {
        printf '@echo off\r\n'
        printf 'setlocal\r\n'
        printf 'set "MSYS2_ARG_CONV_EXCL=*"\r\n'
        printf '"%s" %%*\r\n' "$src_win"
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
    echo "ok: $tool -> cmd.exe -> $src_win"
done

echo
echo "Verification:"
for tool do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '%s -> %s\n' "$tool" "$(command -v "$tool")"
    fi
done
