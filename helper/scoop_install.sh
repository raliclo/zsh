#!/bin/sh
# scoop_install.sh - Package the portable build/bin runtime and install it
# via scoop, so zsh lands in scoop's standard app location with a shim.
#
# Prerequisite: sh helper/compile.sh  (produces build/bin)
#
# Usage (from Git Bash or any POSIX shell):
#   sh helper/scoop_install.sh [--package-only] [--upload-release] [--install-remote]
#   sh helper/scoop_install.sh --release
#
# What it does:
#   1. Packs build/bin/*  ->  build/package/zsh.tar.zst
#   2. Regenerates bucket/zsh.json with the version and sha256 hash
#      (GitHub Release asset URL)
#   3. Optionally uploads zsh.tar.zst to one stable GitHub Release tag
#
# zstd rather than zip, since 2026-08-29. Both ends were verified before the
# switch rather than assumed: Windows' own bsdtar 3.8.4 is built with
# libzstd 1.5.7, so `tar -a -cf x.tar.zst` needs no extra tool; and scoop
# extracts it because Expand-7zipArchive strips the .zst, sees a name still
# ending in .tar, and runs the second pass itself (decompress.ps1, $IsTar).
# 7-Zip only gained zstd support in its 26.x line -- on an older 7-Zip the
# install side would fail, so this is a floor to be aware of, not a free win.
#   4. scoop install bucket/zsh.json or build/local-manifest/zsh.json, which:
#        - extracts to  ~/scoop/apps/zsh/<version>\   (+ 'current' junction)
#        - creates the shim  ~/scoop/shims/zsh        (from zsh-loader.exe)
#        - uses the packaged .zshenv bootstrap so zsh finds dynamic modules
#
# --package-only stops after step 2: it refreshes the archive and the manifest
# hash (which have to be regenerated together, since the manifest pins the
# archive's sha256) but leaves the currently installed zsh alone. Use it when
# preparing a commit without disturbing a working install. --upload-release
# publishes the package asset without installing. --install-remote uploads the
# asset and installs from bucket/zsh.json. --release is shorthand for
# --upload-release --install-remote. The GitHub Release tag is stable
# (default: zsh-portable) and the zsh.tar.zst asset is overwritten each run.

set -e

PACKAGE_ONLY=
UPLOAD_RELEASE=
INSTALL_REMOTE=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --package-only)
            PACKAGE_ONLY=1
            ;;
        --upload-release)
            UPLOAD_RELEASE=1
            ;;
        --install-remote)
            UPLOAD_RELEASE=1
            INSTALL_REMOTE=1
            ;;
        --release)
            UPLOAD_RELEASE=1
            INSTALL_REMOTE=1
            ;;
        *)
            echo "error: unknown option: $1" >&2
            echo "usage: sh helper/scoop_install.sh [--package-only] [--upload-release] [--install-remote|--release]" >&2
            exit 2
            ;;
    esac
    shift
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$REPO/build"
BUCKET="$REPO/bucket"

to_windows_path() {
    case "$1" in
        [A-Za-z]:/*)
            printf '%s\n' "$1"
            ;;
        [A-Za-z]:\\*)
            printf '%s\n' "$1" | sed 's#\\#/#g'
            ;;
        *)
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
            ;;
    esac
}

find_windows_tar() {
    for tar in \
        /c/Windows/System32/tar.exe \
        C:/Windows/System32/tar.exe \
        /mnt/c/Windows/System32/tar.exe
    do
        if [ -x "$tar" ]; then
            printf '%s\n' "$tar"
            return 0
        fi
    done

    if command -v tar.exe >/dev/null 2>&1; then
        command -v tar.exe
        return 0
    fi

    return 1
}

scoop_home() {
    if command -v scoop >/dev/null 2>&1; then
        scoop_cmd=$(command -v scoop)
        case "$scoop_cmd" in
            */shims/scoop*)
                dirname "$(dirname "$scoop_cmd")"
                return 0
                ;;
        esac
    fi

    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE/scoop"
        return 0
    fi

    printf '%s\n' "$HOME/scoop"
}

