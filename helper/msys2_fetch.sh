#!/usr/bin/env bash
# msys2_fetch.sh -- fetch MSYS2 packages and their whole dependency closure
#   using only curl + zstd + tar. No pacman, no MSYS2 installation.
#
# 中文:只用 curl + zstd + tar 取得 MSYS2 套件與其完整相依閉包,不需要 pacman,
#   也不需要安裝 MSYS2。適用於「只想要某個工具(GTK4、ffmpeg、llvm)但不想
#   拉進整套 MSYS2」的情境。
#
# Usage / 用法:
#   msys2_fetch.sh [--dest DIR] [--repo NAME] [--dry-run] [--refresh] PKG...
#   msys2_fetch.sh --help
#
#   PKG             short name (gtk4) or full name (mingw-w64-ucrt-x86_64-gtk4)
#   --dest DIR      unpack root (default: <repo>/build/msys2)
#   --repo NAME     ucrt64 (default) | clang64 | mingw64 | msys
#   --dry-run       print the resolved closure and its size, download nothing
#   --refresh       re-download the package database even if it is cached
#   --no-deps       fetch only the packages named, no closure walk
#   --keep-archives keep the .pkg.tar.zst files instead of deleting them
#
# Two traps this script exists to get right. Both were measured on 2026-08-29
# and both fail SILENTLY -- wrong bytes, not an error:
#
#   1. ucrt64, never mingw64. The repos differ in C runtime: ucrt64 links UCRT,
#      mingw64 links the old msvcrt. Mixing them puts two C runtimes in one
#      process, and the symptom is not a link error -- it is a crash somewhere
#      else, later. mingw64 therefore needs an explicit --allow-msvcrt.
#
#   2. Never sort package versions. A version may carry a pacman epoch, written
#      `1~1.4.357.0`, and epoch 1 is NEWER than a version with no epoch -- but
#      `sort -V` treats `~` as sorting before everything. Measured on
#      vulkan-loader: `sort -V | tail -1` picks 1.4.317-2 while the repo's
#      newest is 1~1.4.357.0-1. You get an older package, not an error.
#      This script reads the repo DATABASE, which names the current version
#      outright, so no version comparison happens at all. That is the point:
#      there is no sorting code here to get wrong. The database is also 588 KB
#      against 8.4 MB for the HTML index, and it carries the sha256 as well.
#
# One performance note, because it is a Windows trap rather than a style
# choice: every lookup goes through a shell associative array loaded in ONE
# pass. The first draft called awk once per package instead, and resolving
# gtk4 did not finish in two minutes -- process creation on Windows is
# expensive enough that per-item spawning is a hang, not a slowdown.
set -eu

script_path=$0
case ${1:-} in
    --help|-h)
        sed -n '2,44p' "$script_path" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

REPO=ucrt64
DEST=
DRY_RUN=0
REFRESH=0
NO_DEPS=0
KEEP_ARCHIVES=0
ALLOW_MSVCRT=0
PKGS=""

while [ $# -gt 0 ]; do
    case $1 in
        --dest) DEST=$2; shift 2 ;;
        --repo) REPO=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --refresh) REFRESH=1; shift ;;
        --no-deps) NO_DEPS=1; shift ;;
        --keep-archives) KEEP_ARCHIVES=1; shift ;;
        --allow-msvcrt) ALLOW_MSVCRT=1; shift ;;
        -*) printf 'error: unknown option: %s\n' "$1" >&2
            printf 'try: %s --help\n' "$script_path" >&2
            exit 2 ;;
        *) PKGS="$PKGS $1"; shift ;;
    esac
done

if [ -z "${PKGS# }" ]; then
    printf 'error: no package named\n' >&2
    printf 'try: %s --help\n' "$script_path" >&2
    exit 2
fi

