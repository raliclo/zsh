#!/bin/sh
# compile.sh - Build zsh on Windows using the MSYS2 toolchain.
#
# Prerequisite: sh helper/install_build_tool.sh
#
# Usage (from Git Bash or any POSIX shell):
#   sh helper/compile.sh [-f] [source-dir]
#
# -f forces the build past a Windows ZLE patch checksum mismatch (see
# below) instead of refusing to build. Only pass this once you've
# reviewed why Src/Zle/zle.h/zle_move.c changed and either regenerated
# helper/patches/checksum.txt (helper/regen_checksum.sh) or
# confirmed the drift is fine to build over as-is; -f does not update
# checksum.txt itself, it just skips the check for this one run.
#
# This is an out-of-tree (VPATH) build: all build output lands in <repo>/build
# and is kept after the build. The resulting binary is build/Src/zsh.exe.
# Generated autotools files in the source tree (configure, config.h.in,
# autom4te.cache, ...) are removed once the build finishes, so the source
# tree stays clean.
#
# The autotools build requires LF line endings. If the source tree has been
# converted to CRLF (e.g. by core.autocrlf=true), this script builds from a
# clean detached git worktree at ../zsh-build instead of the damaged tree.

set -e

FORCE=
if [ "$1" = "-f" ]; then
    FORCE=1
    shift
fi

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="${1:-$REPO}"
BUILD="$REPO/build"

