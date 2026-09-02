# How this port keeps its PDCA cycle

Plan → Do → Check → Act, as actually practised here. The wording is ordinary;
what makes it work in this repo is that each stage has a rule that has already
been paid for by a failure, and those rules are written below with the failure
that bought them.

The cycle exists because of one recurring shape. Almost nothing here fails
loudly. The compiler is silent, the exit status is zero, the test prints PASS,
and the number has a plausible explanation. **Reading the output more carefully
does not catch that class — only changing the method before the judgement
does.** Every rule below is placed *before* a decision, not after it.

---

## Plan — establish the fact before choosing the fix

**Measure the claim first, including claims from our own documents.**

A report, a memory, or a paragraph in this repo is a starting hypothesis, not a
finding. Two examples from the same week:

- `taskkill //F //IM` was reported as "fails under zsh". Measuring all four
  contexts showed the two spellings are correct in *opposite* environments, and
  that our own wrapper caused it — a fix aimed at the reported symptom would
  have been aimed at the wrong layer.
- `bugs.md` explained the WSL argument loss as "Git Bash consumes the quotes".
  The same call from the packaged zsh lost the same byte. The document was
  wrong, and it was wrong in the direction that sends someone to change their
  shell instead of their call.

**Decide what would disprove the plan before starting it.** For a packaging
change that means naming the check up front — "does the archive still contain
`usr/bin/libzsh-*`" — because a plan with no disproof is a plan that will be
confirmed by whatever happens.

## Do — make the change where it belongs

- **`Src/` stays pristine.** Changes to upstream code live as
  `helper/patches/*.patch`, applied at build time and restored by a trap. If a
  build is interrupted the tree can be left patched; `git status Src/` says so,
  and `git checkout -- Src/` is the restore. Verify the leftover diff is
  *exactly* the patches before discarding it.
- **Use the Edit tool, never a script, to change a file.** A scripted
  substitution reports success while the file is subtly wrong: it has renamed a
  variable in a function but not in the loop that calls it, and it has rewritten
  a whole file from LF to CRLF while claiming a 14-line change.
- **Fix the cause, not the reported symptom.** `DL_EXT` flipping from `dll` to
  `so` was not a defect — `compile.sh` had documented that flip years-in and
  reads the value rather than hardcoding it. The defect was one line that did
  not follow its own document.

## Check — the stage that carries all the weight

**Nothing is "passing" until it has been checked by a method that could have
said no.**

- **Enter the gate before the judgement, not after.** The one mistake that
  repeated across days here was skipping the check with the tool in reach, and
  that cannot be fixed by adding patterns to the check.
- **A test that has never been red does not count.** Every regression test in
  `helper/test/` was run against the broken build first.
  `test_usr_bin_zsh_runs_standalone` was confirmed to produce empty output
  before the fix and `ZSHOK` after; without that step it would only have proved
  that some command exits 0.
- **Exit status is not the result.** `scoop update '*'` returned 0 with nodejs
  not upgraded. `usr/bin/zsh.exe` returned 0 while printing nothing because it
  could not load its core library. Read what the thing produced.
- **Do not judge from your own filter.** `grep -c 'FAIL:'` reported 0 failures
  on a log that contained one, because a colour escape sits between `FAIL` and
  the colon. Strip formatting before counting, and prefer the tool's own
  summary line to a pattern you invented.
- **Verify outward-facing results independently.** After a release upload, the
  asset list is read back from GitHub and the artifact re-downloaded and hashed
  against the manifest, rather than trusting the uploader's "success".
- **Absent preconditions are neither pass nor fail.** `skip_test` exists so a
  machine without WSL reports SKIP with a reason. A green line for something
  that never ran is the failure mode this suite is built to catch.

A test can also be wrong in the direction of over-fitting. When the archive
moved from `.zip` to `.tar.zst`, the Release test failed — correctly. It was
then rewritten to assert the *mechanism* (`ARCHIVE_NAME` is defined and used)
rather than the literal filename, so the next format change does not produce a
failure that says nothing about whether the Release flow is intact.

## Act — make the lesson outlive the session

Three artefacts, and the third is the one that is usually skipped:

1. **`helper/bugs/bugs.md`** — the finding, with the measurement that
   established it, not the conclusion alone. Entries are corrected when later
   evidence contradicts them; the WSL entry carries its own correction date.
2. **The code comment at the site** — why the non-obvious line is that way, so
   the next person editing it sees the reason without finding the document.
3. **A test that fails if it regresses.** This is the step that separates a
   lesson from a wish. `compile.sh` had *already documented* that `DL_EXT`
   flips, and a line 130 lines away still assumed `.dll` — knowing and writing
   it down were both insufficient. Where a mistake has crossed sessions, the
   corrective must be a check that runs, not another paragraph.

Then close the loop: the next cycle starts by re-measuring, because the fix
itself is a claim.

---

## The loop in one worked example

Reported: "is the packaged file larger or smaller after this change?"

- **Plan** — answer it by comparing the two archives file by file, not by
  reasoning about what was edited.
- **Do** — nothing yet; the question is a measurement.
- **Check** — the comparison showed the new package *smaller*, which
  contradicted the change (text was added). Following that contradiction
  instead of accepting the number found 39 modules renamed `.dll` → `.so`, and
  one file missing: `usr/bin/libzsh-*`. The real interpreter could not start,
  printed nothing, and exited 0. The full suite was green throughout, because
  every test reached zsh through the launcher, by which point the bundle root
  was on `PATH` and the library resolved.
- **Act** — fix the glob in `compile.sh`, add
  `test_usr_bin_zsh_runs_standalone` with `PATH` narrowed to `System32`,
  record the mechanism, and re-run the whole suite.

The size answer was −13.71%. It was the least valuable output of the cycle.
