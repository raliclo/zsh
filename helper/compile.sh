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
        /mnt/[A-Za-z]/*)
            drive=${1#/mnt/}
            drive=${drive%%/*}
            rest=${1#/mnt/?/}
            case "$drive" in
                A) drive=a ;; B) drive=b ;; C) drive=c ;; D) drive=d ;;
                E) drive=e ;; F) drive=f ;; G) drive=g ;; H) drive=h ;;
                I) drive=i ;; J) drive=j ;; K) drive=k ;; L) drive=l ;;
                M) drive=m ;; N) drive=n ;; O) drive=o ;; P) drive=p ;;
                Q) drive=q ;; R) drive=r ;; S) drive=s ;; T) drive=t ;;
                U) drive=u ;; V) drive=v ;; W) drive=w ;; X) drive=x ;;
                Y) drive=y ;; Z) drive=z ;;
            esac
            printf '/%s/%s\n' "$drive" "$rest"
            ;;
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
                out=
                while :; do
                    case "$rest" in
                        *\\*)
                            out=$out${rest%%\\*}/
                            rest=${rest#*\\}
                            ;;
                        *)
                            out=$out$rest
                            break
                            ;;
                    esac
                done
                rest=$out
                printf '/%s/%s\n' "$drive" "$rest"
            fi
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Forward-slash Windows form (C:/foo/bar), which both cmd.exe and MSYS2 bash
# accept -- used when relaunching bash through cmd.exe (see the /tmp handover
# workaround below).
to_windows_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1" | sed 's#^/\([A-Za-z]\)/#\1:/#'
    fi
}

MSYS2_HOME=$(to_msys_path "$HOME")
MSYS2_ROOT="$MSYS2_HOME/scoop/apps/msys2/current"
[ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || MSYS2_ROOT="$(to_msys_path "$USERPROFILE")/scoop/apps/msys2/current"
[ -x "$MSYS2_ROOT/usr/bin/bash.exe" ] || MSYS2_ROOT="/c/msys64"
MSYS2_BASH="$MSYS2_ROOT/usr/bin/bash.exe"
MSYS2_USR_BIN="$MSYS2_ROOT/usr/bin"

if [ ! -x "$MSYS2_BASH" ]; then
    echo "error: MSYS2 not found; run helper/install_build_tool.sh first" >&2
    exit 1
fi

# The caller may be PowerShell -> Scoop sh.exe -> this script, with Scoop
# shims ahead of MSYS2 in PATH. Force MSYS2's real POSIX tools to win before
# the first mkdir/sed/grep call; stale BusyBox shims can otherwise break the
# build before the inner bash environment is even launched.
PATH="$MSYS2_USR_BIN:$PATH"
export PATH

# bash.exe probes the MSYS2 root /tmp at startup and prints
#   bash.exe: warning: could not find /tmp, please create!
# when it is missing (scoop's MSYS2 does not always create it). Create it from
# this outer shell BEFORE launching bash below: the TMPDIR/mkdir inside the
# -lc script runs too late (bash has already emitted the warning at startup)
# and targets the build dir, not this MSYS2 root /tmp that bash checks.
#
# Caveat: this only covers a genuinely-missing /tmp. If this script is driven
# through a FOREIGN msys-2.0.dll runtime -- e.g. running the build through the
# packaged portable zsh itself -- that parent's fork/exec handover corrupts a
# same-named different-build child's mount table, so MSYS2 bash resolves / (and
# /tmp) to the wrong root and warns regardless of this mkdir. Run compile.sh
# from PowerShell, Git Bash, or a real MSYS2 shell (a native/compatible
# parent), not through the portable zsh. Same class as the '/'-resolution
# limitation documented in helper/test/test_windows_packaging.zsh.
mkdir -p "$MSYS2_ROOT/tmp"

# Bring MSYS2 to a consistent package set before detecting/copying build and
# bundled tools, so build/release and build/bin/version.txt reflect one
# coherent tree rather than a mix of old and new. This is a FULL upgrade, not
# a database refresh plus a selective install -- the latter is the partial
# upgrade pattern, and it matters here because the packaged runtime is
# assembled from whatever this MSYS2 tree happens to hold.
#
# Set ZSH_SKIP_MSYS2_UPGRADE=1 for offline builds, or when you need the build
# to consume a pre-prepared toolchain without mutating it.
if [ "${ZSH_SKIP_MSYS2_UPGRADE:-}" != 1 ]; then
    sh "$REPO/helper/msys2_upgrade.sh" "$MSYS2_ROOT"
else
    echo "==> Skipping MSYS2 package update (ZSH_SKIP_MSYS2_UPGRADE=1)"
fi

PATH="$MSYS2_USR_BIN:$PATH"
export PATH

missing_build_tools=
for tool in autoconf make gcc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_build_tools="$missing_build_tools $tool"
    fi
done
if [ -n "$missing_build_tools" ]; then
    echo "error: missing MSYS2 build tools:$missing_build_tools" >&2
    echo "       run: zsh helper/install_build_tool.sh" >&2
    echo "       checked MSYS2 root: $MSYS2_ROOT" >&2
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
SRC_WIN=$(to_windows_path "$SRC")

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
DRIVE_PATCH="$REPO/helper/patches/windows-drive-abspath.patch"
ZLE_CHECKSUMS="$REPO/helper/patches/checksum.txt"
ZLE_BACKUP="$BUILD/zle-patch-backup"
ZLE_RESTORE_FROM_BACKUP=
# Space-separated repo-relative paths saved into $ZLE_BACKUP before patching.
# List-driven so a second patch does not mean a second copy of the
# backup/restore/trap machinery below.
PATCHED_FILES=

backup_patch_targets() {
    for _bpt_file in "$@"; do
        mkdir -p "$ZLE_BACKUP/$(dirname "$_bpt_file")"
        cp "$SRC/$_bpt_file" "$ZLE_BACKUP/$_bpt_file"
        PATCHED_FILES="$PATCHED_FILES $_bpt_file"
    done
}

restore_zle_backup() {
    if [ -n "$ZLE_RESTORE_FROM_BACKUP" ]; then
        echo "==> Restoring patched sources from pre-patch backup..."
        for _rzb_file in $PATCHED_FILES; do
            [ -f "$ZLE_BACKUP/$_rzb_file" ] && cp "$ZLE_BACKUP/$_rzb_file" "$SRC/$_rzb_file"
        done
        ZLE_RESTORE_FROM_BACKUP=
    fi
}
trap restore_zle_backup EXIT HUP INT TERM

if [ -f "$ZLE_PATCH" ] && ! grep -q ZSH_IS_HIGH_SURROGATE "$SRC/Src/Zle/zle.h" 2>/dev/null; then
    # Comments stripped before checking: not all sha256sum implementations
    # skip '#' lines in --check mode (GNU coreutils does; some don't and
    # report each as a bogus FAILED entry).
    if ! ( cd "$SRC" && grep -v '^#' "$ZLE_CHECKSUMS" | sha256sum -c - ) >/dev/null 2>&1; then
        if [ -n "$FORCE" ]; then
            echo "warning: one or more of Src/Zle/zle.h, Src/Zle/zle_move.c," >&2
            echo "         Src/hist.c, Src/subst.c no longer matches" >&2
            echo "         helper/patches/checksum.txt; building anyway (-f). The" >&2
            echo "         patches below may not apply cleanly, or may apply but no" >&2
            echo "         longer mean what their comments say. Run" >&2
            echo "         helper/regen_checksum.sh once you've confirmed they are" >&2
            echo "         still correct." >&2
        else
            echo "error: one or more of Src/Zle/zle.h, Src/Zle/zle_move.c," >&2
            echo "       Src/hist.c, Src/subst.c no longer matches the versions the" >&2
            echo "       patches in helper/patches/ were written against (see" >&2
            echo "       helper/patches/checksum.txt). Refusing to build until the" >&2
            echo "       patches are reviewed and checksum.txt updated" >&2
            echo "       (helper/regen_checksum.sh), or rerun with -f to build" >&2
            echo "       past this check once." >&2
            exit 1
        fi
    fi
    echo "==> Applying Windows ZLE surrogate-pair patch..."
    rm -rf "$ZLE_BACKUP"
    backup_patch_targets Src/Zle/zle.h Src/Zle/zle_move.c
    git -C "$SRC" apply "$ZLE_PATCH"
    ZLE_RESTORE_FROM_BACKUP=1

    # Same lifecycle, so it rides along with the ZLE patch's checksum gate
    # and backup: both are applied to a pristine tree here and reverted by
    # the trap. Keeping them together means a build can never end up with
    # one applied and the other not.
    echo "==> Applying Windows drive-path (:A/:a/:P) patch..."
    backup_patch_targets Src/hist.c Src/subst.c
    git -C "$SRC" apply "$DRIVE_PATCH"
elif [ -f "$ZLE_BACKUP/Src/Zle/zle.h" ] && \
     [ -f "$ZLE_BACKUP/Src/Zle/zle_move.c" ] && \
     grep -q ZSH_IS_HIGH_SURROGATE "$SRC/Src/Zle/zle.h" 2>/dev/null; then
    # A previous run was interrupted after patching. Rebuild the restore
    # list from whatever the backup actually holds, so the trap below puts
    # every patched file back, not just the ZLE pair.
    for _leftover in Src/Zle/zle.h Src/Zle/zle_move.c Src/hist.c Src/subst.c; do
        [ -f "$ZLE_BACKUP/$_leftover" ] && PATCHED_FILES="$PATCHED_FILES $_leftover"
    done
    ZLE_RESTORE_FROM_BACKUP=1
fi

# --- preconfig, configure (in build/), make ---------------------------------
# Assembled here, then run below either directly or (when the MSYS2 mount
# handover is broken -- see the dispatch after the closing quote) through
# cmd.exe. The script is self-contained: it sets its own PATH/TMPDIR and cd's
# to an absolute path, so it does not depend on the inherited environment.
_msys_build_script="
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
    mkdir -p bin/etc bin/tmp
    : > bin/.bundled-tool-versions.tmp
    cat > bin/etc/fstab <<'EOF_FSTAB'
# Use MSYS2 short drive mounts such as /c/Users in the portable runtime.
none / cygdrive binary,posix=0,noacl,user 0 0
EOF_FSTAB
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

    if [ -d /usr/share/terminfo ]; then
        mkdir -p bin/share
        cp -R /usr/share/terminfo bin/share/
    fi

    # Bundle MSYS tools the portable runtime expects to win over Windows,
    # BusyBox, Git-for-Windows, or other sh environments on PATH. This covers
    # every currently-detected BusyBox-backed Scoop shim that also has an
    # MSYS2 /usr/bin/<tool>.exe equivalent, plus terminal/process helpers
    # used by zsh. ps must be the MSYS/Cygwin one with -W support, not
    # BusyBox ps; procps-ng/psmisc provide pgrep/pkill/pidof/killall.
    record_bundled_tool_version() {
        record_tool=\$1
        record_path=\$2
        record_version=
        for record_opt in --version -V -v; do
            record_candidate=\$(timeout 3s \"\$record_path\" \"\$record_opt\" </dev/null 2>&1 \\
                | sed -n '/./{p;q;}')
            if [ -n \"\$record_candidate\" ] && ! printf '%s\n' \"\$record_candidate\" \\
                | grep -Eiq 'invalid|illegal|unknown|usage|missing operand|requires an argument'; then
                record_version=\$record_candidate
                break
            fi
        done
        if [ -z \"\$record_version\" ]; then
            record_version='version unavailable'
        fi
        printf '%s\t%s\t%s\n' \"\$record_tool\" \"\$record_path\" \"\$record_version\" \\
            >> bin/.bundled-tool-versions.tmp
    }

    for tool in '[' ar arch ash awk base32 base64 basename bash bc cal cat chattr \
        chmod cksum clear cmp comm cp cut date dc dd df diff dirname du env file \
        expand expr factor false find flock fold getopt grep groups gzip \
        head hexdump id install join kill killall less link ln locale logname ls \
        lsattr lzcat lzma m4 make man md5sum mkdir mktemp mv nc nl nproc od \
        openssl paste perl pgrep pidof pkill printenv ps pwd readlink realpath reset rev rm rmdir sed \
        seq sh sha1sum sha256sum sha384sum sha512sum shred shuf sleep sort \
        split stat strings stty sum sync tac tail tar tee test time timeout \
        touch tr true truncate tset tsort uname unexpand uniq unlink unlzma \
        unxz uuidgen wc wget which whoami xargs xxd xzcat yes infocmp tput \
        autoconf autoconf-2.13 autoconf-2.69 autoconf-2.71 autoconf-2.72 \
        autoconf-2.73 autoheader autoheader-2.13 autoheader-2.69 \
        autoheader-2.71 autoheader-2.72 autoheader-2.73 autom4te \
        autom4te-2.69 autom4te-2.71 autom4te-2.72 autom4te-2.73 \
        autoreconf autoreconf-2.13 autoreconf-2.69 autoreconf-2.71 \
        autoreconf-2.72 autoreconf-2.73 autoscan autoscan-2.13 \
        autoscan-2.69 autoscan-2.71 autoscan-2.72 autoscan-2.73 \
        autoupdate autoupdate-2.13 autoupdate-2.69 autoupdate-2.71 \
        autoupdate-2.72 autoupdate-2.73 ifnames ifnames-2.13 \
        ifnames-2.69 ifnames-2.71 ifnames-2.72 ifnames-2.73; do
        tool_exe=
        tool_kind=exe
        if command -v \$tool.exe >/dev/null 2>&1; then
            tool_exe=\"\$(command -v \$tool.exe)\"
        elif command -v \$tool >/dev/null 2>&1; then
            tool_exe=\"\$(command -v \$tool)\"
            tool_kind=script
        fi
        if [ -n \"\$tool_exe\" ]; then
            if [ \"\$tool\" = ps ] && ! \"\$tool_exe\" -W >/dev/null 2>&1; then
                echo \"warning: skipping non-MSYS ps.exe without -W support: \$tool_exe\" >&2
                continue
            fi
            mkdir -p bin/usr/bin
            if [ \"\$tool_kind\" = exe ]; then
                cp \"\$tool_exe\" bin/
                cp \"\$tool_exe\" \"bin/usr/bin/\$tool.exe\"
                record_bundled_tool_version \"\$tool\" \"\$tool_exe\"
                case \"\$tool\" in
                    sh)
                        mkdir -p bin/bin
                        cp \"\$tool_exe\" bin/bin/sh.exe
                        ;;
                esac
                ldd \"\$tool_exe\" 2>/dev/null \\
                    | awk '/=> \/usr\/bin\/msys-/ { print \$3 }' \\
                    | while read -r dll; do cp \"\$dll\" bin/; done
            else
                cp \"\$tool_exe\" \"bin/usr/bin/\$tool\"
                record_bundled_tool_version \"\$tool\" \"\$tool_exe\"
            fi
        fi
    done

    for share_dir in /usr/share/autoconf-*; do
        [ -d "\$share_dir" ] || continue
        mkdir -p bin/usr/share
        cp -R "\$share_dir" bin/usr/share/
    done
    if [ -d /usr/lib/perl5 ]; then
        mkdir -p bin/usr/lib
        cp -R /usr/lib/perl5 bin/usr/lib/
    fi
    if [ -d /usr/share/perl5 ]; then
        mkdir -p bin/usr/share
        cp -R /usr/share/perl5 bin/usr/share/
    fi

    # MSYS derives its POSIX root from the executable/DLL layout. Keep the real
    # interpreter and runtime DLLs under usr/bin so absolute shebangs such as
    # /usr/bin/env resolve inside the portable package rather than under the
    # parent Scoop apps directory. The public root zsh.exe is replaced by the
    # native launcher below; direct callers get argv-preserving behavior, while
    # the MSYS-linked interpreter stays available as usr/bin/zsh.exe.
    mkdir -p bin/usr/bin
    cp bin/zsh.exe bin/usr/bin/zsh.exe
    cp bin/*.dll bin/usr/bin/

    # zsh.cmd can only be run via cmd.exe's own batch-file parser, which
    # re-tokenizes the incoming command line before this script ever runs:
    # it truncates a multi-line -c argument at the first embedded newline,
    # and can leak '|' and other metacharacters out of what looks like a
    # quoted string. Neither is fixable from inside zsh.cmd -- the
    # corruption happens before any of its lines execute. This launcher must
    # be a native Windows PE binary, not an MSYS binary: an MSYS-linked loader
    # re-enters the runtime's child-copy protocol when invoked from zsh and
    # nested shells can fail before main() with a signal-pipe creation error.
    # Package it as zsh-loader.exe and also copy it to root zsh.exe. Users and
    # tools sometimes call apps/zsh/current/zsh.exe directly, bypassing the
    # Scoop shim; that path must be the native argv-preserving launcher too.
    echo '==> Compiling native launcher (bin/zsh-loader.exe and bin/zsh.exe)...'
    NATIVE_CLANG=/clang64/bin/clang.exe
    if [ ! -x \"\$NATIVE_CLANG\" ]; then
        echo 'error: native Clang not found at /clang64/bin/clang.exe' >&2
        echo '       run helper/install_build_tool.sh to install mingw-w64-clang-x86_64-clang' >&2
        exit 1
    fi
    \"\$NATIVE_CLANG\" -O2 -o bin/zsh-loader.exe '$SRC_WIN/helper/zsh_launcher.c' -lshell32

    # Guard the property that makes the loader safe to invoke from a running
    # MSYS zsh. Using /usr/bin/clang or /usr/bin/gcc here would silently
    # produce a loader linked to msys-2.0.dll and restore the nested
    # child_copy/signal-pipe failure.
    if objdump -p bin/zsh-loader.exe \
        | grep -qi 'DLL Name:[[:space:]]*msys-2\.0\.dll'; then
        echo 'error: zsh-loader.exe unexpectedly imports msys-2.0.dll' >&2
        exit 1
    fi
    cp bin/zsh-loader.exe bin/zsh.exe
"

# Run the assembled build script under MSYS2 bash. Normally direct. But if
# MSYS2 bash comes up unable to see /tmp, this script's parent is a FOREIGN
# msys-2.0.dll runtime (e.g. the build was driven through the packaged
# portable zsh itself): its fork/exec handover corrupts a same-named
# different-build child's mount table, so bash resolves / and /tmp to the
# wrong root and cannot find /tmp. Relaunch through cmd.exe -- a native
# process -- which lets MSYS2 bash initialize a correct mount table. The
# probe (test -d /tmp) is spawned the same way, so it detects the breakage.
# ZSH_COMPILE_FORCE_CMD=1 forces the cmd.exe route unconditionally -- for
# testing, or from a shell you already know corrupts the handover.
#
# The script is always handed over as a FILE, never as a -c string. When the
# parent is a different msys-2.0.dll build (Git Bash spawning MSYS2's
# bash.exe), the command line crossing that boundary is truncated at ~8KB
# with no error: bash just runs the prefix it received. The assembled script
# is well past that, and because the bundled-tool `for` list collapses into
# one very long line, the cut landed mid-list and surfaced only as a bare
# "syntax error: unexpected end of file from `for' command". A file argument
# is a short path, so it cannot hit the limit.
mkdir -p "$BUILD/tmp"
_msys_script_file="$BUILD/tmp/compile_msys_build.sh"
printf '%s\n' "$_msys_build_script" > "$_msys_script_file"

if [ -z "${ZSH_COMPILE_FORCE_CMD:-}" ] && "$MSYS2_BASH" -c 'test -d /tmp' 2>/dev/null; then
    "$MSYS2_BASH" -l "$_msys_script_file"
else
    echo '==> MSYS2 /tmp unreachable (foreign msys runtime parent); relaunching bash via cmd.exe...'
    # cmd.exe needs a BACKSLASH exe path -- forward slashes make it mis-split
    # the path at each component (e.g. .../current -> a stray 'urrent'
    # command). bash then reads a forward-slash script path fine. And
    # MSYS2_ARG_CONV_EXCL stops the outer shell (Git Bash / MSYS2) from
    # rewriting the '/c' switch into a path on the way to cmd.
    _msys_bash_win=$(cygpath -w "$MSYS2_BASH" 2>/dev/null || to_windows_path "$MSYS2_BASH")
    _msys_script_win=$(to_windows_path "$_msys_script_file")
    MSYS2_ARG_CONV_EXCL='*' cmd /c "$_msys_bash_win" -l "$_msys_script_win"
fi

# --- Portable launcher + zsh bootstrap --------------------------------------
# Written here (outer script), not inside the MSYS2 -lc "..." string above:
# these heredocs contain literal double quotes, which would otherwise close
# that outer double-quoted string early and mangle everything after it.
cat > "$BUILD/bin/zsh.cmd" <<'EOF_CMD'
@echo off
setlocal EnableDelayedExpansion
set "_ZSH_INHERITED_PORTABLE=%ZSH_PORTABLE_DIR%"
set "ZSH_PORTABLE_DIR=%~dp0"
rem Strip %~dp0's trailing backslash so the value matches the form the
rem native launcher (zsh-loader.exe) uses -- nested sessions compare
rem ZDOTDIR against ZSH_PORTABLE_DIR and must agree regardless of which
rem entry point set them.
if "%ZSH_PORTABLE_DIR:~-1%"=="\" set "ZSH_PORTABLE_DIR=%ZSH_PORTABLE_DIR:~0,-1%"
set "ZSH_WIN_HOME=%USERPROFILE%"
set "ZSH_TERMINFO_DIR=%ZSH_PORTABLE_DIR:\=/%/share/terminfo"
set "ZSH_TERMINFO_DRIVE=%ZSH_TERMINFO_DIR:~0,1%"
set "ZSH_TERMINFO_PATH=%ZSH_TERMINFO_DIR:~2%"
set "TERMINFO=/%ZSH_TERMINFO_DRIVE%%ZSH_TERMINFO_PATH%"
rem "C.utf8" (as in `locale -a`), NOT "C.UTF-8": the dashed spelling is
rem not a real Cygwin locale and is mis-decoded, which scrambles ZLE input.
set "LC_CTYPE=C.utf8"
if not defined LANG set "LANG=C.utf8"

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
set "PATH=%ZSH_PORTABLE_DIR%;%ZSH_PORTABLE_DIR%\usr\bin;%PATH%"
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

rem Precedence for what counts as the user's dot dir (same rules as the
rem native launcher): an explicitly set ZDOTDIR that isn't just the
rem portable dir inherited from an enclosing session wins even when
rem nested; otherwise an inherited ZSH_ORIG_ZDOTDIR is kept (we're
rem nested -- don't clobber the original caller's value); otherwise
rem fall back to USERPROFILE.
if not defined _ZSH_INHERITED_PORTABLE set "_ZSH_INHERITED_PORTABLE=%ZSH_PORTABLE_DIR%"
if defined ZDOTDIR if /I "%ZDOTDIR%"=="%_ZSH_INHERITED_PORTABLE%" set "_ZSH_ZDOTDIR_IS_PORTABLE=1"
if defined ZDOTDIR if /I "%ZDOTDIR%"=="%ZSH_PORTABLE_DIR%" set "_ZSH_ZDOTDIR_IS_PORTABLE=1"
if defined ZDOTDIR if not defined _ZSH_ZDOTDIR_IS_PORTABLE set "ZSH_ORIG_ZDOTDIR=%ZDOTDIR%"
if not defined ZSH_ORIG_ZDOTDIR set "ZSH_ORIG_ZDOTDIR=%USERPROFILE%"
set "ZDOTDIR=%ZSH_PORTABLE_DIR%"

rem %* is passed through to zsh.exe as-is below; disable delayed expansion
rem first so a literal "!" in a forwarded argument survives untouched.
rem (zsh.exe, not zsh-loader.exe: this script already does the same env setup
rem the native launcher does, so it calls the real interpreter directly.)
setlocal DisableDelayedExpansion
"%ZSH_PORTABLE_DIR%\usr\bin\zsh.exe" %*
set "_ZSH_EXIT=%ERRORLEVEL%"
if defined _ZSH_ORIG_CP chcp %_ZSH_ORIG_CP% >nul
exit /b %_ZSH_EXIT%
EOF_CMD

# for /f (used above to read back the current code page) requires CRLF line
# endings to parse correctly in cmd.exe; the heredoc above wrote plain LF.
sed -i 's/$/\r/' "$BUILD/bin/zsh.cmd"

cat > "$BUILD/bin/.zshenv" <<'EOF_ZSHENV'
zsh_portable_dir=${ZSH_PORTABLE_DIR:-}
zsh_portable_dir_win=
if [[ -n $zsh_portable_dir ]]; then
  zsh_portable_dir=${zsh_portable_dir//\\//}
  zsh_portable_dir=${zsh_portable_dir%/}
  zsh_portable_dir_win=$zsh_portable_dir
  if [[ $zsh_portable_dir == [A-Za-z]:/* ]]; then
    zsh_portable_dir="/${(L)zsh_portable_dir[1]}/${zsh_portable_dir[4,-1]}"
  fi
  if [[ ! -d $zsh_portable_dir && $zsh_portable_dir == /[A-Za-z]/* ]]; then
    zsh_portable_dir="/cygdrive/${(L)zsh_portable_dir[2]}${zsh_portable_dir[3,-1]}"
  fi
  module_path=("$zsh_portable_dir" $module_path)
  if [[ -d $zsh_portable_dir/share/terminfo ]]; then
    TERMINFO=$zsh_portable_dir/share/terminfo
    export TERMINFO
  elif [[ -d $zsh_portable_dir/usr/share/terminfo ]]; then
    TERMINFO=$zsh_portable_dir/usr/share/terminfo
    export TERMINFO
  elif [[ -d /usr/share/terminfo ]]; then
    TERMINFO=/usr/share/terminfo
    export TERMINFO
  else
    unset TERMINFO
  fi
fi
# "C.utf8" (as it appears in `locale -a`), NOT "C.UTF-8": the dashed/
# uppercase spelling is not a real Cygwin locale here and is mis-decoded
# (mbrtowc is inconsistent), which puts ZLE into multibyte mode with
# unreliable decoding and desyncs the cursor from the display -- even
# plain ASCII line editing gets scrambled. LC_ALL has priority over
# LC_CTYPE, so remove a user-provided LC_ALL after startup files too.
zsh_portable_fix_locale() {
  if [[ -n ${LC_ALL:-} && ${LC_ALL:-} != C.utf8 ]]; then
    unset LC_ALL
  fi
  LC_CTYPE=C.utf8
  export LC_CTYPE
  if [[ -z ${LANG:-} || ${LANG:-} == C.UTF-8 ]]; then
    LANG=C.utf8
    export LANG
  fi
}
zsh_portable_fix_locale
unsetopt nomatch
if [[ -n ${ZSH_WIN_HOME:-} ]]; then
  HOME=${ZSH_WIN_HOME//\\//}
  export HOME
fi
if [[ -n ${ZSH_START_CWD:-} ]]; then
  zsh_start_cwd=$ZSH_START_CWD
  if [[ ! -d $zsh_start_cwd && $zsh_start_cwd == /[A-Za-z]/* ]]; then
    zsh_start_cwd="/cygdrive/${(L)zsh_start_cwd[2]}${zsh_start_cwd[3,-1]}"
  fi
  if [[ -d $zsh_start_cwd ]]; then
    cd -- $zsh_start_cwd 2>/dev/null || true
  fi
  unset ZSH_START_CWD
  unset zsh_start_cwd
fi
function taskkill.exe {
  MSYS2_ARG_CONV_EXCL='*' command taskkill.exe "$@"
}
taskkill() {
  taskkill.exe "$@"
}
function wsl.exe {
  MSYS2_ARG_CONV_EXCL='*' command wsl.exe "$@"
}
wsl() {
  wsl.exe "$@"
}
zsh_portable_no_msys_arg_conv() {
  local zsh_portable_cmd=$1
  shift
  MSYS2_ARG_CONV_EXCL='*' command "$zsh_portable_cmd" "$@"
}
node.exe() { zsh_portable_no_msys_arg_conv node.exe "$@" }
node() { zsh_portable_no_msys_arg_conv node "$@" }
npm() { zsh_portable_no_msys_arg_conv npm "$@" }
npx() { zsh_portable_no_msys_arg_conv npx "$@" }
pnpm() { zsh_portable_no_msys_arg_conv pnpm "$@" }
yarn() { zsh_portable_no_msys_arg_conv yarn "$@" }
bun.exe() { zsh_portable_no_msys_arg_conv bun.exe "$@" }
bun() { zsh_portable_no_msys_arg_conv bun "$@" }
deno.exe() { zsh_portable_no_msys_arg_conv deno.exe "$@" }
deno() { zsh_portable_no_msys_arg_conv deno "$@" }
killwin() {
  if (( $# == 0 )); then
    printf '%s\n' "usage: killwin WINPID [...]" >&2
    return 2
  fi
  local zsh_portable_pid zsh_portable_status=0
  for zsh_portable_pid in "$@"; do
    if [[ $zsh_portable_pid != <-> ]]; then
      printf '%s\n' "killwin: invalid WINPID: $zsh_portable_pid" >&2
      zsh_portable_status=2
      continue
    fi
    taskkill /PID "$zsh_portable_pid" /F || zsh_portable_status=$?
  done
  return $zsh_portable_status
}
if [[ -o interactive ]]; then
  PROMPT="%n@%~%# "
  zsh_portable_fix_keys() {
    local zsh_portable_keymap
    for zsh_portable_keymap in main emacs viins vicmd; do
      bindkey -M "$zsh_portable_keymap" "^M" accept-line 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^J" accept-line 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^?" backward-delete-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^H" backward-delete-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[A" up-line-or-history 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[B" down-line-or-history 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[C" forward-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[D" backward-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[200~" bracketed-paste 2>/dev/null
    done
    stty erase "^?" 2>/dev/null || stty erase "^H" 2>/dev/null
  }
  zsh_portable_fix_keys
  precmd_functions=(${precmd_functions:#zsh_portable_fix_keys} zsh_portable_fix_keys)
fi

# ZDOTDIR deliberately stays pointing at the portable dir for the whole
# session tree (ZSH_ORIG_ZDOTDIR/ZSH_PORTABLE_DIR/ZSH_WIN_HOME stay
# exported too): that is what lets a nested zsh.exe, spawned from inside
# this session, find this same bootstrap and load its modules, instead of
# inheriting a consumed, half-restored environment. The user's own
# startup files still run: their .zshenv here, and .zshrc/.zprofile/
# .zlogin via the matching forwarding stubs next to this file -- each
# sourced with ZDOTDIR temporarily set to the user's real dot dir, since
# that is what those files expect it to mean.
if [[ -n ${ZSH_ORIG_ZDOTDIR:-} ]]; then
  zsh_portable_user_zdotdir=${ZSH_ORIG_ZDOTDIR//\\//}
  if [[ $zsh_portable_user_zdotdir != $zsh_portable_dir_win && \
        $zsh_portable_user_zdotdir != $zsh_portable_dir && \
        -r $zsh_portable_user_zdotdir/.zshenv ]]; then
    ZDOTDIR=$zsh_portable_user_zdotdir
    source $zsh_portable_user_zdotdir/.zshenv
    # honor a ZDOTDIR change made by the user's own .zshenv
    if [[ ${ZDOTDIR:-} != $zsh_portable_user_zdotdir ]]; then
      ZSH_ORIG_ZDOTDIR=$ZDOTDIR
      export ZSH_ORIG_ZDOTDIR
    fi
    ZDOTDIR=${ZSH_PORTABLE_DIR:-}
    export ZDOTDIR
  fi
  zsh_portable_fix_locale
  unset zsh_portable_user_zdotdir
fi
unset zsh_portable_dir zsh_portable_dir_win
EOF_ZSHENV

# Forwarding stubs for the remaining startup files: ZDOTDIR points at the
# portable dir (see .zshenv above), so zsh looks for these HERE; each one
# hands off to the user's real counterpart.
for rc in .zshrc .zprofile .zlogin; do
cat > "$BUILD/bin/$rc" <<EOF_RC
# Forwarding stub: ZDOTDIR points at the portable runtime dir for the
# whole session (see .zshenv there); this loads the user's real $rc
# from their own dot dir, with ZDOTDIR temporarily set the way that
# file expects.
if [[ -n \${ZSH_ORIG_ZDOTDIR:-} ]]; then
  zsh_portable_user_zdotdir=\${ZSH_ORIG_ZDOTDIR//\\\\//}
  if [[ \$zsh_portable_user_zdotdir != \${\${ZSH_PORTABLE_DIR:-}//\\\\//} && \\
        -r \$zsh_portable_user_zdotdir/$rc ]]; then
    ZDOTDIR=\$zsh_portable_user_zdotdir
    source \$zsh_portable_user_zdotdir/$rc
    ZDOTDIR=\${ZSH_PORTABLE_DIR:-\$zsh_portable_user_zdotdir}
    export ZDOTDIR
  fi
  if (( \$+functions[zsh_portable_fix_keys] )); then
    zsh_portable_fix_keys
  fi
  if (( \$+functions[zsh_portable_fix_locale] )); then
    zsh_portable_fix_locale
  fi
  unset zsh_portable_user_zdotdir
fi
EOF_RC
done

# --- Stamp the build: zsh version + source commit ---------------------------
{
    "$BUILD/bin/zsh.cmd" --version
    git -C "$SRC" log -1 --format='%H'
    if [ -s "$BUILD/bin/.bundled-tool-versions.tmp" ]; then
        printf '\n%s\n' 'bundled tools:'
        sort "$BUILD/bin/.bundled-tool-versions.tmp"
    fi
} > "$BUILD/bin/version.txt"
rm -f "$BUILD/bin/.bundled-tool-versions.tmp"
echo "==> version.txt:"
cat "$BUILD/bin/version.txt"

# --- Clean generated files out of the source tree; keep build/ --------------
echo "==> Cleaning generated files from source tree..."
rm -rf "$SRC/autom4te.cache"
rm -f "$SRC/configure" "$SRC/config.h.in" "$SRC/stamp-h.in" "$SRC/META-FAQ"
restore_zle_backup
if [ -f "$ZLE_PATCH" ] && grep -q ZSH_IS_HIGH_SURROGATE "$SRC/Src/Zle/zle.h" 2>/dev/null; then
    echo "warning: Windows ZLE patch is present, but no pre-patch backup was found." >&2
    echo "         Leaving Src/Zle/zle.h and Src/Zle/zle_move.c unchanged;" >&2
    echo "         restore them manually before the next clean build." >&2
fi

echo "==> Build complete. Output kept in: $BUILD"
echo "==> Portable runtime: $BUILD/bin"
echo "==>   zsh.cmd        - interactive launcher for cmd.exe / double-click"
echo "==>   zsh-loader.exe - native launcher for programmatic callers (preserves argv exactly)"
echo "==>   zsh.exe        - public native launcher; real interpreter is usr/bin/zsh.exe"
"$BUILD/bin/zsh.cmd" --version
echo "==> For dynamic modules (zle etc.) outside MSYS2, run $BUILD/bin/zsh.cmd or zsh-loader.exe"
