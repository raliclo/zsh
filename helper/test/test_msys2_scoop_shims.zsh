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
    echo expand expr factor false find flock fold getopt grep groups gzip
    head hexdump id install join kill less link ln locale logname ls
    lsattr lzcat lzma m4 make man md5sum mkdir mktemp mv nl nproc od
    paste perl printenv printf ps pwd readlink realpath reset rev rm rmdir
    sed seq sh sha1sum sha256sum sha384sum sha512sum shred shuf sleep sort
    split stat strings stty sum sync tac tail tar tee test time timeout touch
    tr true truncate tset tsort uname unexpand uniq unlink unlzma unxz
    uuidgen wc wget which whoami xargs xzcat yes infocmp tput
    autoconf autoconf-2.13 autoconf-2.69 autoconf-2.71 autoconf-2.72
    autoconf-2.73 autoheader autoheader-2.13 autoheader-2.69
    autoheader-2.71 autoheader-2.72 autoheader-2.73 autom4te
    autom4te-2.69 autom4te-2.71 autom4te-2.72 autom4te-2.73
    autoreconf autoreconf-2.13 autoreconf-2.69 autoreconf-2.71
    autoreconf-2.72 autoreconf-2.73 autoscan autoscan-2.13
    autoscan-2.69 autoscan-2.71 autoscan-2.72 autoscan-2.73
    autoupdate autoupdate-2.13 autoupdate-2.69 autoupdate-2.71
    autoupdate-2.72 autoupdate-2.73 ifnames ifnames-2.13
    ifnames-2.69 ifnames-2.71 ifnames-2.72 ifnames-2.73)

is_script_tool() {
    case $1 in
        autoconf|autoconf-*|autoheader|autoheader-*|autom4te|autom4te-*)
            return 0
            ;;
        autoreconf|autoreconf-*|autoscan|autoscan-*|autoupdate|autoupdate-*)
            return 0
            ;;
        ifnames|ifnames-*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

for tool in "${tools[@]}"; do
    if is_script_tool "$tool"; then
        src="$tmp/scoop/apps/msys2/current/usr/bin/$tool"
        print -r -- '#!/bin/sh' > "$src"
        print -r -- 'exit 0' >> "$src"
    else
        src="$tmp/scoop/apps/msys2/current/usr/bin/$tool.exe"
        : > "$src"
    fi
    : > "$tmp/scoop/shims/$tool.exe"
    print -r -- 'old ps1 wrapper' > "$tmp/scoop/shims/$tool-msys2.ps1"
    chmod 755 "$src" "$tmp/scoop/shims/$tool.exe"
done

(
    emulate -L zsh
    setopt err_return no_unset
    SCOOP="$tmp/scoop"
    HOME="$tmp/home"
    MSYS2_SCOOP_SHIMS_NO_VERIFY=1
    source "$script" "${tools[@]}" >/dev/null
)

missing=0
for tool in "${tools[@]}"; do
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
    if [[ "$(<"$tmp/scoop/shims/$tool-msys2.ps1")" != *"legacy PowerShell wrapper is intentionally disabled"* ]]; then
        print -ru2 -- "stale ps1 wrapper was not disabled: $tmp/scoop/shims/$tool-msys2.ps1"
        missing=1
    fi
    wrapper_body=$(<"$wrapper")
    if is_script_tool "$tool"; then
        expected_path="/apps/msys2/current/usr/bin/$tool"
        expected_launcher="/apps/msys2/current/usr/bin/sh.exe"
    else
        expected_path="/apps/msys2/current/usr/bin/$tool.exe"
        expected_launcher=$expected_path
    fi
    if [[ $wrapper_body != *"$expected_path"* ||
          $wrapper_body != *"$expected_launcher"* ||
          $wrapper_body != *"MSYS2_BIN="* ||
          $wrapper_body != *"PATH=%MSYS2_BIN%;%PATH%"* ||
          $wrapper_body != *"CHERE_INVOKING=1"* ||
          $wrapper_body != *"MSYS2_ARG_CONV_EXCL=*"* ||
          $wrapper_body != *"%*"* ]]; then
        print -ru2 -- "wrong cmd boundary wrapper for $tool: $(<"$wrapper")"
        missing=1
    fi
done

exit $missing