to_msys_path() {
    case "$1" in
        [A-Za-z]:/*|[A-Za-z]:\\*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -u "$1"
            else
                drive=$(printf '%s' "$1" | sed 's#^\([A-Za-z]\):.*#\1#' | tr 'A-Z' 'a-z')
                rest=$(printf '%s' "$1" | sed 's#^[A-Za-z]:[/\\]*##; s#\\#/#g')
                printf '/%s/%s\n' "$drive" "$rest"
            fi
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

MSYS2_ROOT="$HOME/scoop/apps/msys2/current"
[ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || MSYS2_ROOT="$(to_msys_path "$USERPROFILE")/scoop/apps/msys2/current"
[ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || MSYS2_ROOT="/c/msys64"
MSYS2_BASH="$MSYS2_ROOT/usr/bin/bash.exe"

if [ ! -x "$MSYS2_BASH" ]; then
    echo "error: MSYS2 not found; run helper/install_build_tool.sh first" >&2
    exit 1
fi

# --- Guard against CRLF-damaged checkouts ----------------------------------
if [ -f "$SRC/configure.ac" ] && grep -q "$(printf '\r')" "$SRC/configure.ac"; then
    echo "==> Source tree has CRLF line endings; using clean worktree ../zsh-build"
    WT="$SRC/../zsh-build"
    if [ ! -d "$WT" ]; then
        git -C "$SRC" worktree add --detach "$WT" HEAD
    fi
    SRC=$(cd "$WT" && pwd)
fi

SRC_MSYS=$(to_msys_path "$SRC")
BUILD_MSYS=$(to_msys_path "$BUILD")

echo "==> Source tree:  $SRC"
echo "==> Build output: $BUILD"
mkdir -p "$BUILD" 2>/dev/null || mkdir -p "$BUILD_MSYS"

# --- Apply the Windows-specific ZLE fix (reverted after the build below) ----
# Windows/Cygwin's 16-bit wchar_t stores a character outside the Basic
# Multilingual Plane (most emoji) as a UTF-16 surrogate pair -- two
# consecutive ZLE_CHAR_T units -- instead of one. Without this patch, ZLE
# cursor movement and character deletion treat the two halves as separate
# characters, landing the cursor in the middle of the pair. Applied as a
# build-time patch rather than a permanent source change so the tree stays
# clean for merging upstream zsh changes.
#
# The patch's context lines only make sense against the exact pristine
# source it was written against; if a future upstream sync changes these
# files, 'git apply' could still succeed via fuzzy matching and silently
# produce something subtly wrong. Guard against that by checksumming the
# pristine files first (helper/patches/checksum.txt) and refusing to
# build at all if they've drifted, rather than build with a patch that
# may not mean what it says.
ZLE_PATCH="$REPO/helper/patches/windows-zle-surrogate-pairs.patch"
ZLE_CHECKSUMS="$REPO/helper/patches/checksum.txt"
if [ -f "$ZLE_PATCH" ] && ! grep -q ZSH_IS_HIGH_SURROGATE "$SRC/Src/Zle/zle.h" 2>/dev/null; then
    # Comments stripped before checking: not all sha256sum implementations
    # skip '#' lines in --check mode (GNU coreutils does; some don't and
    # report each as a bogus FAILED entry).
    if ! ( cd "$SRC" && grep -v '^#' "$ZLE_CHECKSUMS" | sha256sum -c - ) >/dev/null 2>&1; then
        if [ -n "$FORCE" ]; then
            echo "warning: Src/Zle/zle.h and/or Src/Zle/zle_move.c no longer match" >&2
            echo "         helper/patches/checksum.txt; building anyway (-f). The ZLE" >&2
            echo "         patch below may not apply cleanly, or may apply but no" >&2
            echo "         longer mean what its comments say. Run" >&2
            echo "         helper/regen_checksum.sh once you've confirmed the" >&2
            echo "         patch is still correct." >&2
        else
            echo "error: Src/Zle/zle.h and/or Src/Zle/zle_move.c no longer match the" >&2
            echo "       versions helper/patches/windows-zle-surrogate-pairs.patch was" >&2
            echo "       written against (see helper/patches/checksum.txt). Refusing to" >&2
            echo "       build until the patch is reviewed and checksum.txt updated" >&2
            echo "       (helper/regen_checksum.sh), or rerun with -f to build" >&2
            echo "       past this check once." >&2
            exit 1
        fi
    fi
    echo "==> Applying Windows ZLE surrogate-pair patch..."
    git -C "$SRC" apply "$ZLE_PATCH"
fi

# --- preconfig, configure (in build/), make ---------------------------------
"$MSYS2_BASH" -lc "
    set -e
    export PATH=/usr/bin:\$PATH
    export TMPDIR='$BUILD_MSYS/tmp'
    mkdir -p \"\$TMPDIR\"
    cd '$SRC_MSYS'

    # a leftover in-tree build breaks VPATH builds; clear it first
    if [ -f config.status ]; then
        echo '==> Removing leftover in-tree build (make distclean)...'
        make distclean >/dev/null 2>&1 || true
    fi

    if [ ! -f configure ]; then
        echo '==> Generating configure (Util/preconfig)...'
        ./Util/preconfig
    fi

    cd '$BUILD_MSYS'
    # re-run configure serially if it was regenerated, otherwise parallel
    # sub-makes race to reconfigure and corrupt each other's conftest files
    if [ ! -f config.status ] || [ '$SRC_MSYS/configure' -nt config.status ]; then
        echo '==> Running configure (out-of-tree)...'
        # config.guess reports mingw32, not cygwin, so configure picks bare
        # ld for module linking; modern binutils then exports no symbols and
        # configure silently disables dynamic modules. Preset the link
        # command the cygwin branch would use. (Do not add a libzsh
        # reference here: configure's own dlopen self-test links a throwaway
        # conftest with these exact flags, and a glob with no match at that
        # point makes the test fail, silently disabling dynamic modules
        # entirely instead of just this one module.)
        DLLD=gcc DLLDFLAGS='-shared -Wl,--export-all-symbols' \
            '$SRC_MSYS/configure' --prefix=/usr/local
    fi

    echo '==> Running make (first pass, modules expected to fail here)...'
    # The per-directory module Makefiles (Src/Builtins, Src/Modules, Src/Zle)
    # do not exist until make generates them on this first pass, so the
    # libzsh-linking patch below cannot be applied any earlier. Unlike
    # genuine Cygwin's ld, MSYS2's cygwin-target ld does not tolerate
    # unresolved symbols in a -shared build, so this first pass is expected
    # to fail once it reaches module linking (e.g. rlimits.so).
    make -j\$(nproc) || true

    # Each module's link recipe references its NOLINKMODS_<mod> variable
    # -- always blank -- instead of LINKMODS_<mod>, which mkmakemod.sh
    # always fills in with the module's real dependencies (libzsh, plus any
    # other module it declares via moddeps=, e.g. zsh/ksh93 needs
    # zsh/zle for varedarg/curkeymapname). configure.ac only picks
    # LINKMODS when host_os = cygwin; config.guess reports mingw32 here,
    # so it falls through to the NOLINKMODS default meant for platforms
    # whose dynamic loader resolves inter-module symbols lazily at
    # dlopen time. MSYS2's cygwin-target ld does not, so those symbols
    # are unresolved at link time instead, breaking the build. Point the
    # recipes at LINKMODS_ instead so dependencies actually get linked.
    for mod_makefile in Src/Builtins/Makefile Src/Modules/Makefile Src/Zle/Makefile; do
        if [ -f \"\$mod_makefile\" ] && grep -q '\$(NOLINKMODS_' \"\$mod_makefile\"; then
            sed -i 's/\$(NOLINKMODS_/\$(LINKMODS_/g' \"\$mod_makefile\"
        fi
    done

    echo '==> Running make (second pass, with libzsh linking patched in)...'
    make -j\$(nproc)

    # --- Assemble a portable runtime in build/bin ---------------------------
    # zsh.exe (the real interpreter) + libzsh + loadable modules + the
    # MSYS2 runtime DLLs they need, so the result runs from any shell
    # (Git Bash, cmd, ...) without MSYS2 on PATH. It's installed as
    # native launcher compiled below is named zsh-loader.exe; it does env
    # setup and then forwards to the real zsh.exe -- see that step for why.
    # Modules go in
    # bin/zsh/ because module 'zsh/foo' is looked up as
    # <module_path>/zsh/foo.\$DL_EXT. Read DL_EXT from the Makefile that
    # was actually just built with, rather than hardcoding .so or .dll:
    # whether configure's host_os check lands on the cygwin branch
    # (DL_EXT=dll) or falls through to the generic-ELF branch (DL_EXT=so)
    # depends on how config.guess reads the MSYS2 toolchain, which has
    # flipped between runs on the same machine (an MSYS2 update changes
    # what 'uname' reports).
    echo '==> Assembling portable runtime in build/bin...'
    cd '$BUILD_MSYS'
    DL_EXT=\$(sed -n 's/^DL_EXT[[:space:]]*=[[:space:]]*//p' Src/Makefile | head -1)
    rm -rf bin
    mkdir -p bin
    cp Src/zsh.exe bin/zsh.exe
    cp Src/libzsh-*.\$DL_EXT bin/

    sed -n 's/^name=\([^ ]*\).* modfile=\([^ ]*\).* link=dynamic .*/\1 \2/p' config.modules \\
        | while read -r modname modfile; do
            src=\"\${modfile%.mdd}.\$DL_EXT\"
            dll=\"\${modfile##*/}\"
            dll=\"\${dll%.mdd}.\$DL_EXT\"
            dest=\"bin/\$modname.\$DL_EXT\"
            if [ -f \"\$src\" ]; then
                mkdir -p \"\$(dirname \"\$dest\")\"
                cp \"\$src\" \"\$dest\"
            else
                echo \"warning: expected module not found: \$src\" >&2
            fi
        done

    { ldd Src/zsh.exe; find Src -name \"*.\$DL_EXT\" -exec ldd {} +; } 2>/dev/null \\
        | awk '/=> \/usr\/bin\/msys-/ { print \$3 }' | sort -u \\
        | while read -r dll; do cp \"\$dll\" bin/; done

    if command -v tput.exe >/dev/null 2>&1; then
        cp \"\$(command -v tput.exe)\" bin/
    fi
    if [ -d /usr/share/terminfo ]; then
        mkdir -p bin/share
        cp -R /usr/share/terminfo bin/share/
    fi

    # Bundle real GNU findutils binaries the portable runtime needs but
    # doesn't build itself: find (Windows ships its own incompatible
    # C:\\Windows\\System32\\find.exe that would otherwise shadow it --
    # zsh.cmd's PATH reordering only helps once a real one is here to
    # find) and xargs (Windows ships none at all, so it would simply be
    # missing on a machine without MSYS2/Git on PATH).
    for tool in find xargs; do
        if command -v \$tool.exe >/dev/null 2>&1; then
            tool_exe=\"\$(command -v \$tool.exe)\"
            cp \"\$tool_exe\" bin/
            ldd \"\$tool_exe\" 2>/dev/null \\
                | awk '/=> \/usr\/bin\/msys-/ { print \$3 }' \\
                | while read -r dll; do cp \"\$dll\" bin/; done
        fi
    done

    # zsh.cmd can only be run via cmd.exe's own batch-file parser, which
    # re-tokenizes the incoming command line before this script ever runs:
    # it truncates a multi-line -c argument at the first embedded newline,
    # and can leak '|' and other metacharacters out of what looks like a
    # quoted string. Neither is fixable from inside zsh.cmd -- the
    # corruption happens before any of its lines execute. This launcher is
    # a real PE binary, so argv reaches zsh.exe unmodified; package it as
    # zsh-loader.exe and let the Scoop shim named zsh point at it.
    echo '==> Compiling native launcher (bin/zsh-loader.exe -> zsh.exe)...'
    gcc -O2 -o bin/zsh-loader.exe '$SRC_MSYS/helper/zsh_launcher.c'
"

# --- Portable launcher + zsh bootstrap --------------------------------------
# Written here (outer script), not inside the MSYS2 -lc "..." string above:
# these heredocs contain literal double quotes, which would otherwise close
# that outer double-quoted string early and mangle everything after it.
cat > "$BUILD/bin/zsh.cmd" <<'EOF_CMD'
@echo off
setlocal EnableDelayedExpansion
set "ZSH_PORTABLE_DIR=%~dp0"
set "ZSH_WIN_HOME=%USERPROFILE%"
set "ZSH_TERMINFO_DIR=%ZSH_PORTABLE_DIR:\=/%share/terminfo"
set "ZSH_TERMINFO_DRIVE=%ZSH_TERMINFO_DIR:~0,1%"
set "ZSH_TERMINFO_PATH=%ZSH_TERMINFO_DIR:~2%"
set "TERMINFO=/cygdrive/%ZSH_TERMINFO_DRIVE%%ZSH_TERMINFO_PATH%"

rem Switch the console to UTF-8 (65001) so zsh's UTF-8 output and typed
rem multibyte input round-trip correctly; without this, a console left on
rem a legacy code page (still common unless "Beta: Use Unicode UTF-8" is
rem enabled system-wide) shows mojibake instead of e.g. CJK text or emoji.
rem Save the current code page first and restore it on exit below, so it
rem doesn't leak into the parent cmd/PowerShell session once zsh quits.
for /f "tokens=2 delims=:" %%P in ('chcp') do set "_ZSH_ORIG_CP=%%P"
set "_ZSH_ORIG_CP=%_ZSH_ORIG_CP: =%"
chcp 65001 >nul

rem Prepend the portable dir, then push the Windows system directories to
rem the very end of PATH. Those ship their own find/sort/more/where/... with
rem non-POSIX behavior; left in their normal (early) position they shadow
rem the real tools zsh expects -- e.g. Windows' find.exe instead of the GNU
rem find bundled next to zsh.exe -- no matter what else is on PATH.
set "PATH=%ZSH_PORTABLE_DIR%;%PATH%"
set "_ZSH_SYS32=%SystemRoot%\System32"
set "_ZSH_SYSWOW=%SystemRoot%\SysWOW64"
set "_ZSH_WINDIR=%SystemRoot%"
set "PATH=!PATH:%_ZSH_SYS32%;=!"
set "PATH=!PATH:%_ZSH_SYSWOW%;=!"
set "PATH=!PATH:%_ZSH_WINDIR%;=!"
set "PATH=!PATH!;%_ZSH_SYS32%;%_ZSH_SYSWOW%;%_ZSH_WINDIR%"
set "_ZSH_SYS32="
set "_ZSH_SYSWOW="
set "_ZSH_WINDIR="

if defined ZDOTDIR (
    set "ZSH_ORIG_ZDOTDIR=%ZDOTDIR%"
) else (
    set "ZSH_ORIG_ZDOTDIR=%USERPROFILE%"
)
set "ZDOTDIR=%ZSH_PORTABLE_DIR%"

rem %* is passed through to zsh.exe as-is below; disable delayed expansion
rem first so a literal "!" in a forwarded argument survives untouched.
rem (zsh.exe, not zsh-loader.exe: this script already does the same env setup
rem the native launcher does, so it calls the real interpreter directly.)
setlocal DisableDelayedExpansion
"%ZSH_PORTABLE_DIR%zsh.exe" %*
set "_ZSH_EXIT=%ERRORLEVEL%"
if defined _ZSH_ORIG_CP chcp %_ZSH_ORIG_CP% >nul
exit /b %_ZSH_EXIT%
EOF_CMD

# for /f (used above to read back the current code page) requires CRLF line
# endings to parse correctly in cmd.exe; the heredoc above wrote plain LF.
sed -i 's/$/\r/' "$BUILD/bin/zsh.cmd"

cat > "$BUILD/bin/.zshenv" <<'EOF_ZSHENV'
zsh_portable_dir=${ZSH_PORTABLE_DIR:-}
if [[ -n $zsh_portable_dir ]]; then
  zsh_portable_dir=${zsh_portable_dir//\\//}
  zsh_portable_dir=${zsh_portable_dir%/}
  if [[ $zsh_portable_dir == [A-Za-z]:/* ]]; then
    zsh_portable_dir="/cygdrive/${(L)zsh_portable_dir[1]}/${zsh_portable_dir[4,-1]}"
  fi
  module_path=("$zsh_portable_dir" $module_path)
  TERMINFO="$zsh_portable_dir/share/terminfo"
  export TERMINFO
fi
if [[ -n ${ZSH_WIN_HOME:-} ]]; then
  HOME=${ZSH_WIN_HOME//\\//}
  export HOME
fi
if [[ -o interactive ]]; then
  PROMPT="%n@%~%# "
  zsh_portable_fix_keys() {
    local zsh_portable_keymap
    for zsh_portable_keymap in main emacs viins; do
      bindkey -M "$zsh_portable_keymap" "^?" backward-delete-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^H" backward-delete-char 2>/dev/null
    done
    stty erase "^?" 2>/dev/null || stty erase "^H" 2>/dev/null
  }
  precmd_functions=(${precmd_functions:#zsh_portable_fix_keys} zsh_portable_fix_keys)
fi

if [[ -n ${ZSH_ORIG_ZDOTDIR:-} ]]; then
  zsh_orig_zdotdir=${ZSH_ORIG_ZDOTDIR//\\//}
  ZDOTDIR=$zsh_orig_zdotdir
  export ZDOTDIR
  if [[ $ZDOTDIR != $zsh_portable_dir && -r $ZDOTDIR/.zshenv ]]; then
    source $ZDOTDIR/.zshenv
  fi
  unset ZSH_ORIG_ZDOTDIR ZSH_PORTABLE_DIR ZSH_WIN_HOME zsh_portable_dir zsh_orig_zdotdir
fi
EOF_ZSHENV

# --- Stamp the build: zsh version + source commit ---------------------------
{
    "$BUILD/bin/zsh.cmd" --version
    git -C "$SRC" log -1 --format='%H'
} > "$BUILD/bin/version.txt"
echo "==> version.txt:"
cat "$BUILD/bin/version.txt"

# --- Clean generated files out of the source tree; keep build/ --------------
echo "==> Cleaning generated files from source tree..."
rm -rf "$SRC/autom4te.cache"
rm -f "$SRC/configure" "$SRC/config.h.in" "$SRC/stamp-h.in" "$SRC/META-FAQ"
if [ -f "$ZLE_PATCH" ] && grep -q ZSH_IS_HIGH_SURROGATE "$SRC/Src/Zle/zle.h" 2>/dev/null; then
    echo "==> Reverting Windows ZLE surrogate-pair patch..."
    git -C "$SRC" apply -R "$ZLE_PATCH"
fi

echo "==> Build complete. Output kept in: $BUILD"
echo "==> Portable runtime: $BUILD/bin"
echo "==>   zsh.cmd        - interactive launcher for cmd.exe / double-click"
echo "==>   zsh-loader.exe - native launcher for programmatic callers (preserves argv exactly)"
echo "==>   zsh.exe        - the real interpreter zsh.cmd/zsh-loader.exe both forward to"
"$BUILD/bin/zsh.cmd" --version
echo "==> For dynamic modules (zle etc.) outside MSYS2, run $BUILD/bin/zsh.cmd or zsh-loader.exe"
