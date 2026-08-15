#!/bin/sh
# regen_checksum.sh - Regenerate helper/patches/checksum.txt.
#
# Run this after confirming windows-zle-surrogate-pairs.patch still
# applies correctly and still means what its comments say against the
# CURRENT Src/Zle/zle.h and Src/Zle/zle_move.c -- e.g. after an upstream
# zsh sync touched either file. It records a checksum of the *pristine*
# (unpatched) files, so run it against a clean working tree: if the patch
# is currently applied, revert it first (`git apply -R
# helper/patches/windows-zle-surrogate-pairs.patch`) or just `git
# checkout -- Src/Zle/zle.h Src/Zle/zle_move.c`.
#
# Usage (from Git Bash or any POSIX shell, from anywhere in the repo):
#   sh helper/regen_checksum.sh

set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

if grep -q ZSH_IS_HIGH_SURROGATE Src/Zle/zle.h 2>/dev/null; then
    echo "error: Src/Zle/zle.h has the ZLE patch applied right now; checksum.txt" >&2
    echo "       must be generated from the pristine (unpatched) files. Revert it" >&2
    echo "       first: git apply -R helper/patches/windows-zle-surrogate-pairs.patch" >&2
    echo "       or: git checkout -- Src/Zle/zle.h Src/Zle/zle_move.c" >&2
    exit 1
fi
if grep -q cygdrivepath Src/hist.c 2>/dev/null; then
    echo "error: Src/hist.c has the drive-path patch applied right now;" >&2
    echo "       checksum.txt must be generated from the pristine files. Revert" >&2
    echo "       it first: git apply -R helper/patches/windows-drive-abspath.patch" >&2
    echo "       or: git checkout -- Src/hist.c Src/subst.c" >&2
    exit 1
fi

{
    echo "# sha256 checksums of the pristine (unpatched) files that the patches"
    echo "# in helper/patches/ were written against."
    echo "#   zle.h, zle_move.c -> windows-zle-surrogate-pairs.patch"
    echo "#   hist.c, subst.c   -> windows-drive-abspath.patch"
    echo "# Verified with: sha256sum -c helper/patches/checksum.txt"
    echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sha256sum Src/Zle/zle.h Src/Zle/zle_move.c Src/hist.c Src/subst.c
} > helper/patches/checksum.txt

echo "==> Wrote helper/patches/checksum.txt:"
cat helper/patches/checksum.txt

echo "==> Verifying it reads back cleanly..."
# Not all sha256sum implementations skip '#' comment lines in --check
# mode (GNU coreutils does; some don't and report each as a bogus
# FAILED entry), so strip them here instead of relying on that.
grep -v '^#' helper/patches/checksum.txt | sha256sum -c -

echo "==> Reminder: this only re-checksums the pristine files. If zle.h or"
echo "    zle_move.c actually changed, review whether"
echo "    helper/patches/windows-zle-surrogate-pairs.patch still applies"
echo "    cleanly and still does what its comments say -- regenerate the"
echo "    patch itself (git diff after re-applying the fix by hand) if not."
