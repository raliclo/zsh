# zsh language traps

Caused by zsh itself, not by Windows. They are filed here anyway because they
bit this port and share the shape the other files share: no error, plausible
wrong state, a symptom far from its cause. Index: [bugs.md](bugs.md).

Nothing here is a zsh defect. Each is deliberate behaviour that a script can
walk into, so the fix is always at the usage level — never a patch.

---

## `local path` (and `path=`, `for path in`) silently empties `PATH`

Identical on macOS and Linux; it bit this port during the sh→zsh conversion.

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

## Modules do not load under `zsh -f` in the portable package

`zsh -f` skips the startup files, and `module_path` is set by the packaged
`.zshenv` — so under `-f` it holds only the compiled-in `/usr/local/lib/zsh/...`,
which does not exist in the package:

```
zsh -f   -> module_path = /usr/local/lib/zsh/5.9.999.3-test
normal   -> module_path = <bundle dir> /usr/local/lib/zsh/5.9.999.3-test
```

Every `zmodload` then fails — `zsh/regex`, `zsh/stat`, `zsh/watch`,
`zsh/parameter` — and each failure is reported in terms of the module, not in
terms of `-f`, so a run under `-f` produces a scatter of unrelated-looking
errors. Driving another project's test suite with `zsh -f` turned three
independent cases red for this reason alone.

**Rule:** drive anything that loads modules with the packaged zsh *without*
`-f`. Note `MODULE_PATH` in the environment does not help — `module_path` is a
shell parameter, not inherited from the environment, and it is lost across
`exec`; only `source` preserves it.

---

## Nothing in `$0`'s family tells you whether you were sourced

The natural first attempt is to compare `$0` (or `${0:A}`) against `${(%):-%x}`
and branch on the difference. It never fires. Measured — all four expansions,
both ways of arriving:

| expansion | run directly | sourced |
|---|---|---|
| `$0` | `./lib.zsh` | `./lib.zsh` |
| `${0:A}` | `/abs/.../lib.zsh` | `/abs/.../lib.zsh` |
| `${(%):-%x}` | `./lib.zsh` | `./lib.zsh` |
| `${(%):-%N}` | `./lib.zsh` | `./lib.zsh` |

Not a defect: two correct definitions simply agree here. `FUNCTION_ARGZERO`
says "when executing a shell function **or sourcing a script**, set `$0` to the
name of the function/script", and `%x` is by definition the file whose code is
running. In a sourced file that is the same file, so the comparison has nothing
to compare.

**`$ZSH_EVAL_CONTEXT` is the discriminator**, and it is a documented read-only
parameter for exactly this question:

```
run directly -> toplevel
sourced      -> toplevel:file
```

## `source` without arguments inherits the caller's positional parameters

Documented under `.`: *"if no arguments are given, the positional parameters
remain those of the calling context, and no restoring is done."*

So a caller started as `./tool.zsh --help` hands `$1=--help` to every library it
sources. Harmless while the library only defines functions; a library that
parses `$@` at top level will act on the caller's flags.

**The obvious remedy does not work.** `source lib.zsh --` does not clear them —
`--` is taken as a literal argument, so the library sees `$#=1 $1=--`. Measured,
after it was written into this entry as advice and had to be removed.

**What does work** — either gives the library `$#=0` and leaves the caller's
parameters intact afterwards:

```zsh
() { source ./lib.zsh }                 # anonymous function: its own (empty) $@

typeset -a saved; saved=("$@"); set --  # or save, clear, restore
source ./lib.zsh
set -- "${saved[@]}"
```

---

## `trap ... EXIT` does not run when the shell is killed by a signal

A cleanup registered only on `EXIT` leaks its temp files whenever the script is
terminated rather than allowed to finish. Measured, with the script signalling
**itself** so no cross-process PID question is involved:

| trap spec | on SIGTERM | on SIGINT |
|---|---|---|
| `EXIT` | does not run | does not run |
| `EXIT INT TERM` | runs — **twice** | runs — **twice** |

Not a defect, and not zsh-specific: `EXIT` means *normal termination*, and a
shell killed by an uncaught signal never reaches that path — it dies of the
signal. Every POSIX shell behaves this way. Name the signals you actually want.

**The part that is easy to miss is the second column.** With `EXIT INT TERM`,
the handler runs twice: once for the signal, once for the exit that follows.
That is fine for a handler that only removes files —

```zsh
remove_temps() { rm -f "${TMPDIR:-/tmp}"/.mytool.*(N) }
trap remove_temps EXIT INT TERM HUP
```

— because `rm -f` is idempotent (verified: handler ran twice, the file was
removed, no error). **The `(N)` is not decoration**: without it zsh's `nomatch`
makes the usual case — nothing to clean — an error, `zsh: no matches found`,
rc=1, with `rm` never reached. A handler meant to be safe to run twice then
fails on the *first* run against a clean tree. `rm -f` does not cover this,
because the failure happens during expansion. See
[example.md](../example.md) for the whole pattern and the rest of its edges.

It is *not* fine for a handler that does real work. A
cleanup that rebuilds something, restores a checkout, or re-runs a compile will
do it twice, and trapping `INT` then means **Ctrl-C starts two multi-minute
builds**.

If the handler cannot be made idempotent, disarm the EXIT trap inside the
signal handler so it runs once:

```zsh
trap 'cleanup; trap - EXIT; exit 143' INT TERM
trap cleanup EXIT
```

Measured: one run instead of two.

**The rule worth carrying:** a trap handler should be idempotent and instant.
If the thing you want on interrupt is expensive, that is a sign the expensive
part belongs in the normal flow and only the file removal belongs in the trap —
which is also how you get to keep `INT` in the list.