# Trap 1. Refused rather than warned about: the failure this prevents does not
# look like a packaging mistake when it arrives, so a warning that scrolls past
# would not be enough.
case $REPO in
    ucrt64|clang64|msys) : ;;
    mingw64)
        if [ "$ALLOW_MSVCRT" -eq 0 ]; then
            printf 'error: repo mingw64 links the old msvcrt, while ucrt64 links UCRT.\n' >&2
            printf '       Mixing them puts two C runtimes in one process; the symptom is\n' >&2
            printf '       not a link error but a crash elsewhere, later. Use --repo ucrt64,\n' >&2
            printf '       or pass --allow-msvcrt if you have established this is safe.\n' >&2
            exit 2
        fi
        ;;
    *) printf 'error: unknown repo: %s (expected ucrt64, clang64, mingw64 or msys)\n' "$REPO" >&2
       exit 2 ;;
esac

case $REPO in
    ucrt64)  PREFIX=mingw-w64-ucrt-x86_64-; DB_PATH="mingw/ucrt64";  DB_NAME=ucrt64 ;;
    clang64) PREFIX=mingw-w64-clang-x86_64-; DB_PATH="mingw/clang64"; DB_NAME=clang64 ;;
    mingw64) PREFIX=mingw-w64-x86_64-;      DB_PATH="mingw/mingw64"; DB_NAME=mingw64 ;;
    msys)    PREFIX=;                       DB_PATH="msys/x86_64";   DB_NAME=msys ;;
esac

for tool in curl zstd tar sha256sum awk; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'error: required tool not found: %s\n' "$tool" >&2
        exit 3
    }
done

REPO_ROOT=$(cd "$(dirname "$script_path")/.." && pwd)
[ -n "$DEST" ] || DEST="$REPO_ROOT/build/msys2"
CACHE="$DEST/.cache"
DB_DIR="$CACHE/db-$REPO"
DB_FILE="$CACHE/$REPO.db"
BASE_URL="https://repo.msys2.org/$DB_PATH"

mkdir -p "$CACHE"

# --- the database -----------------------------------------------------------
if [ "$REFRESH" -eq 1 ] || [ ! -s "$DB_FILE" ]; then
    printf '==> Fetching %s database...\n' "$REPO"
    curl -fsS --max-time 120 "$BASE_URL/$DB_NAME.db" -o "$DB_FILE.tmp"
    mv -f "$DB_FILE.tmp" "$DB_FILE"
    rm -rf "$DB_DIR"
    rm -f "$CACHE/index-$REPO.tsv" "$CACHE/meta-$REPO.tsv"
fi

if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR"
    zstd -dc "$DB_FILE" | tar -xf - -C "$DB_DIR"
fi

INDEX="$CACHE/index-$REPO.tsv"
META="$CACHE/meta-$REPO.tsv"

# One awk pass over every desc builds both tables. PROVIDES is indexed
# alongside NAME because a dependency may name a provide rather than a real
# package; resolving only NAME reports those as missing when they are present.
if [ ! -s "$INDEX" ] || [ ! -s "$META" ] || [ "$DB_FILE" -nt "$INDEX" ]; then
    awk -v idx="$INDEX.tmp" -v meta="$META.tmp" '
        function flush(   i) {
            if (dir == "") return
            print name "\t" dir > idx
            for (i = 1; i <= np; i++) print prov[i] "\t" dir > idx
            print dir "\t" version "\t" filename "\t" sha "\t" csize "\t" deps > meta
        }
        FNR == 1 {
            flush()
            dir = FILENAME; sub(/\/desc$/, "", dir); sub(/.*\//, "", dir)
            name = ""; version = ""; filename = ""; sha = ""; csize = ""; deps = ""; np = 0
        }
        $0 == "%NAME%"      { getline; name = $0; next }
        $0 == "%VERSION%"   { getline; version = $0; next }
        $0 == "%FILENAME%"  { getline; filename = $0; next }
        $0 == "%SHA256SUM%" { getline; sha = $0; next }
        $0 == "%CSIZE%"     { getline; csize = $0; next }
        $0 == "%PROVIDES%"  {
            while ((getline line) > 0 && line != "") {
                sub(/[<>=].*$/, "", line); prov[++np] = line
            }
            next
        }
        $0 == "%DEPENDS%"   {
            while ((getline line) > 0 && line != "") {
                sub(/[<>=].*$/, "", line)
                if (deps == "") deps = line; else deps = deps "," line
            }
            next
        }
        END { flush() }
    ' "$DB_DIR"/*/desc
    mv -f "$INDEX.tmp" "$INDEX"
    mv -f "$META.tmp" "$META"
fi

declare -A DIR_OF VERSION_OF FILE_OF SHA_OF CSIZE_OF DEPS_OF SEEN

while IFS=$'\t' read -r key dir; do
    [ -n "${DIR_OF[$key]:-}" ] || DIR_OF[$key]=$dir
done < "$INDEX"

while IFS=$'\t' read -r dir version filename sha csize deps; do
    VERSION_OF[$dir]=$version
    FILE_OF[$dir]=$filename
    SHA_OF[$dir]=$sha
    CSIZE_OF[$dir]=$csize
    DEPS_OF[$dir]=$deps
done < "$META"

# --- resolve the closure ----------------------------------------------------
RESOLVED=()
MISSING=()
QUEUE=()

for p in $PKGS; do
    case $p in
        mingw-w64-*) QUEUE+=("$p") ;;
        *)           QUEUE+=("$PREFIX$p") ;;
    esac
