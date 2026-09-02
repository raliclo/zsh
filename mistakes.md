# mistakes.md — this tree's record

Mistakes made while working on this port, kept so the corrective outlives the
session that learned it. The authoritative counts live in
`mistakes_counter.csv2`; read and write that file **only through `csv2`**, since
three of its columns contain commas inside quotes.

Almost every entry below shares one property, and it is why they are dangerous:

> **No tool reported an error.** The exit status was zero, the log said the
> right thing, the test printed PASS, and the number had a plausible
> explanation.

Reading the output more carefully does not catch that class. Only changing the
method *before* the judgement does. Entry #6 is deliberately the exception, and
is marked as such.

---

## 1. Judging success from the wrong exit code

**Symptom.** "The build succeeded" — announced from a wrapper's status, while
`compile.sh` itself had returned 1. Twice more the same day at rc=2, and
`scoop update '*'` returned 0 with one app not upgraded.

The background-task notification reports the exit code of the *outer* command.
`printf 'DONE rc=%d' $?` appended to a log is the script's own code, and the two
disagree exactly when it matters.

**Corrective.** Read the script's own status and the last lines of its output
before saying anything about it. For anything long-running, append the real
`rc=` to the log and read *that*.

## 2. Asserting a cause, then acting on it, without a disproof

**Symptom.** Builds kept dying. The theory was "session activity during the
build kills it", and work was paced around that for several turns. Then a build
died with no activity at all — a clean control that disproved it. The real cause
was an orphaned `make` from an earlier killed run, still writing into `build/`.

The same shape had already happened once: the earlier explanation was "concurrent
Bash", then "native-child TERM", neither measured.

**Corrective.** Before acting on a cause, name the observation that would
disprove it. If none exists, it is not yet a cause. `ps -W | grep -c msys2` was
one command away the whole time.

## 3. POSIX and Windows path forms compared directly

**Symptom.** `stop_zsh_processes` matched `$SCOOP_HOME/apps/zsh`
(`/c/Users/...`) against `ps -W` output (`C:\Users\...`). It matched nothing,
killed nothing, and reported no work, while the uninstall it was supposed to
unblock went on failing. The diagnostic printed the POSIX form beside
Windows-form paths, which is how it stayed invisible.

Same family: a test asserted `${p:A}` on `/tmp/x`, which MSYS rewrites; and
`tar -cf C:/...` treated `C:` as a remote host (`Cannot connect to C:`).

**Corrective.** Normalize both sides to one form before comparing, and print
the form the *other* tool uses in any diagnostic, so the two can be read against
each other.

## 4. Suppressing the error that was the answer

**Symptom.** `rm -f build/config.status 2>/dev/null` appeared to do nothing and
the file survived. The reason was in the stderr that had just been discarded.

**Corrective.** Never `2>/dev/null` a diagnostic. Suppress output only where a
failure is genuinely expected and irrelevant, and never while investigating.

## 5. A filter that reports zero because it cannot match

**Symptom.** `grep -c 'FAIL:'` returned 0 on a log containing a failure: a
colour escape sits between `FAIL` and the colon. "0 failures" is what a clean
run looks like.

Same family, from earlier: `grep -c $'\r'` returns the *line count* in Git Bash,
because CR is stripped from argv and the pattern becomes empty.

**Corrective.** Strip formatting before counting, prefer the tool's own summary
line to a pattern you invented, and when a count is load-bearing, cross-check it
against a second signal (the summary, the exit code).

## 6. A test pinned to a literal instead of the mechanism

**This one is loud** — it fails visibly — and is recorded because the failure
carries no information, not because it is silent.

**Symptom.** A new test asserted `index($NF, d) == 1`. Fixing a real bug changed
it to `index(tolower($NF), d) == 1`, and the test went red *because the code
improved*. The Release test had failed the same way when the archive moved
`.zip` → `.tar.zst`.

**Corrective.** Assert the markers of the mechanism (`ps -W`, `to_windows_path`,
`taskkill -f -pid`), not the spelling. Then verify the assertions still fail
against the pre-fix version, or the loosening has removed the test's teeth.

## 7. Spawning a process per item on Windows

**Symptom.** A `tr` inside a path helper ran once per shimmed tool (~150×) and
hung the test suite for ten minutes. Later, a first draft of `msys2_fetch.sh`
called `awk` once per package and could not resolve gtk4 in two minutes.

Process creation on Windows is expensive enough that per-item spawning is a
hang, not a slowdown — so it reads as "stuck", not "slow".

**Corrective.** One pass that builds a table, then look-ups in shell arrays or a
`case`. If a loop must spawn, count the iterations first.

## 8. Escaping for the wrong heredoc

**Symptom.** `"\$@"` written into a **quoted** heredoc (`<<'EOF'`), which does
no expansion — the backslash would have shipped literally. A neighbouring
heredoc in the same file *is* expanding and legitimately needs `\$DL_EXT`, and
`bash -n` accepts both.

**Corrective.** Check which heredoc the line is in before escaping, by looking
at the adjacent lines: if they use bare `"$@"`, so should you.

## 9. Reporting an outcome from the log instead of the system

**Symptom.** `scoop_install.sh` printed `Installed.` and returned 0 while scoop
had refused the uninstall and left the previous build in place. The release
upload was genuinely fine, so every check of the *release* looked correct — the
error was on the side nobody inspects.

**Corrective.** Verify the end state, not the transcript: compare the installed
version against the one just packaged, and file hashes rather than version
strings — two different builds report the same `$ZSH_VERSION`.

## 10. Pushing a branch that was not the one committed to

**Symptom.** Committed on `develop-win`, then ran `git push ralic develop`.
The answer was `Everything up-to-date` — a success message for a no-op.

**Corrective.** Push the branch you are on (`git push ralic HEAD`), or read the
ref update line in the output rather than the last word.

## 11. `print` in bash

**Symptom.** `print` is a zsh builtin. In bash it falls through to `PATH` and
finds `C:\Windows\System32\print.exe` — the printer — which writes
`Unable to initialize device PRN` to stdout and exits 0. Redirected into a file,
that becomes the file's content.

**Corrective.** `printf` everywhere. It is a builtin in both shells.

## 12. A fixture that was executable but not runnable

**Symptom.** A zero-byte `cp.exe` fixture. Windows treats an empty `.exe` as
executable, so `[ -x ]` passed and running it *hung* rather than failing.

**Corrective.** Test fixtures for the property actually needed (`-s` for
non-empty), and prefer copying a real binary when the test will execute it.