# Stop everything running OUT OF the zsh app directory -- by PATH, not by name.
#
# scoop refuses to uninstall an app while any process whose image path lives
# under that app's directory is running, and this package ships the MSYS2
# tools, so the blocker is usually not named zsh at all. Observed: scoop
# reported "instances of zsh are still running" and listed a `grep`, and on the
# next attempt a `sleep` -- both the packaged copies. Matching on the names
# zsh/zsh-c/zsh-loader, as this did, could never see them.
#
# It is self-inflicted, which is what made it a loop: the shim check at the end
# of a run starts zsh, whatever it leaves behind blocks the NEXT run's
# uninstall, and that uninstall failing was not checked -- so the script
# reported "Installed." over an install that never happened.
#
# ps -W (not PowerShell) because it reports the full Windows image path, which
# is the thing being matched; taskkill takes the WINPID from the same listing.
# Dash options survive MSYS argument conversion either way.
stop_zsh_processes() {
    _szp_dir=$1
    [ -n "$_szp_dir" ] || return 0
    command -v ps >/dev/null 2>&1 || return 0
    # ps -W reports WINDOWS paths (C:\Users\...) while $SCOOP_HOME is POSIX
    # (/c/Users/...). Comparing the two directly matches nothing and kills
    # nothing, silently -- the first version of this function did exactly that,
    # and the uninstall went on failing while the killer reported no work.
    # Normalize to one form, lowercased, before comparing.
    _szp_win=$(to_windows_path "$_szp_dir" 2>/dev/null) || _szp_win=$_szp_dir
    _szp_key=$(printf '%s' "$_szp_win" | tr 'A-Z' 'a-z' | tr '\\' '/')
    ps -W 2>/dev/null \
        | tr '\\' '/' \
        | awk -v d="$_szp_key" 'index(tolower($NF), d) == 1 { print $4 }' \
        | while read -r _szp_pid; do
            [ -n "$_szp_pid" ] || continue
            taskkill -f -pid "$_szp_pid" >/dev/null 2>&1 || true
        done
    # Windows releases the file handles a moment after the process goes.
    sleep 1
}

run_shim_version() {
    shim=$1

    if command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        shim_win=$(cygpath -m "$shim")
        powershell.exe -NoProfile -Command \
            "& '$shim_win' --version"
        return $?
    fi

    "$shim" --version
}

github_repo_url() {
    case "$1" in
        git@github.com:*)
            printf 'https://github.com/%s\n' "${1#git@github.com:}" | sed 's/\.git$//'
            ;;
        https://github.com/*|http://github.com/*)
            printf '%s\n' "$1" | sed 's/\.git$//'
            ;;
        *)
            printf '%s\n' "$1" | sed 's/\.git$//'
            ;;
    esac
}

if [ ! -x "$BUILD/bin/zsh.exe" ] || [ ! -x "$BUILD/bin/zsh-loader.exe" ]; then
    echo "error: $BUILD/bin/zsh.exe or zsh-loader.exe not found; run helper/compile.sh first" >&2
    exit 1
fi
if [ ! -f "$BUILD/bin/zsh.cmd" ] || { [ ! -f "$BUILD/bin/zsh/zle.so" ] && [ ! -f "$BUILD/bin/zsh/zle.dll" ]; }; then
    echo "error: build/bin is missing zsh.cmd or zsh/zle module; rerun helper/compile.sh" >&2
    exit 1
fi
if [ ! -f "$BUILD/bin/zshrc.sh" ] || ! grep -q 'zshrc\.sh' "$BUILD/bin/.zshrc" 2>/dev/null; then
    echo "error: build/bin is missing the portable zshrc.sh bootstrap; rerun helper/compile.sh" >&2
    exit 1
fi
if [ -z "$PACKAGE_ONLY" ]; then
    command -v scoop >/dev/null 2>&1 || {
        echo "error: scoop not found; run helper/install_build_tool.sh first" >&2
        exit 1
    }
fi

# zsh's own version string never changes between builds of the same source
# ("5.9.999.3-test"), so scoop saw every rebuild as already-installed:
# `scoop update zsh` skipped it, `scoop install` refused it, and the stale
# download stayed in the cache -- three symptoms of one cause, which is why
# updating meant uninstall + cache rm + install every time.
#
# Append a build identity: <date>v<n>.<commit>. The date makes it obvious
# how old an install is, the counter distinguishes rebuilds within one day,
# and the commit ties the artifact back to the source it came from.
#
# Joined with '.' rather than '+' deliberately: under semver, everything
# after '+' is build metadata and is IGNORED when comparing precedence, so
# "...+20260816v1" and "...+20260816v2" could compare equal and scoop would
# go on skipping the update -- reintroducing the exact bug this fixes.
BASE_VERSION=$("$BUILD/bin/zsh.exe" --version | awk '{print $2}')
BUILD_DATE=$(date +%Y%m%d)
SHORT_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo nogit)

# The counter restarts at v1 each new day. It is derived from the version
# already in bucket/zsh.json rather than from local state, so it stays
# correct across machines and clean checkouts -- the manifest is committed,
# a scratch file would not be.
# Parsed from the END, not the start: the base version contains dots and
# digits of its own, so anchoring on it is fragile. The tail is always
# .<8-digit date>v<counter>.<commit>, so strip the commit, then take the
# final dot-separated field.
PREV_VERSION=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$BUCKET/zsh.json" 2>/dev/null)
PREV_DATE=
PREV_SEQ=
_datever=${PREV_VERSION%.*}     # drop .<commit>
_datever=${_datever##*.}        # keep <date>v<counter>
case "$_datever" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]v[0-9]*)
        PREV_DATE=${_datever%%v*}
        PREV_SEQ=${_datever#*v}
        ;;
esac
case "$PREV_SEQ" in
    ''|*[!0-9]*) PREV_SEQ= ;;