done

while [ ${#QUEUE[@]} -gt 0 ]; do
    name=${QUEUE[0]}
    QUEUE=("${QUEUE[@]:1}")

    [ -n "${SEEN[$name]:-}" ] && continue
    SEEN[$name]=1

    dir=${DIR_OF[$name]:-}
    if [ -z "$dir" ]; then
        MISSING+=("$name")
        continue
    fi

    RESOLVED+=("$dir")

    [ "$NO_DEPS" -eq 1 ] && continue

    deps=${DEPS_OF[$dir]:-}
    [ -z "$deps" ] && continue
    old_ifs=$IFS; IFS=,
    for dep in $deps; do
        [ -n "${SEEN[$dep]:-}" ] || QUEUE+=("$dep")
    done
    IFS=$old_ifs
done

# A dependency this repo cannot satisfy is reported, never skipped quietly: the
# unpacked tree would otherwise look complete and fail at run time instead.
if [ ${#MISSING[@]} -gt 0 ]; then
    printf 'warning: not present in %s (left unresolved):\n' "$REPO" >&2
    for m in "${MISSING[@]}"; do printf '  %s\n' "$m" >&2; done
fi

total=0
for dir in "${RESOLVED[@]}"; do
    total=$((total + ${CSIZE_OF[$dir]:-0}))
done

printf '==> %d package(s), %s MiB compressed\n' "${#RESOLVED[@]}" "$((total / 1048576))"

if [ "$DRY_RUN" -eq 1 ]; then
    for dir in "${RESOLVED[@]}"; do
        printf '  %s\n' "$dir"
    done
    exit 0
fi

# --- download, verify, unpack -----------------------------------------------
mkdir -p "$DEST"
for dir in "${RESOLVED[@]}"; do
    file=${FILE_OF[$dir]}
    want=${SHA_OF[$dir]}
    archive="$CACHE/$file"

    if [ ! -s "$archive" ]; then
        printf '==> %s\n' "$file"
        curl -fsS --max-time 600 "$BASE_URL/$file" -o "$archive.tmp"
        mv -f "$archive.tmp" "$archive"
    fi

    # Verified on every run, not only after a download: a cached archive may
    # have been truncated by an interrupted earlier run, and unpacking that
    # gives a tree that is wrong rather than absent.
    got=$(sha256sum "$archive" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
        printf 'error: sha256 mismatch for %s\n' "$file" >&2
        printf '       want %s\n       got  %s\n' "$want" "$got" >&2
        rm -f "$archive"
        exit 4
    fi

    zstd -dc "$archive" | tar -xf - -C "$DEST" \
        --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL
    [ "$KEEP_ARCHIVES" -eq 1 ] || rm -f "$archive"
done

printf '==> Unpacked into %s\n' "$DEST"
