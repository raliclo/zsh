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
# Do not run a full `pacman -Syu` from compile.sh. If msys2-runtime itself is
# upgraded, MSYS2 terminates every running MSYS process to complete the update,
# including the shell executing compile.sh. This helper refreshes package
# databases and upgrades/installs only the packages required by this portable
# build. Run a full MSYS2 system upgrade manually as a separate maintenance
# step, then start a fresh compile.

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

upgrade_script=$MSYS2_ROOT/tmp/zsh_msys2_upgrade.$$.sh
cat > "$upgrade_script" <<'EOF_UPGRADE'
set -e
export PATH=/usr/bin:/clang64/bin:$PATH
pacman --noconfirm -Sy
pacman --noconfirm -S --needed \
  gcc make autoconf automake ncurses-devel mingw-w64-clang-x86_64-clang \
  bc coreutils diffutils findutils gawk gnu-netcat grep gzip m4 make man-db ncurses \
  openssl perl procps-ng psmisc sed tar util-linux vim wget which xz
EOF_UPGRADE

echo "==> Updating MSYS2 packages for zsh build..."
if command -v cmd.exe >/dev/null 2>&1; then
    MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "$(to_windows_path "$MSYS2_BASH")" -l "$(to_windows_path "$upgrade_script")"
else
    "$MSYS2_BASH" -l "$upgrade_script"
fi
rm -f "$upgrade_script"

echo "==> MSYS2 package update complete."