esac

if [ "$PREV_DATE" = "$BUILD_DATE" ] && [ -n "$PREV_SEQ" ]; then
    BUILD_SEQ=$((PREV_SEQ + 1))
else
    BUILD_SEQ=1
fi

VERSION="$BASE_VERSION.${BUILD_DATE}v${BUILD_SEQ}.${SHORT_SHA}"
echo "==> Build version: $VERSION"
PACKAGE="$BUILD/package"
ARCHIVE_NAME=zsh.tar.zst
ARCHIVE="$PACKAGE/$ARCHIVE_NAME"
REPO_WIN=$(to_windows_path "$REPO")   # Windows-style path (C:/...)
SCOOP_HOME=$(scoop_home)
TAR_EXE=$(find_windows_tar) || {
    echo "error: Windows tar.exe not found; expected it under C:/Windows/System32" >&2
    exit 1
}

# Public download URL for scoop users: OUR fork's stable GitHub Release asset.
# Deliberately the 'ralic' remote, not 'origin': 'origin' is often the upstream
# repo this one was forked from (zsh-users/zsh). Fall back to 'origin' only for
# clones that predate the remote split.
if git -C "$REPO" remote get-url ralic >/dev/null 2>&1; then
    FORK_REMOTE=ralic
else
    FORK_REMOTE=origin
