# Windows / WSL environment traps

Findings that cost real debugging time on this port. They share a shape: the
tooling does not fail, it returns **plausible wrong data**, so the mistake
surfaces far from its cause and the first conclusion drawn from it is wrong.

Each entry records what was measured, not what was assumed.

---

## `$` is eaten crossing the Windows → WSL boundary

`wsl.exe -- zsh -lc '...'` loses `$var` even inside single quotes. Measured
with `od -c` on what actually arrives:

```
send 'A$pB'  ->  receives  A        (1 byte -- $pB gone)
send 'A_pB'  ->  receives  A_pB     (4 bytes -- intact)
```

Three layers, none of them zsh:

1. Git Bash consumes the quotes — they are its own syntax
2. `wsl.exe` receives the bare argument `A$pB` and reassembles a command line
3. The Linux-side shell sees an **unquoted** `$pB`, expands it, gets nothing

**Why it is expensive.** The failure is a false negative, not an error:

```zsh
p=/usr/local/swift/...; [ -x "$p" ]     # $p arrives empty
[ -x "" ]                                # false -- "no toolchain"
```

The toolchain was present the whole time. A wrong conclusion ("the
environments are inconsistent") was drawn and chased before the argument
transit was suspected.

**Fix — escape the `$`:**

```zsh
wsl.exe -- zsh -lc 'p=/usr/bin; [ -x "\$p" ] && echo YES; echo "p=[\$p]"'
# -> YES  p=[/usr/bin]
```

One level of `\$` is enough; `\\$` behaves identically. Passing the script as
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
