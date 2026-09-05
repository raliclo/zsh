# Worked example: a cleanup trap that actually cleans up

The pattern this page is about:

```zsh
remove_temps() { rm -f "${TMPDIR:-/tmp}"/.mytool.*(N) }
trap remove_temps EXIT INT TERM HUP
```

Four lines' worth of decisions, each one paid for by a measurement. The short
version of every rule below: **a trap handler must be idempotent, instant, and
unable to fail.**

---

## 1. `EXIT` alone leaks, because a killed shell never exits

`EXIT` means *normal termination*. A shell killed by an uncaught signal dies of
the signal and never reaches that path — so the handler does not run and the
temp files stay. Measured, with the script signalling itself so no
cross-process PID question is involved:

| trap spec | on SIGTERM | on SIGINT |
|---|---|---|
| `EXIT` | does not run | does not run |
| `EXIT INT TERM` | runs — **twice** | runs — **twice** |

This is not a zsh quirk; every POSIX shell behaves this way. Name the signals
you want. `HUP` is in the list for a terminal that closes.

## 2. Naming the signals makes the handler run *twice*

Once for the signal, once for the exit that follows it. That is the reason the
handler has to be idempotent, and it is the reason **the handler must not do
real work**.

A cleanup that recompiles, restores a checkout, or re-runs a build will do it
twice — and once `INT` is in the list, **Ctrl-C starts two of them**. If you
find yourself declining to trap `INT` for that reason, the problem is not the
trap: it is that a function called `cleanup` is doing something its name does
not say. Split it. Only the file removal belongs here; the expensive part
belongs in the normal flow.

If a handler genuinely cannot be made idempotent, disarm the EXIT trap from
inside the signal handler so it runs once (measured: one run instead of two):

```zsh
trap 'cleanup; trap - EXIT; exit 143' INT TERM
trap cleanup EXIT
```

## 3. `(N)` is not optional in zsh

Without it, the usual case — nothing to clean — is an **error**:

```
$ rm -f "${TMPDIR:-/tmp}"/.mytool.*
zsh: no matches found: /tmp/.mytool.*
rc=1
```

zsh's default `nomatch` aborts the command before `rm` ever runs, so the
handler that was supposed to be "safe to run twice" fails the first time on a
clean tree. `(N)` (`null_glob` for this glob only) makes an unmatched pattern
expand to nothing:

```
$ rm -f "${TMPDIR:-/tmp}"/.mytool.*(N)
rc=0
```

`rm -f` alone does **not** cover this — the failure happens during expansion,
before `rm` is reached. This is the single most likely thing to be wrong in a
cleanup handler copied from a bash script.

## 4. Know which `/tmp` you mean

`TMPDIR` is **unset** in the packaged zsh, with or without `-f`, so
`${TMPDIR:-/tmp}` resolves to `/tmp` — and `/tmp` is not one place on this
machine:

```
Git Bash          /tmp -> C:/Users/lowei/AppData/Local/Temp
packaged zsh      /tmp -> its own MSYS root's /tmp
```

A script that writes from one and a check that looks from the other will
disagree, and the disagreement reads as "the cleanup did not work". Measured
while writing this page: files created from Git Bash were still there after the
zsh handler ran, because the handler had correctly emptied a different
directory.

**If the temp files cross a shell boundary, use an absolute Windows-form path**
(`cygpath -m`), not `/tmp`.

## 5. Better still: own a directory, not a prefix

Globbing a prefix means matching files you did not create — another run of the
same tool, another user, a stale file from last week. A directory of your own
removes the guesswork and the glob:

```zsh
typeset -g workdir
workdir=$(mktemp -d) || exit 1
remove_workdir() { [[ -n $workdir ]] && rm -rf -- "$workdir" }
trap remove_workdir EXIT INT TERM HUP
```

`rm -rf` on a path that is already gone succeeds, so this is idempotent for
free, and there is no pattern to match nothing.

---

## Verifying it yourself

The claims above are all reproducible in a few seconds. The one worth running
before trusting any cleanup handler:

```zsh
# does the handler survive the case where there is nothing to clean?
zsh -f -c 'rm -f /tmp/.definitely_no_such_prefix.*   ; print rc=$?'   # rc=1, and an error
zsh -f -c 'rm -f /tmp/.definitely_no_such_prefix.*(N); print rc=$?'   # rc=0
```

and the one worth running before trusting a trap:

```zsh
cat > /tmp/t.zsh <<'EOF'
cleanup() { print ran >> /tmp/trapcount }
trap cleanup EXIT INT TERM
kill -TERM $$
sleep 5
EOF
: > /tmp/trapcount; zsh -f /tmp/t.zsh; wc -l < /tmp/trapcount    # 2, not 1
```

Related: [bugs/bugs-zsh.md](bugs/bugs-zsh.md) for the trap and glob findings in
their original context, and [flow.md](flow.md) for why measurements like these
go in a document rather than staying in someone's memory.