fi
ORIGIN=$(github_repo_url "$(git -C "$REPO" remote get-url "$FORK_REMOTE")")
GITHUB_REPO=${ORIGIN#https://github.com/}
RELEASE_TAG=${ZSH_RELEASE_TAG:-zsh-portable}
PUBLIC_URL="$ORIGIN/releases/download/$RELEASE_TAG/$ARCHIVE_NAME"

# --- 1. Pack the portable runtime -------------------------------------------
# Windows' bsdtar is used because PowerShell's Compress-Archive cannot read
# the MSYS2-built binaries. -a picks the format from the NAME, and this
# bsdtar carries libzstd, so .tar.zst needs no external zstd binary.
echo "==> Packaging build/bin -> build/package/$ARCHIVE_NAME"
mkdir -p "$PACKAGE"
rm -f "$ARCHIVE"
"$TAR_EXE" -a -cf "$REPO_WIN/build/package/$ARCHIVE_NAME" \
    -C "$REPO_WIN/build/bin" .
[ -f "$ARCHIVE" ] || { echo "error: archive creation failed" >&2; exit 1; }

HASH=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[ -n "$HASH" ] || { echo "error: could not hash archive" >&2; exit 1; }
echo "==> sha256: $HASH"

# --- 2. Regenerate the scoop manifest ----------------------------------------
mkdir -p "$BUCKET"
cat > "$BUCKET/zsh.json" <<EOF
{
    "version": "$VERSION",
    "description": "Zsh shell built from source with the MSYS2 toolchain (portable runtime)",
    "homepage": "https://www.zsh.org",
    "license": "Zsh (MIT-like)",
    "architecture": {
        "64bit": {
            "url": "$PUBLIC_URL",
            "hash": "$HASH"
        }
    },
    "bin": [
        [
            "zsh-loader.exe",
            "zsh"
        ]
    ],
    "notes": "zsh built from source with MSYS2; zip served from the stable GitHub Release $RELEASE_TAG at $ORIGIN. The 'zsh' shim points at zsh-loader.exe (a native launcher), not zsh.cmd: scoop shims for a .cmd target still have to go through cmd.exe's own parser, which can truncate a multi-line -c script at the first newline and mangle characters like | inside quoted arguments. zsh-loader.exe forwards argv to the real interpreter (zsh.exe) untouched."
}
EOF
echo "==> Wrote $BUCKET/zsh.json (url: $PUBLIC_URL)"

# A local-file variant of the manifest, so the install can be tested before
# the archive is uploaded to the Release the published manifest points at.
mkdir -p "$BUILD/local-manifest"
sed "s#\"url\": \".*\"#\"url\": \"file:///$REPO_WIN/build/package/$ARCHIVE_NAME\"#" \
    "$BUCKET/zsh.json" > "$BUILD/local-manifest/zsh.json"

if [ -n "$UPLOAD_RELEASE" ]; then
    command -v gh >/dev/null 2>&1 || {
        echo "error: gh not found; install GitHub CLI or rerun without --upload-release/--release" >&2
        exit 1
    }
    COMMIT=$(git -C "$REPO" rev-parse HEAD)
    RELEASE_NOTES="Portable zsh build

Version: $VERSION
Commit: $COMMIT
Asset: $ARCHIVE_NAME
"
    echo "==> Uploading $ARCHIVE to GitHub Release $RELEASE_TAG ($GITHUB_REPO)..."
    if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        gh release edit "$RELEASE_TAG" \
            --repo "$GITHUB_REPO" \
            --title "zsh portable" \
            --notes "$RELEASE_NOTES"
        gh release upload "$RELEASE_TAG" "$ARCHIVE" --repo "$GITHUB_REPO" --clobber
        # The zip this replaced would otherwise stay on the release forever,
        # downloadable and pinned by no manifest -- a stale artifact that looks
        # current. Removing it is not fatal if it is already gone.
        gh release delete-asset "$RELEASE_TAG" zsh.zip --repo "$GITHUB_REPO" --yes 2>/dev/null \
            && echo "==> Removed the superseded zsh.zip asset" || :
    else
        gh release create "$RELEASE_TAG" "$ARCHIVE" \
            --repo "$GITHUB_REPO" \
            --target "$COMMIT" \
            --title "zsh portable" \
            --notes "$RELEASE_NOTES"
    fi
fi

if [ -n "$PACKAGE_ONLY" ]; then
    echo "==> --package-only: archive and manifest refreshed; install left untouched."
    echo "    Upload and install from GitHub Release with:"
    echo "      sh helper/scoop_install.sh --release"
    echo "    or directly from the local manifest:"
    echo "      scoop install '$REPO_WIN/build/local-manifest/zsh.json'"
    exit 0
fi

# --- 3. Install through scoop ------------------------------------------------
ZSH_APP_DIR="$SCOOP_HOME/apps/zsh"
stop_zsh_processes "$ZSH_APP_DIR"
if scoop list zsh 2>/dev/null | grep -q '^zsh '; then
    echo "==> Removing previously installed zsh..."
    scoop uninstall zsh
    # Checked rather than assumed. scoop prints its refusal and still exits 0,
    # and the install that follows then reports "already installed" and leaves
    # the OLD version in place -- an outcome indistinguishable from success in
    # every line this script prints.
    if scoop list zsh 2>/dev/null | grep -q '^zsh '; then
        ZSH_APP_DIR_WIN=$(to_windows_path "$ZSH_APP_DIR" 2>/dev/null) || ZSH_APP_DIR_WIN=$ZSH_APP_DIR
        echo "error: scoop could not uninstall the previous zsh." >&2
        echo "       Something is still running out of $ZSH_APP_DIR_WIN." >&2
        # Listed in the form ps reports, so the paths printed here can be
        # compared with the paths matched above. Printing the POSIX form beside
        # Windows-form process paths is how the mismatch above went unnoticed.
        ps -W 2>/dev/null | tr '\\' '/' \
            | awk -v d="$(printf '%s' "$ZSH_APP_DIR_WIN" | tr 'A-Z' 'a-z' | tr '\\' '/')" \
                  'index(tolower($NF), d) == 1 { print "       still running: " $NF }' >&2
        exit 1
    fi
fi
echo "==> Clearing scoop download cache for zsh..."
scoop cache rm zsh 2>/dev/null || true
if [ -n "$INSTALL_REMOTE" ]; then
    INSTALL_MANIFEST="$REPO_WIN/bucket/zsh.json"
    echo "==> Installing via scoop (from GitHub Release asset)..."
else
    INSTALL_MANIFEST="$REPO_WIN/build/local-manifest/zsh.json"
    echo "==> Installing via scoop (from local zip)..."
fi
stop_zsh_processes "$ZSH_APP_DIR"
scoop install "$INSTALL_MANIFEST"

# --- 4. Verify ---------------------------------------------------------------
# The version just packaged must be the version now installed. Without this the
# script has reported success while scoop left the previous build in place.
INSTALLED_VERSION=$(scoop list zsh 2>/dev/null | awk '$1 == "zsh" { print $2; exit }')
if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    echo "error: installed version does not match the one just packaged." >&2
    echo "       packaged:  $VERSION" >&2
    echo "       installed: ${INSTALLED_VERSION:-<nothing>}" >&2
    exit 1
fi
echo "==> Installed $INSTALLED_VERSION. Shim check:"
SHIM="$SCOOP_HOME/shims/zsh"
if [ ! -x "$SHIM" ] && [ -x "$SCOOP_HOME/shims/zsh.cmd" ]; then
    SHIM="$SCOOP_HOME/shims/zsh.cmd"
fi
run_shim_version "$SHIM"
echo "==> App dir: $SCOOP_HOME/apps/zsh/current"
echo "==> zsh.cmd bootstraps module_path for dynamic modules; run: zsh"
