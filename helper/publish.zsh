#!/usr/bin/env zsh
# publish.zsh -- upload a packaged portable zsh to the stable GitHub Release.
#
# 中文:把打包好的可攜式 zsh 上傳到固定的 GitHub Release tag,並在上傳後
#   「從 GitHub 讀回來」核對,而不是相信上傳工具自己的回報。
#
# Usage / 用法:
#   publish.zsh --archive PATH --version V [--tag TAG] [--repo OWNER/NAME]
#   publish.zsh --dry-run --archive PATH --version V
#   publish.zsh --help
#
#   --archive PATH   the .tar.zst to publish (required)
#   --version V      build version string, for the release notes (required)
#   --tag TAG        release tag; default $ZSH_RELEASE_TAG or zsh-portable
#   --repo O/N       GitHub repo; default derived from the 'ralic' remote
#   --commit SHA     recorded in the notes and used as --target on creation;
#                    default HEAD of the repo this script lives in
#   --dry-run        print what would be done, touch nothing
#
# Extracted from scoop_install.sh on 2026-10-08. It was inline there, which
# meant the only way to publish was to run the whole package-and-install flow;
# re-publishing an archive that already existed required editing the script or
# calling gh by hand, and a hand-run gh call is exactly where the --clobber and
# the superseded-asset cleanup get forgotten.
#
# Two behaviours here are not optional, both bought by failures:
#
#   * The superseded `zsh.zip` is deleted. Nothing pins it once the manifest
#     moves to .tar.zst, so it stays downloadable and looks current forever.
#
#   * The upload is VERIFIED by reading the asset list back from GitHub and
#     comparing the archive's own sha256 against the uploaded copy. `gh` exits
#     0 on an upload that produced the wrong bytes, and the half that fails is
#     the half nobody inspects -- a release can be perfect while the install is
#     stale, or the reverse.
set -eu
setopt no_unset

script_path=${0:A}

case ${1:-} in
    --help|-h)
        sed -n '2,30p' "$script_path" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

archive= version= tag= repo= commit= dry_run=

while (( $# )); do
    case $1 in
        --archive) archive=${2:?--archive needs a path}; shift 2 ;;
        --version) version=${2:?--version needs a value}; shift 2 ;;
        --tag)     tag=${2:?--tag needs a value}; shift 2 ;;
        --repo)    repo=${2:?--repo needs OWNER/NAME}; shift 2 ;;
        --commit)  commit=${2:?--commit needs a sha}; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) printf 'error: unknown option: %s\n' "$1" >&2
           printf 'try: %s --help\n' "$script_path" >&2
           exit 2 ;;
    esac
done

[[ -n $archive ]] || { printf 'error: --archive is required\n' >&2; exit 2 }
[[ -n $version ]] || { printf 'error: --version is required\n' >&2; exit 2 }
[[ -s $archive ]] || { printf 'error: archive is missing or empty: %s\n' "$archive" >&2; exit 1 }

repo_root=${script_path:h:h}
: ${tag:=${ZSH_RELEASE_TAG:-zsh-portable}}

# The fork, not 'origin': origin is the upstream we forked FROM
# (zsh-users/zsh), per helper/README-win.md. Pushing a build there would be
# wrong in a way that is hard to undo.
if [[ -z $repo ]]; then
    local remote_url
    if remote_url=$(git -C "$repo_root" remote get-url ralic 2>/dev/null); then
        :
    else
        remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || {
            printf 'error: no ralic or origin remote; pass --repo OWNER/NAME\n' >&2
            exit 1
        }
    fi
    repo=${remote_url#*github.com[:/]}
    repo=${repo%.git}
fi

: ${commit:=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)}

archive_name=${archive:t}
want_sha=$(sha256sum "$archive" | awk '{print $1}')

printf '==> Publishing %s\n' "$archive_name"
printf '    repo    : %s\n' "$repo"
printf '    tag     : %s\n' "$tag"
printf '    version : %s\n' "$version"
printf '    commit  : %s\n' "$commit"
printf '    sha256  : %s\n' "$want_sha"
printf '    bytes   : %s\n' "$(wc -c < "$archive")"

if [[ -n $dry_run ]]; then
    printf '==> --dry-run: nothing uploaded\n'
    exit 0
fi

command -v gh >/dev/null 2>&1 || {
    printf 'error: gh not found; install the GitHub CLI\n' >&2
    exit 1
}

notes="Portable zsh build

Version: $version
Commit: $commit
Asset: $archive_name
"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$repo" --title 'zsh portable' --notes "$notes"
    gh release upload "$tag" "$archive" --repo "$repo" --clobber
    # Not fatal if it is already gone.
    if gh release delete-asset "$tag" zsh.zip --repo "$repo" --yes 2>/dev/null; then
        printf '==> Removed the superseded zsh.zip asset\n'
    fi
else
    gh release create "$tag" "$archive" \
        --repo "$repo" --target "$commit" \
        --title 'zsh portable' --notes "$notes"
fi

# --- verify, by reading back rather than trusting the upload -----------------
printf '==> Verifying the published asset...\n'
typeset -a assets
assets=(${(f)"$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' 2>/dev/null)"})
if (( ! ${assets[(Ie)$archive_name]} )); then
    printf 'error: %s is not on release %s after upload. Assets: %s\n' \
        "$archive_name" "$tag" "${assets[*]:-<none>}" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT INT TERM HUP
url="https://github.com/$repo/releases/download/$tag/$archive_name"
if ! curl -fsSL --max-time 600 "$url" -o "$tmp/dl"; then
    printf 'error: could not download %s back for verification\n' "$url" >&2
    exit 1
fi
got_sha=$(sha256sum "$tmp/dl" | awk '{print $1}')
if [[ $got_sha != $want_sha ]]; then
    printf 'error: the published asset does not match what was uploaded.\n' >&2
    printf '       local  %s\n       remote %s\n' "$want_sha" "$got_sha" >&2
    exit 1
fi

printf '==> Published and verified: %s on %s (%s)\n' "$archive_name" "$tag" "$repo"
printf '==>   %s\n' "$url"
