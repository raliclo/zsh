# WSL boundary traps

Caused by `wsl.exe` itself — what it does to a command on the way across.
Index and the classification rule: [bugs.md](bugs.md).

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

**`--exec` costs you the login shell's environment, which is a separate trap.**
`wsl.exe --exec sh -c 'command -v swift'` answered "not found" for a Swift that
was installed the whole time, because `PATH` additions live in the login
shell's startup files that `--exec` skips. Use `--exec bash -lc '...'` to get
both: `--exec` keeps the arguments intact, `-l` restores the environment. The
two fixes pull in opposite directions and both are needed.

**Fallback when the far-side shell is wanted — escape what it would eat:**

```zsh
wsl.exe -- zsh -lc 'p=/usr/bin; [ -x "\$p" ] && echo YES; echo "p=[\$p]"'
# -> YES  p=[/usr/bin]
```

One level of `\$` is enough; `\\$` behaves identically. The same applies to
`*`, `?` and `[...]` — escape them, or the far-side shell resolves them against
*its* filesystem. Note what does NOT need escaping and why: `$(...)` is
untouched here because the LOCAL shell already replaced it with its value
before `wsl.exe` was called, so no metacharacter ever crosses.

Passing the script as a **file** is steadier still, since it removes the
guessing about how many layers are consuming characters — but that runs into
[MSYS argument conversion](bugs-msys.md#mnt-paths-are-rewritten-before-wslexe-sees-them),
so a call doing both needs `MSYS2_ARG_CONV_EXCL` *and* correct quoting.
