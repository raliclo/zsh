#!/bin/sh
# scoop_install.sh - Package the portable build/bin runtime and install it
# via scoop, so zsh lands in scoop's standard app location with a shim.
#
# Prerequisite: sh helper/compile.sh  (produces build/bin)
#
# Usage (from Git Bash or any POSIX shell):
#   sh helper/scoop_install.sh [--package-only]
#
# What it does:
#   1. Zips build/bin/*  ->  build/zsh-<version>-x64.zip
#   2. Regenerates bucket/zsh.json with the version and sha256 hash
#      (file:/// url pointing at the zip)
#   3. scoop install bucket/zsh.json, which:
#        - extracts to  ~/scoop/apps/zsh/<version>\   (+ 'current' junction)
#        - creates the shim  ~/scoop/shims/zsh        (from zsh-loader.exe)
#        - uses the packaged .zshenv bootstrap so zsh finds dynamic modules
#
# --package-only stops after step 2: it refreshes the zip and the manifest
# hash (which have to be regenerated together, since the manifest pins the
# zip's sha256) but leaves the currently installed zsh alone. Use it when
# preparing a commit without disturbing a working install -- steps 3 and 4
# uninstall and reinstall, which would interrupt anything running zsh.

set -e

PACKAGE_ONLY=
if [ "$1" = "--package-only" ]; then
    PACKAGE_ONLY=1
    shift
fi

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

stop_zsh_processes() {
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command \
            "Get-Process zsh,zsh-c,zsh-loader -ErrorAction SilentlyContinue | Stop-Process -Force" \
            >/dev/null 2>&1 || true
    fi
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

if [ ! -x "$BUILD/bin/zsh.exe" ] || [ ! -x "$BUILD/bin/zsh-loader.exe" ]; then
    echo "error: $BUILD/bin/zsh.exe or zsh-loader.exe not found; run helper/compile.sh first" >&2
    exit 1
fi
if [ ! -f "$BUILD/bin/zsh.cmd" ] || { [ ! -f "$BUILD/bin/zsh/zle.so" ] && [ ! -f "$BUILD/bin/zsh/zle.dll" ]; }; then
    echo "error: build/bin is missing zsh.cmd or zsh/zle module; rerun helper/compile.sh" >&2
    exit 1
fi
if [ -z "$PACKAGE_ONLY" ]; then
    command -v scoop >/dev/null 2>&1 || {
        echo "error: scoop not found; run helper/install_build_tool.sh first" >&2
        exit 1
    }
fi

VERSION=$("$BUILD/bin/zsh.exe" --version | awk '{print $2}')
RELEASE="$BUILD/release"
ZIP="$RELEASE/zsh.zip"
REPO_WIN=$(to_windows_path "$REPO")   # Windows-style path (C:/...)
SCOOP_HOME=$(scoop_home)
TAR_EXE=$(find_windows_tar) || {
    echo "error: Windows tar.exe not found; expected it under C:/Windows/System32" >&2
    exit 1
}

# Public download URL for scoop users: OUR fork's remote, develop branch.
# (Requires build/release/zsh.zip to be committed and pushed on develop.)
#
# Deliberately the 'ralic' remote, not 'origin': 'origin' is the upstream
# repo this one was forked from (zsh-users/zsh), which carries no
# build/release/zsh.zip, so deriving the URL from it would silently produce
# a manifest pointing at a file that does not exist. Fall back to 'origin'
# only for a clone that predates the remote split.
if git -C "$REPO" remote get-url ralic >/dev/null 2>&1; then
    FORK_REMOTE=ralic
else
    FORK_REMOTE=origin
fi
ORIGIN=$(git -C "$REPO" remote get-url "$FORK_REMOTE" | sed -e 's/\.git$//')
PUBLIC_URL=$(printf '%s' "$ORIGIN" \
    | sed -e 's#github\.com#raw.githubusercontent.com#')/develop/build/release/zsh.zip

# --- 1. Zip the portable runtime --------------------------------------------
# Windows' bsdtar is used because PowerShell's Compress-Archive cannot read
# the MSYS2-built binaries.
echo "==> Packaging build/bin -> build/release/zsh.zip"
mkdir -p "$RELEASE"
rm -f "$ZIP"
"$TAR_EXE" -a -cf "$REPO_WIN/build/release/zsh.zip" \
    -C "$REPO_WIN/build/bin" .
[ -f "$ZIP" ] || { echo "error: zip creation failed" >&2; exit 1; }

HASH=$(sha256sum "$ZIP" | awk '{print $1}')
[ -n "$HASH" ] || { echo "error: could not hash zip" >&2; exit 1; }
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
    "notes": "zsh built from source with MSYS2; zip served from the develop branch of $ORIGIN. The 'zsh' shim points at zsh-loader.exe (a native launcher), not zsh.cmd: scoop shims for a .cmd target still have to go through cmd.exe's own parser, which can truncate a multi-line -c script at the first newline and mangle characters like | inside quoted arguments. zsh-loader.exe forwards argv to the real interpreter (zsh.exe) untouched."
}
EOF
echo "==> Wrote $BUCKET/zsh.json (url: $PUBLIC_URL)"

# A local-file variant of the manifest, so the install can be tested before
# the zip is committed and pushed to origin/develop.
mkdir -p "$BUILD/local-manifest"
sed "s#\"url\": \".*\"#\"url\": \"file:///$REPO_WIN/build/release/zsh.zip\"#" \
    "$BUCKET/zsh.json" > "$BUILD/local-manifest/zsh.json"

if [ -n "$PACKAGE_ONLY" ]; then
    echo "==> --package-only: zip and manifest refreshed; install left untouched."
    echo "    Install it yourself with:"
    echo "      sh helper/scoop_install.sh"
    echo "    or directly from the local manifest:"
    echo "      scoop install '$REPO_WIN/build/local-manifest/zsh.json'"
    exit 0
fi

# --- 3. Install through scoop ------------------------------------------------
stop_zsh_processes
if scoop list zsh 2>/dev/null | grep -q '^zsh '; then
    echo "==> Removing previously installed zsh..."
    scoop uninstall zsh
fi
echo "==> Clearing scoop download cache for zsh..."
scoop cache rm zsh 2>/dev/null || true
echo "==> Installing via scoop (from local zip)..."
stop_zsh_processes
scoop install "$REPO_WIN/build/local-manifest/zsh.json"

# --- 4. Verify ---------------------------------------------------------------
echo "==> Installed. Shim check:"
SHIM="$SCOOP_HOME/shims/zsh"
if [ ! -x "$SHIM" ] && [ -x "$SCOOP_HOME/shims/zsh.cmd" ]; then
    SHIM="$SCOOP_HOME/shims/zsh.cmd"
fi
run_shim_version "$SHIM"
echo "==> App dir: $SCOOP_HOME/apps/zsh/current"
echo "==> zsh.cmd bootstraps module_path for dynamic modules; run: zsh"
