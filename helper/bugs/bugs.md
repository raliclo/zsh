# Windows / WSL environment traps

Findings that cost real debugging time on this port. They share a shape: the
tooling does not fail, it returns **plausible wrong data**, so the mistake
surfaces far from its cause and the first conclusion drawn from it is wrong.

Each entry records what was measured, not what was assumed.

---

## `wsl.exe` runs your arguments through the WSL login shell

`wsl.exe -- ... '...'` loses `$var` even inside single quotes. Measured with
`od -c` on what actually arrives:

```
send 'A$pB'  ->  receives  A        (1 byte -- $pB gone)
send 'A_pB'  ->  receives  A_pB     (4 bytes -- intact)
```

**Corrected 2026-08-29.** This entry used to blame Git Bash for consuming the
quotes, and the local shell for being the problem. Both were wrong, and the
first is the kind of wrong that sends someone to change the wrong thing:

- **The local shell is irrelevant.** The same call from the packaged zsh loses
  exactly the same byte. Removing quotes is what every POSIX shell correctly
  does with its own syntax; there is no Git Bash quirk here to escape.
- **A shell runs on the far side even when you did not ask for one.**
  `wsl.exe -- printf '%s' '[$HOME]'` — `printf` expands nothing and there is no
  `sh -c` anywhere — answers `zsh:1: no matches found: [/home/lowei]`. So
  `$HOME` was substituted and `[...]` was globbed. `wsl.exe -- sh -c 'printf %s
  "\$SHELL"'` returns `/usr/bin/zsh`: the command is handed to the WSL **login
  shell**, not exec'd.

**It is not only `$`.** Every metacharacter that shell has is live, and the
dangerous case is the one that succeeds:

```
'/etc/hostn*me'        ->  /etc/hostname      # SILENTLY a different string
'/nonexistent/zz*qq'   ->  zsh: no matches found   # loud, therefore harmless
'$HOME'                ->  /home/lowei        # silently substituted
'$UNDEFINED'           ->  (empty)            # silently emptied
```

A glob that matches, and a variable that is set, both hand back a plausible
wrong value at exit 0. A glob that matches nothing is the *safe* case, because
it fails loudly.

**Why it is expensive.** The failure is a false negative, not an error:

```zsh
p=/usr/local/swift/...; [ -x "$p" ]     # $p arrives empty
[ -x "" ]                                # false -- "no toolchain"
```

