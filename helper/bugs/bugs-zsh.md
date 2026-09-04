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
