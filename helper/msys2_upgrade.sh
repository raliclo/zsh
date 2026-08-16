#!/bin/sh
# msys2_upgrade.sh - Refresh MSYS2 packages used by the portable zsh build.
#
# Usage:
#   sh helper/msys2_upgrade.sh [MSYS2_ROOT]
#
# This intentionally runs pacman through MSYS2 bash via a native cmd.exe
# boundary when available. Launching one MSYS runtime directly from another
# unrelated MSYS runtime can corrupt the child process mount table on Windows.
#
# This performs a FULL system upgrade (`pacman -Syu`), not a database refresh
# followed by a selective install. Refreshing the sync database with `-Sy` and
# then upgrading only a chosen package set is the classic partial-upgrade
# pattern: it can leave newer build tools and DLLs mixed with an older base
# runtime. That matters more here than in a normal install, because the build
# output is a portable runtime assembled from whatever this MSYS2 tree holds
# -- a mismatch can produce an artifact that works on the build machine by
# accident and breaks once packaged and unpacked elsewhere.
#
# The upgrade runs TWICE by design. If the first pass upgrades msys2-runtime
# itself, MSYS2 terminates every running MSYS process to complete the update,
# which can kill pacman mid-transaction; the second pass then runs against the
# freshly installed runtime and converges. This is MSYS2's own documented
# procedure, and it is why the first pass is allowed to fail without aborting.
#
# Because of that termination behaviour, run compile.sh from Git Bash,
# PowerShell or cmd -- not from an MSYS2 shell, and not through the packaged
# zsh. Those are separate runtimes, so a msys2-runtime upgrade cannot pull the
# caller out from under itself. helper/README-win.md already recommends this
# for unrelated reasons (the mount-table handover), so the requirement is not
# new.

set -e

to_msys_path() {
    case "$1" in
        [A-Za-z]:/*|[A-Za-z]:\\*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -u "$1"
            else
                drive=${1%%:*}
                case "$drive" in
                    A) drive=a ;; B) drive=b ;; C) drive=c ;; D) drive=d ;;
                    E) drive=e ;; F) drive=f ;; G) drive=g ;; H) drive=h ;;
                    I) drive=i ;; J) drive=j ;; K) drive=k ;; L) drive=l ;;
                    M) drive=m ;; N) drive=n ;; O) drive=o ;; P) drive=p ;;
                    Q) drive=q ;; R) drive=r ;; S) drive=s ;; T) drive=t ;;
                    U) drive=u ;; V) drive=v ;; W) drive=w ;; X) drive=x ;;
                    Y) drive=y ;; Z) drive=z ;;
                esac
                rest=${1#?:}
                while :; do
                    case "$rest" in
                        /*|\\*) rest=${rest#?} ;;
                        *) break ;;
                    esac
                done
                printf '/%s/%s\n' "$drive" "$(printf '%s' "$rest" | sed 's#\\#/#g')"
            fi
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

to_windows_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        case "$1" in
            /[A-Za-z]/*)
                drive=$(printf '%s' "$1" | sed 's#^/\([A-Za-z]\)/.*#\1#' | tr 'a-z' 'A-Z')
                rest=$(printf '%s' "$1" | sed 's#^/[A-Za-z]/##')
                printf '%s:/%s\n' "$drive" "$rest"
                ;;
            *)
                printf '%s\n' "$1"
                ;;
        esac
    fi
}

MSYS2_ROOT=${1:-${MSYS2_ROOT:-}}
if [ -z "$MSYS2_ROOT" ]; then
    if [ -n "${HOME:-}" ]; then
        MSYS2_ROOT="$(to_msys_path "$HOME")/scoop/apps/msys2/current"
    fi
    [ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || \
        MSYS2_ROOT="$(to_msys_path "${USERPROFILE:-}")/scoop/apps/msys2/current"
    [ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || MSYS2_ROOT=/c/msys64
fi

MSYS2_ROOT=$(to_msys_path "$MSYS2_ROOT")
MSYS2_BASH=$MSYS2_ROOT/usr/bin/bash.exe

if [ ! -x "$MSYS2_BASH" ]; then
    echo "error: MSYS2 not found at $MSYS2_ROOT" >&2
    exit 1
fi

mkdir -p "$MSYS2_ROOT/tmp"

# The two passes must be two SEPARATE process launches, not two commands in
# one script. When pacman replaces msys2-runtime it announces "all MSYS2
# processes including this terminal will be closed" and kills them -- which
# includes the very bash running the script, so anything after that line,
# `||` fallbacks included, never executes. Measured: a single script with
# both passes inside ran pass 1, swapped the runtime, died, and pass 2 never
# happened. Only the OUTER shell survives, because it is a different runtime
# (Git Bash / cmd), so it is the one that has to drive the retry.
write_upgrade_script() {
    cat > "$1" <<EOF_UPGRADE
export PATH=/usr/bin:/clang64/bin:\$PATH
pacman --noconfirm -Syu
$2
EOF_UPGRADE
}

run_upgrade_script() {
    if command -v cmd.exe >/dev/null 2>&1; then
        MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c \
            "$(to_windows_path "$MSYS2_BASH")" -l "$(to_windows_path "$1")"
    else
        "$MSYS2_BASH" -l "$1"
    fi
}

upgrade_script=$MSYS2_ROOT/tmp/zsh_msys2_upgrade.$$.sh

# Pass 1: full upgrade. Allowed to fail -- being killed mid-transaction by a
# runtime swap is the expected outcome, not an error.
echo "==> MSYS2 full upgrade (pass 1 of 2)..."
write_upgrade_script "$upgrade_script" ''
run_upgrade_script "$upgrade_script" \
    || echo "   pass 1 ended early (runtime swap); retrying in a fresh process"

# Pass 2: fresh process against the new runtime, converging the upgrade and
# only then installing what the build needs -- by now everything is on one
# consistent package set, so this can no longer mix new tools with an old base.
echo "==> MSYS2 full upgrade (pass 2 of 2)..."
write_upgrade_script "$upgrade_script" 'pacman --noconfirm -S --needed \
  gcc make autoconf automake ncurses-devel mingw-w64-clang-x86_64-clang \
  bc coreutils diffutils findutils gawk gnu-netcat grep gzip m4 make man-db ncurses \
  openssl perl procps-ng psmisc sed tar util-linux vim wget which xz'
run_upgrade_script "$upgrade_script"
rm -f "$upgrade_script"

echo "==> MSYS2 package update complete."
