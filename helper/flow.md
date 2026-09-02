# How this port is built and how it improves

Two different axes, often confused, both needed:

| | **SDLC** — the pipeline | **PDCA** — the improvement loop |
|---|---|---|
| Answers | which stages a change passes through | how we know this one is right, and how the next is better |
| Produces | updated software | updated *practice* |
| Shape | a line, with a delivery at the end | a loop, with no end |

They nest. One trip down the pipeline is one turn of the loop; and each stage
of the pipeline has small loops inside it.

Everything below exists because of one recurring shape. **Almost nothing here
fails loudly.** The compiler is silent, the exit status is zero, the test
prints PASS, and the number has a plausible explanation. Reading the output
more carefully does not catch that class — only changing the method *before*
the judgement does. So every gate below sits ahead of a decision, never after.

---

# Part 1 — SDLC: the pipeline

```
  edit  →  build  →  test  →  package  →  release  →  install  →  verify
```

Each stage has an acceptance condition that can say no. A stage is not "done"
because it printed something reassuring.

### 1. Edit

- Changes go in with the **Edit tool**, never a script. A scripted
  substitution reports success while the file is subtly wrong: it has renamed a
  variable in a function but not in the loop calling it, and it has rewritten a
  whole file LF→CRLF while claiming a 14-line change.
- **`Src/` stays pristine.** Upstream changes live as `helper/patches/*.patch`,
  applied at build time, restored by a trap.
- Accept when: `git diff --stat` and `git diff --stat --ignore-all-space` agree
  (whitespace/line-endings untouched), and `tr -dc '\r' | wc -c` is 0 for text
  files. `grep`/`sed`/`awk` cannot see CR on MSYS and will report 0 regardless.

### 2. Build — `helper/compile.sh`

- Applies the patches, configures out-of-tree into `build/`, makes, then
  assembles the portable runtime in `build/bin`.
- Accept when: **`compile.sh`'s own exit code is 0**, and `Src/` is pristine
  afterwards. Not the wrapper's exit code, and not the harness's notification —
  both have reported success over a build that returned 1.
- If a build is interrupted: check `git status Src/` (the restore trap may not
  have run) **and** check for surviving `make.exe`. An interrupted build can
  leave children alive that keep writing into `build/`, and the next configure
  then picks up their `conftest.c` and fails somewhere unrelated.

### 3. Test — `helper/test/*.zsh`

- Accept when: every file exits 0 **and** the summary reads `N passed, 0
  failed, 0 skipped`. `skipped` is not a pass: it means a precondition was
  absent and the test never ran.
- Strip ANSI before counting anything yourself. `grep -c 'FAIL:'` returned 0 on
  a log containing a failure, because a colour escape sits between `FAIL` and
  the colon.

### 4. Package — `helper/scoop_install.sh`

- Packs `build/bin` into `build/package/zsh.tar.zst` and regenerates
  `bucket/zsh.json` with the version and sha256, which must be regenerated
  together — the manifest pins the archive's hash.
- Accept when: the archive **contains** what the fix added. Verifying the build
  tree is not verifying the package; a fix has been present in `build/bin` and
  absent from the archive.

### 5. Release

- Uploads to the stable `zsh-portable` tag and deletes the superseded asset.
- Accept when: the asset list read back **from GitHub** shows what you expect,
  and a **fresh download** hashes to the manifest value. The uploader's
  "success" is not evidence.

### 6. Install

- `scoop install` from the manifest.
- Accept when: the installed files' **sha256 match the build tree's**. Compare
  files, not version strings — two different builds report the same
  `$ZSH_VERSION`.

### 7. Verify the thing users actually run

- The shim, and `usr/bin/zsh.exe` **standalone**, since the root `zsh.exe` is
  only a launcher that forwards to it.
- Accept when: each prints what it should. Exit 0 is not enough — the real
  interpreter once started, failed to find its core library, printed nothing,
  and exited 0.

**Provenance:** the version string embeds the commit the build came from. Commit
before the final package, or the artifact names a commit that does not contain
it. That has happened, and the install still worked, which is why nothing
caught it.

---

# Part 2 — PDCA: the improvement loop

### Plan — establish the fact before choosing the fix

**Measure the claim first, including claims from our own documents.** A report,
a memory, or a paragraph in this repo is a hypothesis.

- `taskkill //F //IM` was reported as "fails under zsh". Measuring all four
  contexts showed the two spellings are correct in *opposite* environments and
  that our own wrapper caused it. A fix aimed at the symptom would have hit the
  wrong layer.
- `bugs.md` blamed Git Bash for eating `$var` across the WSL boundary. The same
  call from the packaged zsh lost the same byte — the document was wrong in the
  direction that sends the reader to change their shell, which does nothing.

**Name what would disprove the plan before starting.** A plan with no disproof
gets confirmed by whatever happens.

### Do — change it where it belongs

Fix the cause, not the reported symptom. `DL_EXT` flipping `dll`→`so` was not a
defect: `compile.sh` documents that flip and reads the value. The defect was one
line 130 lines away that still assumed `.dll`.

### Check — the stage that carries the weight

- **Enter the gate before the judgement.** The mistake that repeated across days
  here was skipping the check with the tool in reach; adding patterns to the
  check cannot fix that.
- **A test that has never been red does not count.** Every regression test here
  was run against the broken build first.
- **Exit status is not the result.** `scoop update '*'` returned 0 with one app
  not upgraded.
- **Do not trust your own filter.** See the ANSI/`grep -c` case above.
- **Verify outward-facing results independently**, by reading back from the
  other side.

A test can also over-fit. When the archive moved `.zip`→`.tar.zst` the Release
test failed correctly, and was then rewritten to assert the *mechanism*
(`ARCHIVE_NAME` is defined and used) rather than a literal filename — so the
next format change does not produce a failure that says nothing.

### Act — make the lesson outlive the session

1. **`helper/bugs/bugs.md`** — the finding *with its measurement*. Entries are
   corrected when later evidence contradicts them; the WSL entry carries its
   own correction date.
2. **A comment at the site** — why the non-obvious line is that way.
3. **A test that fails if it regresses.** The step usually skipped, and the one
   that separates a lesson from a wish: `compile.sh` had *already documented*
   that `DL_EXT` flips, and a line elsewhere still assumed `.dll`. Knowing and
   writing it down were both insufficient.

---

# The two axes in one worked example

Reported: *"is the packaged file larger or smaller after this change?"*

- **Plan** — answer by comparing the two archives file by file, not by reasoning
  about what was edited.
- **Do** — nothing yet; the question is a measurement.
- **Check** — the new package came out *smaller*, contradicting the change,
  which had only added text. Following the contradiction instead of accepting
  the number found 39 modules renamed `.dll`→`.so` and one file missing:
  `usr/bin/libzsh-*`. The real interpreter could not start, printed nothing,
  exited 0. The suite was green throughout, because every test reached zsh
  through the launcher — by which point the bundle root was on `PATH` and the
  library resolved.
- **Act** — fix the glob (SDLC stage 2), add
  `test_usr_bin_zsh_runs_standalone` (stage 3), record the mechanism, re-run
  the pipeline from stage 2.

The size answer was −13.71%, and it was the least valuable output of the cycle.
