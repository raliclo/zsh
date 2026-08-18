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
