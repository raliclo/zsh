# Traps this repo's own build creates

Caused by `helper/compile.sh` and the packaging flow — not by Windows, not by
zsh. They are here because they make a correct tree *look* wrong, and a check
that reports a false alarm on every successful run is one people learn to skip.
Index: [bugs.md](bugs.md).

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
false positive on every successful build.

**Ask about content, not timestamps:**

```zsh
git diff --quiet HEAD -- "$f"    # true when the file matches what was built
```

The four affected files are exactly `helper/patches/`' targets: `Src/hist.c`,
`Src/subst.c`, `Src/Zle/zle.h`, `Src/Zle/zle_move.c`. Any other source turning
up newer than the binary IS a real staleness signal and should be treated as
one.

---

## An interrupted build leaves patched sources and live children

`Src/` is meant to stay pristine; the patches are applied at build time and
removed by an EXIT trap. Kill the build — a timeout, a stopped background task —
and the trap may not run, so `Src/` stays patched and the next build applies
the patches on top of themselves.

Worse, the children survive. A `make` from a killed build kept running and kept
writing into `build/`, and the *next* configure then picked up a `conftest.c`
that belonged to a later stage of the dead run and failed with
`cannot compute suffix of executables` — an error that says nothing about the
real cause. `gcc` compiled a hello-world fine throughout.

**After any interrupted build, check both:**

```zsh
git status --porcelain Src/          # empty, or restore with git checkout -- Src/
ps -W | grep -ci msys2               # 0, or kill the survivors before rebuilding
```

Also worth knowing: a full disk surfaces here as something else entirely. The
first symptom was `fatal: sha1 file '.git/index.lock' write error`, which reads
as a git problem; the cause was on the same line, further along —
`Out of diskspace`. The build that "took more than nine minutes" took 266
seconds once there was room.