The toolchain was present the whole time. A wrong conclusion ("the
environments are inconsistent") was drawn and chased before the argument
transit was suspected.

**Fix — `--exec`, which skips that shell entirely.** Measured 2026-08-29:

```
                        wsl.exe --          wsl.exe --exec
'A$pB'                  A                   A$pB
'/etc/hostn*me'         /etc/hostname       /etc/hostn*me
'[$HOME]'               zsh: no matches     [$HOME]
```

This is better than escaping, because escaping requires knowing in advance
every metacharacter the far-side shell has, and getting one wrong is silent.
`--exec` removes the shell, so there is nothing to escape and an explicit
`--exec zsh -lc '...'` still expands its own `$var` exactly once, as written.
Pinned by `test_wsl_exec_preserves_argv` in
`helper/test/test_windows_packaging.zsh`, asserted through a real `wsl.exe`
call rather than by reading a script — the claim is about what crosses the
boundary.

**Fallback when the far-side shell is wanted — escape what it would eat:**

```zsh
wsl.exe -- zsh -lc 'p=/usr/bin; [ -x "\$p" ] && echo YES; echo "p=[\$p]"'
# -> YES  p=[/usr/bin]
```

One level of `\$` is enough; `\\$` behaves identically. The same applies to
`*`, `?` and `[...]` — escape them, or the far-side shell resolves them against
*its* filesystem. Note what does NOT need escaping and why: `$(...)` is
untouched here because the LOCAL shell already replaced it with its value
before `wsl.exe` was called, so no metacharacter ever crosses. Passing the script as
a **file** is steadier still, since it removes the guessing about how many
layers are consuming characters — but see the next entry, because the obvious
way to do that fails too.

---

## `/mnt/...` paths are rewritten before `wsl.exe` sees them

The natural fix for the above — put the script in a file and pass its path —
runs straight into MSYS argument conversion:

```
wsl.exe -- zsh /mnt/c/Users/.../script.sh
zsh: can't open input file:
     C:/Users/lowei/scoop/apps/git/2.54.0/mnt/c/Users/.../script.sh
```

Git Bash rewrote `/mnt/c/...` by prepending its own MSYS root. Confirm the
root it uses with `cygpath -m /`.

**Fix — disable the conversion for this call:**

```zsh
MSYS2_ARG_CONV_EXCL='*' wsl.exe -- zsh /mnt/c/Users/.../script.sh
```

This is required for `wsl.exe` specifically, because the callee genuinely
wants POSIX paths. Do **not** apply it blanketly to native Windows binaries:
with conversion off, a Windows `zsh.exe` handed `/tmp/...` cannot open the
file at all.

Note these two traps compound. Escaping `$` avoids the first; passing a file
avoids the first but triggers the second. A call that does both needs
`MSYS2_ARG_CONV_EXCL` *and* correct quoting.

---

## Bundled tools do not resolve `/c/...` when invoked from outside

The packaged `stat.exe` (and every other bundled MSYS binary) fails on POSIX
drive paths when launched directly from Git Bash, yet works from inside the
packaged zsh:

```
from Git Bash:  ./build/bin/stat.exe -c%s /c/.../README
                -> cannot stat: No such file or directory
from zsh:       stat -c%s /c/.../README
                -> 48231
```

It is the same binary, and it does import `msys-2.0.dll`, so it understands
`/c/` in principle. The cause is that `build/bin/msys-2.0.dll`, run standalone
without the rest of an MSYS2 install tree, resolves `/` relative to the
calling process's cwd rather than a real filesystem root — the limitation
already documented in `helper/test/test_windows_packaging.zsh`.

**Rule:** use the bundled tools *through* the packaged zsh. If a call from
Git Bash is unavoidable, pass `C:/...` form, which works.

---

## `MSYS2_ARG_CONV_EXCL='*'` breaks `//F`, and the kill silently does not happen

`taskkill //F //IM foo.exe` — the standard Git Bash spelling — failed inside
the packaged zsh with `ERROR: Invalid argument/option - '//F'`, **and the
target process stayed alive**. It was not a zsh defect: the cause was our own
wrapper, which set the blanket exclusion.

The two spellings are correct in *opposite* contexts, which is what made this
expensive to chase — muscle memory from Git Bash is wrong here, and nothing
said so. Measured (nonexistent image name, so nothing dies):

| context | conversion | `//F //IM` | `/F /IM` | `-f -im` |
|---|---|---|---|---|
| Git Bash | on | ok | `Invalid argument 'F:/'` | ok |
| `zsh -f` (no zshrc) | on | ok | `Invalid argument 'F:/'` | ok |
| packaged zsh, old wrapper | **off** | `Invalid argument '//F'` | ok | ok |

Single-slash `/F` is rewritten into the path `F:/` when conversion is on, which
is exactly why the `//F` idiom exists. Turning conversion fully off with `'*'`
protects `/F` but also suppresses MSYS's own `//x` → `/x` collapse, so `//F`
arrives literally.

End-to-end against a real process — the reason this rates an entry rather than
a footnote:

```
//F //IM   rc=1  alive_after=1   *** SURVIVED ***
/F  /IM    rc=0  alive_after=0   killed
-f  -im    rc=0  alive_after=0   killed
```

`taskkill` does report failure, but a caller that does not check the exit
status reads "killed" from a command that killed nothing.

**Fix — exclude the option prefixes, not everything** (`helper/compile.sh`):

```zsh
MSYS2_ARG_CONV_EXCL='/F;/FI;/IM;/P;/PID;/S;/T;/U' command taskkill.exe "$@"
```

Now `/F` is protected from conversion *and* `//F` still reaches the collapse,
so **both spellings work**. The lists come from `taskkill /?` and `tasklist /?`
verbatim; neither tool accepts a POSIX path, so scoping costs nothing. Note
this does **not** generalize to `wsl.exe`, which genuinely receives POSIX paths
and must keep `'*'`.

`tasklist` had the same hole and was not wrapped at all (`/FI` became
`<cwd>/FI`); it is wrapped now. Pinned by
`test_taskkill_accepts_both_slash_forms` in
`helper/test/test_windows_packaging.zsh`.

**Portable spelling:** `taskkill -f -im name.exe` works in every context above,
conversion on or off, so it needs no knowledge of which mode you are in.

---

## `local path` (and `path=`, `for path in`) silently empties `PATH`

Not Windows-specific — a zsh-language trap, identical on macOS/Linux — but it
bit this port during the sh→zsh conversion and shares the same shape as the
entries above: no error, just plausible wrong state that surfaces far away.

`path` is tied to `PATH` as an array, so spelling it as an ordinary variable
touches the real `PATH`. Measured on this build:

```
zsh -f -c 'f(){ local path; print in $#PATH }; print before $#PATH; f; print after $#PATH'
before 1879
in     0            # PATH emptied for the function's lifetime
after  1879         # ...and restored on return

zsh -f -c 'f(){ local path; ls / }; ls /; f'
top:     ls FOUND
in-func: ls NOT FOUND (rc=127)     # every PATH lookup fails inside f
after:   ls FOUND
```

The self-healing is what makes it worse than a top-level `path=(...)`: the
breakage vanishes the instant control leaves the function, so the failure is
read as "the tool is missing" rather than "PATH was clobbered here." Same trap
applies to `for path in ...` (each iteration assigns `path`) and to `watch`,
`status`, `options`, `cdpath`, `manpath`, `fpath`, `argv`, `fignore`.

**This is not a zsh defect and must not be patched** — the `path`/`PATH`
tie-in is deliberate. The fix is at the usage level: never spell these as plain
variables (`path`→`dir_path`, `watch`→`watch_list`). `module_path` is exempt —
it is essentially always meant as the special parameter. Enforced by
`helper/test/test_reserved_param_names.zsh`, which fails the build if any helper
script reintroduces one; opt out for a genuinely-intended special parameter
with a `reserved-param-ok` comment on the line.

---

## "Sources newer than the binary" is normal here, for exactly four files

A freshness check of the usual shape —

```zsh
find Src -name '*.c' -newer build/bin/zsh.exe
```

— reports three or four files on a tree that was just built successfully:

```
Src/hist.c           content matches HEAD (mtime only)
Src/subst.c          content matches HEAD (mtime only)
Src/Zle/zle_move.c   content matches HEAD (mtime only)
```

Nothing is stale. Those are the **patch targets**, and `compile.sh` restores
them to pristine *after* the build (`restore_zle_backup`, armed as an EXIT trap
at line 238 and run at 966, after `Assembling portable runtime` at 389). The
restore rewrites the files, so their mtime lands after the binary's by design.

**Why it matters.** mtime is the obvious way to ask "was this binary built from
this source", and it is the check the csv2 tree's `STALE BINARY` guard uses.
On *this* repo that question needs asking differently, because the answer is a
false positive on every successful build — and a guard that cries wolf on every
run is one people learn to skip.

**Ask about content, not timestamps:**

```zsh
git diff --quiet HEAD -- "$f"    # true when the file matches what was built
```

The four affected files are exactly `helper/patches/`' targets: `Src/hist.c`,
`Src/subst.c`, `Src/Zle/zle.h`, `Src/Zle/zle_move.c`. Any other source turning
up newer than the binary IS a real staleness signal and should be treated as
one.
