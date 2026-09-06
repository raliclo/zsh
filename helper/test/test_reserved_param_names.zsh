#!/usr/bin/env zsh
# test_reserved_param_names.zsh -- fail if any of our Windows helper scripts
#   uses a zsh special-parameter name (path, watch, ...) as an ordinary
#   variable. Those names are tied to real machinery, so the misuse is silent.
#
# 中文:防止把 zsh 的特殊參數名當成普通變數用。`path` 與 `PATH` 連動成陣列,
#   所以 `path=(...)`、`local path`、`for path in`、`read path` 會在函式期間
#   悄悄清空 PATH(實測:長度 1879 -> 0,函式返回後自癒),`watch` 則觸發
#   zsh/watch 模組載入 -- 兩者都不報錯,症狀出現在離現場很遠的地方。
#
# Runs under run_all_tests.bat, which passes build/bin then the repo root:
#   zsh-loader.exe -f test_reserved_param_names.zsh <build/bin> <repo-root>
# Usage / 用法:
#   --help    print this synopsis and exit, scanning nothing
#
# It is NOT a defect in zsh -- the path<->PATH tie-in is deliberate and behaves
# identically on macOS/Linux. There is nothing to patch; the fix is to never
# spell these names as plain variables. To use one intentionally as its special
# self, put the marker `reserved-param-ok` in a comment on that line.
set -eu

script_path=${0//\\//}
if [[ $script_path == [A-Za-z]:/* ]]; then
    script_path="/${(L)script_path[1]}/${script_path[4,-1]}"
else
    script_path=${script_path:A}
fi

case ${1:-} in
    --help|-h)
        sed -n '2,19p' "$script_path" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

emulate -L zsh
setopt no_unset extended_glob

# Repo root: prefer the argument the runner passes ($2); fall back to walking
# up from this file. Both spellings normalized to POSIX drive form.
if [[ -n ${2:-} ]]; then
    repo=${2//\\//}
    if [[ $repo == [A-Za-z]:/* ]]; then
        repo="/${(L)repo[1]}/${repo[4,-1]}"
    else
        repo=${repo:A}
    fi
else
    repo=${script_path:h:h:h}
fi

# The names zsh ties to live machinery. module_path is deliberately absent: it
# is essentially always meant as the special parameter (our compile.sh and the
# other tests set it on purpose to load dynamic modules), so guarding it would
# be all false positives.
names='path|watch|status|options|argv|fignore|cdpath|manpath|fpath'

# Matched with zsh glob patterns, not `=~`: the regex operator needs the
# zsh/regex module, which -- like zsh/watch -- will not load under `zsh -f` on
# a build whose modules are not at the compiled-in default. Globs are builtin.
#
# `pre` is "line-start, or anything ending in a boundary char"; it is what keeps
# `mypath=` and `module_path=` (no boundary before `path`) from matching. `n` is
# the name alternation. `sfx` is "end-of-word": end of line, or a non-word char
# -- so `path_var` and `pathological` never match. `##` = one-or-more, `#` =
# zero-or-more (extended_glob). `=` has a space before it in `printf 'path ='`,
# so an assignment `NAME=` cannot match that string either.
n="(${names})"
pre='(*[[:space:];&|(){}]|)'
sfx='(|[^[:alnum:]_]*)'
flags='([[:space:]]##-[^[:space:]]##)#'
assign="${pre}${n}(|[+])=*"
declare_bare="${pre}(local|typeset|declare|readonly|integer|float|export)${flags}[[:space:]]##${n}${sfx}"
for_loop="${pre}for[[:space:]]##${n}${sfx}"
read_into="${pre}read${flags}[[:space:]]##${n}${sfx}"

# A colon straight after an UNBRACED parameter is a history modifier, not a
# literal colon. `"$root:libcrux"` expands to the lowercased $root with the `l`
# eaten and `ibcrux` appended -- and `zsh -n` passes it, so the usual syntax
# check is no help. Measured: of 19 letters, twelve change the value and eleven
# do so silently; only `:s` says anything. Bracing ends the parameter name and
# disarms it, which is why the fix is free.
#
# Any letter is flagged, not just today's dangerous ones: a name beginning with
# a currently-inert letter (`:openssh-portable` is fine) becomes wrong the day
# it is renamed, and "safe because of its first letter" is not a property worth
# depending on. Braces, digits, `$`, `/` and `:` itself are all left alone --
# `"${p}:x"`, `"$host:8080"`, `"$proto://x"`, `"$a:$b"` do not match.
# `[$]` and not `\$`: a backslash escape does not survive the `$~var` expansion
# that turns this string into a pattern, so the `\$` form silently matches
# nothing and the check passes everything. Verified both ways before trusting
# it -- a lint that cannot fail is worse than no lint.
colon_modifier='*[$][A-Za-z_][A-Za-z0-9_]#:[A-Za-z]*'

files=($repo/helper/**/*.sh(N) $repo/helper/**/*.zsh(N))
files=(${files:#*/helper/patches/*})              # patches carry upstream code
files=(${files:#*/test_reserved_param_names.zsh}) # this file names them on purpose

typeset -a hits colon_hits
for f in $files; do
    typeset -i lineno=0
    while IFS= read -r line; do
        lineno=$(( lineno + 1 ))
        line=${line%$'\r'}                         # defensive; repo is LF-only
        [[ $line == [[:space:]]#\#* ]] && continue
        [[ $line == *reserved-param-ok* ]] && continue
        if [[ $line == $~assign || $line == $~declare_bare ||
              $line == $~for_loop || $line == $~read_into ]]; then
            hits+="${f#$repo/}:$lineno: ${line##[[:space:]]#}"
        elif [[ $line == $~colon_modifier ]]; then
            colon_hits+="${f#$repo/}:$lineno: ${line##[[:space:]]#}"
        fi
    done < $f
done

if (( ${#hits} )); then
    printf '%s\n' "reserved zsh special-parameter name used as an ordinary variable:" >&2
    printf '  %s\n' "${hits[@]}" >&2
    printf '%s\n' "-> rename it (path->dir_path, watch->watch_list, ...) or, if the" >&2
    printf '%s\n' "   special parameter is genuinely intended, add a 'reserved-param-ok'" >&2
    printf '%s\n' "   comment on that line. See helper/bugs/bugs.md." >&2
    exit 1
fi

if (( ${#colon_hits} )); then
    printf '%s\n' "a colon after an unbraced parameter is a history modifier, not a literal:" >&2
    printf '  %s\n' "${colon_hits[@]}" >&2
    printf '%s\n' '-> brace the parameter: "$root:libcrux" -> "${root}:libcrux".' >&2
    printf '%s\n' '   Unbraced, zsh reads :l as the lowercase modifier and produces the' >&2
    printf '%s\n' '   lowercased value with the l eaten -- silently, and zsh -n passes it.' >&2
    printf '%s\n' "   Add 'reserved-param-ok' on the line if the modifier is intended." >&2
    exit 1
fi

printf 'scanned %d helper script(s); no reserved-name misuse, no unbraced :modifier\n' ${#files}
exit 0
