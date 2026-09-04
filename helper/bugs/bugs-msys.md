# MSYS runtime traps

Caused by the MSYS2 runtime — argument conversion on the way to a native
Windows binary, and path resolution inside `msys-2.0.dll`.

**These surface on whatever program happens to be called**, which is why they
are filed by cause and not by symptom: the same non-conversion showed up as
`Invalid switch` from `attrib.exe`, as `does not exist` from a Swift binary,
and as a silently unquoted path from `cmd.exe echo`. None of those programs is
at fault. Index: [bugs.md](bugs.md).

---

## `/mnt/...` paths are rewritten before `wsl.exe` sees them

Putting a script in a file and passing its path — the natural fix for the
[WSL login-shell trap](bugs-wsl.md) — runs straight into MSYS argument
conversion:

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

Note this trap and the WSL one compound. Escaping `$` avoids the first;
passing a file avoids the first but triggers this one. A call that does both
needs `MSYS2_ARG_CONV_EXCL` *and* correct quoting.

---

## MSYS declines to convert a path when a middle component is a regular file

The other conversion traps here are all "the argument was rewritten when it
should not have been". This is the same family with the sign flipped: **the
argument was NOT rewritten when it should have been**, and nothing said so.

MSYS converts POSIX paths to Windows form when handing them to a native binary.
It does that for a path through a directory, and for a path through a component
that does not exist — but not for one through a regular **file**. Measured with
two unrelated native programs, so neither of them is the cause:

```
                       cmd.exe echo                    attrib.exe
mid=realdir  (dir)     C:/Users/.../realdir/out.txt    File not found - C:/...
mid=afile    (file)    /c/Users/.../afile/out.txt      Invalid switch - /c/...
mid=nosuch   (missing) C:/Users/.../nosuch/out.txt     Path not found - C:\...
```

`attrib` says *Invalid switch* because the unconverted argument still starts
with `/`, which it reads as an option introducer — a second, unrelated way for
the same non-conversion to surface as something that looks like a usage error.

**The mechanism is visible in `cygpath`, which does the same resolution out
loud:**

```
$ cygpath -m /c/Users/.../afile/out.txt
cygpath: error converting "/c/Users/.../afile/out.txt" - Not a directory
```

So the conversion is not skipping the path — it is **failing** on it, with
ENOTDIR, because a middle component is not a directory. `cygpath` reports that
failure; the implicit argv conversion swallows it and passes the original
string through unchanged. Same operation, same error, one loud and one silent.

**Why it costs time.** The native binary receives `/c/Users/...`, which is not a
path in its namespace, so it answers truthfully that the thing does not exist —
and that answer is about the *string it was handed*, not about the file on disk,
which is sitting right there. Every layer is behaving correctly and the
conclusion is still wrong.

It needs three things at once — an MSYS-linked shell, a native callee, and a
middle component that happens to be a file — so it hides easily: in the case
that found this, 1132 sibling invocations converted correctly and one did not.

**Rule:** when a native binary reports a path as missing and the path is visibly
there, print the argument as the callee received it before doubting the file
system. `MSYS2_ARG_CONV_EXCL='*'` plus a `cygpath -m` path sidesteps the
conversion entirely and is the fix when a call must be reliable.

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
