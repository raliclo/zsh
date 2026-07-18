#!/usr/bin/env zsh
set -eu
zmodload -F zsh/files b:mkdir b:rm b:chmod

repo=${0:A:h:h:h}
script=$repo/helper/msys2_scoop_shims.sh
tmp=$repo/build/tmp/zsh-msys2-scoop-shims-test.$$

cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT INT TERM

mkdir -p -- "$tmp/scoop/apps/msys2/current/usr/bin" "$tmp/scoop/shims"

tools=('[' ar arch ash awk base32 base64 basename bash cal cat chattr
    chmod cksum clear cmp comm cp cut date dd df diff dirname du env
    expand expr factor false find flock fold getopt grep groups gzip
    head hexdump id install join kill less link ln logname ls lsattr
    lzcat lzma make man md5sum mkdir mktemp mv nl nproc od paste
    printenv ps pwd readlink realpath reset rev rm rmdir sed seq sh
    sha1sum sha256sum sha384sum sha512sum shred shuf sleep sort split
    stat strings stty sum sync tac tail tar tee test time timeout touch
    tr true truncate tsort uname unexpand uniq unlink unlzma unxz
    uuidgen wc wget which whoami xargs xzcat yes)

for tool in $tools; do
    : > "$tmp/scoop/apps/msys2/current/usr/bin/$tool.exe"
    : > "$tmp/scoop/shims/$tool.exe"
    chmod 755 "$tmp/scoop/apps/msys2/current/usr/bin/$tool.exe" "$tmp/scoop/shims/$tool.exe"
done

(
    emulate -L zsh
    setopt err_return no_unset
    SCOOP="$tmp/scoop"
    HOME="$tmp/home"
    source "$script" >/dev/null
)

missing=0
for tool in $tools; do
    shim=$tmp/scoop/shims/$tool.shim
    wrapper=$tmp/scoop/shims/$tool-msys2.cmd
    if [[ ! -f $shim ]]; then
        print -ru2 -- "missing shim metadata: $shim"
        missing=1
        continue
    fi
    if [[ "$(<"$shim")" != *"cmd.exe"* ||
          "$(<"$shim")" != *"args = /d /c "*"${tool}-msys2.cmd"* ||
          "$(<"$shim")" == *"args = /d /c \"*" ]]; then
        print -ru2 -- "wrong shim metadata for $tool: $(<"$shim")"
        missing=1
    fi
    if [[ ! -f $wrapper ]]; then
        print -ru2 -- "missing cmd boundary wrapper: $wrapper"
        missing=1
        continue
    fi
    if [[ "$(<"$wrapper")" != *"/apps/msys2/current/usr/bin/$tool.exe"* ||
          "$(<"$wrapper")" != *"MSYS2_ARG_CONV_EXCL=*"* ||
          "$(<"$wrapper")" != *"%*"* ]]; then
        print -ru2 -- "wrong cmd boundary wrapper for $tool: $(<"$wrapper")"
        missing=1
    fi
done

exit $missing
