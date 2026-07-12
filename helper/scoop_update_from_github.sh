#!/bin/sh
# scoop_update_from_github.sh - Reinstall zsh from the GitHub-backed Scoop bucket.
#
# Usage:
#   sh helper/scoop_update_from_github.sh
#
# This intentionally uses the public GitHub bucket path rather than the local
# build/local-manifest flow in helper/scoop_install.sh.

set -e

BUCKET_NAME=zsh
BUCKET_URL=https://github.com/raliclo/zsh.git
APP_NAME=zsh

command -v scoop >/dev/null 2>&1 || {
    echo "error: scoop not found; run helper/install_build_tool.sh first" >&2
    exit 1
}

stop_zsh_processes() {
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command \
            "Get-Process zsh,zsh-c,zsh-loader -ErrorAction SilentlyContinue | Stop-Process -Force" \
            >/dev/null 2>&1 || true
    fi
}

echo "==> Stopping running zsh processes..."
stop_zsh_processes

echo "==> Uninstalling existing $APP_NAME app, if present..."
scoop uninstall "$APP_NAME" >/dev/null 2>&1 || true

echo "==> Removing existing $BUCKET_NAME bucket, if present..."
scoop bucket rm "$BUCKET_NAME" >/dev/null 2>&1 || true

echo "==> Adding $BUCKET_NAME bucket from $BUCKET_URL..."
scoop bucket add "$BUCKET_NAME" "$BUCKET_URL"

echo "==> Installing $APP_NAME from $BUCKET_NAME bucket..."
scoop install "$APP_NAME"

echo "==> Installed version:"
scoop list "$APP_NAME"
