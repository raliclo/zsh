# Building zsh on Windows

zsh is a POSIX shell and cannot be built with MSVC alone; it needs the MSYS2
(Cygwin-derived) POSIX runtime and toolchain. These scripts automate that.

## Prerequisites

- [scoop](https://scoop.sh) and/or [winget](https://learn.microsoft.com/windows/package-manager/winget/)
  available on PATH. `install_build_tool.sh` will install scoop via winget if
  it's missing.
- Run scripts from Git Bash or another POSIX shell (not PowerShell/cmd).

## Usage

```sh
sh helper/install_build_tool.sh   # one-time: installs MSYS2 + MSYS GCC, native Clang, and build tools
sh helper/compile.sh              # builds zsh into ./build
sh helper/scoop_install.sh        # optional: install the result as a scoop app with a `zsh` shim
zsh helper/test/test_windows_packaging.zsh <path-to-build/bin>  # optional: regression tests
helper\test\run_all_tests.bat     # optional: run all helper/test/*.zsh tests from cmd/PowerShell
```

### install_build_tool.sh

Installs, in order:

1. **scoop** (via winget, if not already present)
2. **MSYS2** (via scoop, falling back to winget) at
   `~/scoop/apps/msys2/current` (or `C:\msys64` if installed via winget)
3. Build tools inside MSYS2 via `pacman`: `gcc`, `make`, `autoconf`,
   `automake`, `ncurses-devel`, and `mingw-w64-clang-x86_64-clang`

The zsh interpreter uses the plain `msys/*` packages because its autotools
build expects a Cygwin-like environment. Only `zsh-loader.exe` uses the
CLANG64 compiler, keeping the launcher independent of `msys-2.0.dll` so
nested zsh invocations start with fresh runtime state.

### compile.sh

Builds zsh out-of-tree so the source directory stays clean:

1. Verifies `Src/Zle/zle.h` and `Src/Zle/zle_move.c` still match the sha256
   checksums in `helper/patches/checksum.txt`, then applies
   `helper/patches/windows-zle-surrogate-pairs.patch` to the source tree.
   Refuses to build if the checksums don't match (see "The ZLE surrogate-pair
   patch" below).
2. Runs `Util/preconfig` (autoconf) in the source tree if `configure` doesn't
   exist yet.
3. Runs `configure` and `make -j$(nproc)` **inside `build/`** (VPATH build),
   not in the source tree. `configure` is run with `DLLD`/`DLLDFLAGS` preset
   and the module Makefiles are patched to reference `LINKMODS_` instead of
   `NOLINKMODS_`, working around `config.guess` misdetecting `host_os` as
   `mingw32` instead of `cygwin` on this toolchain (this detection has been
   observed to flip between `mingw32` and `cygwin` across MSYS2 updates on
   the same machine, hence `compile.sh` reads the actual `DL_EXT` the build
   produced — `.so` or `.dll` — from the generated Makefile rather than
   assuming either).
4. Assembles a **portable runtime in `build/bin`**: `zsh.exe` (the real
   interpreter), a native launcher compiled as `zsh-loader.exe`, `zsh.cmd`,
   `libzsh-*.so`/`.dll`, all dynamic modules from `config.modules`, a
   bootstrap `.zshenv`, MSYS2 runtime DLLs discovered via `ldd`, `tput.exe`,
   bundled GNU `find`/`xargs`/`tar`, and the MSYS2 terminfo database.
5. Reverts the ZLE patch applied in step 1, so the source tree is clean
   again for merging upstream zsh changes.
6. Removes autotools-generated files from the source tree
   (`configure`, `config.h.in`, `autom4te.cache`, `stamp-h.in`, `META-FAQ`).
7. Leaves `build/` in place — it is **not** cleaned up.

**CRLF guard**: if the source tree's line endings have been converted to
CRLF (e.g. by `core.autocrlf=true`), the autotools build breaks. In that
case the script detects the damaged `configure.ac` and instead builds from a
clean detached git worktree at `../zsh-build`, leaving your source tree
untouched. Fix `core.autocrlf` and restore LF endings to avoid this path.

## Running the built binary

`build/bin` has three entry points:

| File | What it is | When to use it |
|---|---|---|
| `zsh-loader.exe` | Native launcher (compiled from `helper/zsh_launcher.c`) that sets up the environment, then forwards to `zsh.exe` — reconstructing the `-c` script so both MSYS and PowerShell quoting survive (see below) | **Default choice**, especially for programmatic callers (spawning zsh as a subprocess from another program) |
| `zsh.cmd` | Batch-file launcher doing the same environment setup | Interactive use from `cmd.exe` / double-click; equivalent to `zsh-loader.exe` for normal typed commands |
| `zsh.exe` | The real interpreter, built by `configure`/`make` | Not meant to be run directly — needs `ZDOTDIR`/`ZSH_PORTABLE_DIR`/`TERMINFO` set by hand first (see `.zshenv`) |

**Use `zsh-loader.exe`, not `zsh.cmd`, if you're spawning zsh from another program**
(Swift's `Process`, Python's `subprocess`, etc.) or passing it a multi-line
`-c` script. `.cmd` files can only run through `cmd.exe`'s own command-line
parser (`CreateProcess` has no "run this script with these argv" concept for
a `.cmd` target); that parser re-tokenizes the incoming command line using
its own rules — it truncates a multi-line `-c` argument at the first
embedded newline, and can leak `|` and other metacharacters out of what
looks like a quoted string. Neither is fixable from inside `zsh.cmd`, since
the corruption happens before any of its lines run. `zsh-loader.exe` is a real PE
executable, so Windows hands it the process's actual command line
unmodified, which is what makes correct handling possible.

### How `zsh-loader.exe` recovers the `-c` script

Callers quote a `-c` script incompatibly, and the two conventions are
mutually exclusive on the wire:

- **MSYS/Cygwin (Git Bash), `cmd`, and PowerShell 7.3+** escape embedded
  quotes as `\"`. `CommandLineToArgvW` (the standard Windows argv parser)
  unescapes them correctly, so its parsed `-c` argument is right.
- **Windows PowerShell 5.1** passes embedded quotes *bare*. That makes
  `CommandLineToArgvW` lose or split them, so its parse is wrong — but
  stripping the raw command-line tail's outer quote pair recovers the
  script verbatim.

Trusting either one alone breaks the other (e.g. from Git Bash,
`zsh -c 'echo "x"; [[ "test" == t* ]] && echo ok'` would otherwise print
`"x"` with literal quote marks and the pattern match would fail). The
launcher picks between them by a reliable tell: after stripping the raw
tail's outer quotes, **a remaining bare (un-`\`-escaped) quote means the
PowerShell-5.1 form** — use the raw tail; otherwise trust the
`CommandLineToArgvW` parse. Either way the recovered script is handed to
`zsh.exe` out-of-band through the `ZSH_LOADER_SCRIPT` environment variable
and run via `eval`, so it is never re-quoted onto a command line. (Not
handled: a `-c` script *followed by* positional arguments — rare, and
already unsupported by this packaging. `helper/test/cmdline_diag.c` is a
standalone diagnostic that prints what any given caller actually produced,
for narrowing this down further.)

`build/bin` is self-contained — the required MSYS2 DLLs sit next to
`zsh.exe`, so it runs from Git Bash, cmd, or PowerShell without MSYS2 on
`PATH`:

```sh
build/bin/zsh-loader.exe --version
```

Dynamic modules (`zsh/zle`, `zsh/complete`, ...) are compiled to look in
`/usr/local/lib/zsh/<version>`, which won't exist outside MSYS2. Both
launchers set `ZDOTDIR`/`ZSH_PORTABLE_DIR` so the packaged `.zshenv` can
prepend `build/bin` to `module_path`, then restore your real `ZDOTDIR`.

Do **not** run the bare `build/Src/zsh.exe` (the raw build output, before
assembly into `build/bin`) from Git Bash — it will fail with error
0xc0000135 because Git Bash doesn't ship the MSYS2 runtime DLLs (its own
`msys-2.0.dll` is a different, incompatible build and it has no
`msys-ncursesw6.dll`).

The launcher/bootstrap also:

- switches the console to UTF-8 (code page 65001) on entry and restores the
  original code page on exit, so UTF-8 output (and typed multibyte input)
  round-trips correctly instead of showing as mojibake on a console left on
  a legacy code page;
- sets `LC_CTYPE=C.UTF-8` before starting the MSYS zsh runtime, so Windows
  Unicode filenames (for example Chinese `.xlsx` names) are decoded and
  printed as UTF-8 instead of through a legacy code page;
- sets `HOME` from Windows `%USERPROFILE%`, so `~/` resolves to your Windows
  profile instead of a missing `/home/<user>` directory;
- sets `TERMINFO` before zsh starts and packages `share/terminfo`, so `tput`
  and terminals such as `xterm-256color` work;
- prepends `build/bin` to `PATH`, then pushes `%SystemRoot%\System32`,
  `SysWOW64`, and `%SystemRoot%` itself to the very end of `PATH` — those
  ship their own `find`/`sort`/`more`/`where`/... with non-POSIX behavior
  and Scoop shims can point to BusyBox tools such as `tar`; either would
  otherwise shadow the bundled GNU tools (or anything else
  earlier on the caller's own `PATH`) no matter where they'd naturally fall;
- sets the default interactive prompt to `username@current-path`;
- binds both common Backspace sequences (`^?` and `^H`) in `main`, `emacs`,
  and `viins` keymaps. If Backspace still behaves exactly like Tab, the
  terminal is likely sending literal `^I`, which must be fixed in the
  terminal profile/keybinding.

Note: `make install` into the MSYS2 prefix currently fails at
`install.modules` (a `rlimits` module link error against static libc on
MSYS); use the portable `build/bin` layout instead.

## The ZLE surrogate-pair patch

Windows/Cygwin's `wchar_t` is 16 bits. A character outside the Basic
Multilingual Plane — most emoji — needs a UTF-16 surrogate pair to
represent, i.e. two consecutive `ZLE_CHAR_T` units in the line editor's
buffer instead of one. Unpatched, ZLE's cursor movement and character
deletion (`inccs`/`deccs`/`incpos`/`decpos` in `Src/Zle/zle_move.c`, used by
`forward-char`/`backward-char` and `backdel`/`foredel`) treat the two halves
as separate characters, landing the cursor in the middle of a pair or
deleting only half an emoji.

This is fixed by `helper/patches/windows-zle-surrogate-pairs.patch`,
applied to the source tree by `compile.sh` before building and reverted
afterward — not a permanent source change, so the tree stays mergeable with
upstream zsh. Before applying it, `compile.sh` checks
`Src/Zle/zle.h`/`Src/Zle/zle_move.c` against the sha256 checksums recorded
in `helper/patches/checksum.txt` and refuses to build if they don't match,
since the patch's context lines (and its correctness) only make sense
against the exact pristine source it was written against — a future
upstream sync to either file needs the patch (and `checksum.txt`) reviewed
and regenerated, not silently fuzzy-applied.

**Caveat — the patch is not exercisable on the current Cygwin runtime.**
It is correct for a runtime that decodes a non-BMP character into a UTF-16
surrogate pair, but this build's Cygwin `mbrtowc` does not: typing
🎉 (`f0 9f 8e 89`, U+1F389) into ZLE yields the two `wchar_t` values
U+17B3 and U+FFFF, not the surrogate pair D83C/DF89, so the surrogate
checks never match and cursor/delete still step through it wrongly. That
corruption is below ZLE, in `mbrtowc`, and no ZLE-level change reaches it.
BMP multibyte editing (CJK, accented Latin, etc.) decodes and edits
correctly and is what the regression suite locks in
(`test_multibyte_cursor_and_delete`); non-BMP/emoji line editing remains a
known runtime limitation. The patch is kept because it is correct in
principle and harmless (the checks are simply always false here), and helps
on any Windows toolchain whose `mbrtowc` does produce surrogate pairs.

## Installing as a scoop app (scoop_install.sh)

`sh helper/scoop_install.sh` packages `build/bin` and installs it through
scoop, using the manifest in `bucket/zsh.json`:

1. Zips `build/bin/*` to `build/release/zsh.zip` (with Windows' bsdtar —
   PowerShell's `Compress-Archive` cannot read the MSYS2-built binaries).
2. Regenerates `bucket/zsh.json` with the version, a `file:///` URL to the
   zip, and its sha256 hash.
3. Runs `scoop install bucket/zsh.json` (uninstalling any previous zsh
   first — **close any running zsh processes before this step**, since
   scoop can't remove files a running process still has open, and the
   reinstall silently no-ops if uninstall fails since the version string
   doesn't change between rebuilds), which:
   - extracts the zip to `~/scoop/apps/zsh/<version>\` and links
     `~/scoop/apps/zsh/current` to it — this is scoop's canonical location,
     derived from the manifest filename and `version` field;
   - creates the `~/scoop/shims/zsh` shim from the manifest's `zsh-loader.exe`
     entry (the native launcher, not `zsh.cmd` — see "Running the built
     binary" above for why), so `zsh` works from any shell with scoop's
     shims on `PATH`, with argv preserved exactly;
   - uses the wrapper and packaged `.zshenv` to set `module_path`, `HOME`,
     `TERMINFO`, prompt defaults, and Backspace bindings without relying on
     the ignored `MODULE_PATH` environment variable.

The installer clears Scoop's `zsh` download cache before reinstalling, because
the local `file:///` zip is regenerated on each package run.

To rebuild and reinstall after source changes:
`sh helper/compile.sh && sh helper/scoop_install.sh`.
To remove: `scoop uninstall zsh`.

## Regression tests (helper/test/test_windows_packaging.zsh)

Covers the packaging-specific fixes above: the multi-line `-c` /
metacharacter-in-quotes bugs, embedded double quotes in a `-c` script
surviving as real quoting (the MSYS `-c` quote-forwarding bug — see "How
`zsh-loader.exe` recovers the `-c` script"), bundled `find`/`xargs`/`tar`
taking priority over Windows'/BusyBox' own, a child inheriting the caller's
working directory at startup, UTF-8 filenames round-tripping through `ls`,
dynamic module loading, nested-session module loading and user-rc
forwarding, `PATH` ordering, `ps`'s `WINPID` column being a real Windows
PID, and multibyte (BMP) ZLE cursor movement / deletion treating a
character as one editing unit. Run it with `run_all_tests.bat`, or directly
through the build's own **launcher** (`zsh-loader.exe`, not the bare
`zsh.exe` — see the environment-loss item under "Known limitations"), since
it needs `zsh/zpty` and is testing that build specifically, and the
`build/bin` path must be passed explicitly rather than auto-detected — see
"Known limitations" for why:

```sh
helper\test\run_all_tests.bat            # runs every helper/test/*.zsh, sets exit code
# or a single suite directly:
build/bin/zsh-loader.exe -f helper/test/test_windows_packaging.zsh "$(pwd)/build/bin"
```

`helper/test/cmdline_diag.c` is a companion standalone diagnostic (not part
of the suite): build it with the same native clang toolchain and run the
argument form that misbehaves from the shell in question to see the raw
`GetCommandLineW()` string and the `CommandLineToArgvW()` token split.

## Known limitations

- **The bare `zsh.exe`, spawned from another MSYS-runtime shell (Git
  Bash, the system MSYS2 bash, ...), comes up with most of its
  environment silently missing** (`USERPROFILE` included). The parent
  shell sees a child importing a DLL *named* `msys-2.0.dll` — the same
  name as its own runtime, but a different build — and hands the
  environment over via its runtime's internal protocol instead of doing
  a full Win32 environment export; our different-build DLL can't read
  that protocol, so only the handful of variables such parents also
  mirror into the Win32 block (`PATH`, `SystemRoot`, ...) arrive. Enter
  through `zsh-loader.exe` or `zsh.cmd` instead: both are native (the
  parent does a full Win32 export to them), and both re-derive and pin
  the handshake variables before starting `zsh.exe`. This is also why
  nested sessions work: `ZDOTDIR` stays pointed at the portable dir for
  the whole session tree (with forwarding rc stubs handing off to the
  user's real startup files), so a nested `zsh.exe` inherits a live
  bootstrap rather than a consumed one, and a nested launcher keeps the
  original `ZSH_ORIG_ZDOTDIR` (an explicitly set `ZDOTDIR` still wins
  over the inherited one — see the precedence comment in
  `zsh_launcher.c`).
- **`/` resolves to the calling process's working directory, not a fixed
  filesystem root**, when `zsh.exe` (or anything that forwards to it) is
  run standalone without the rest of a normal MSYS2 install tree — this
  packaging only copies a handful of files flatly into `build/bin/`, not
  the usual `usr/bin/...` nesting a real MSYS2 install has `msys-2.0.dll`
  under. Repro: `cd C:\anywhere && build\bin\zsh.exe -f -c 'ls -ld /'`
  prints `C:/anywhere/` instead of a real root. `$PWD` is consequently wrong
  at startup (shows `/` instead of the real cwd until something explicitly
  `cd`s), and every other absolute path (`/tmp`, `/etc`, ...) resolves
  relative to whatever directory the caller happened to launch zsh from —
  most visibly, `echo x > /tmp/a` or a heredoc (which needs to create a temp
  file under `/tmp`) fails with "no such file or directory" unless cwd
  happens to contain a matching subdirectory. A full MSYS2 install's own
  `bash` does **not** have this problem when spawned the same way, so it's
  specific to running `msys-2.0.dll` outside its normal directory layout,
  not an inherent Cygwin/MSYS2-on-Windows limitation. Not yet fixed: needs
  figuring out what a from-scratch `msys-2.0.dll` actually needs on disk
  (or in the registry) to compute a real root without a full MSYS2 install
  tree present. A minimal `/etc/fstab` (either next to `msys-2.0.dll` or one
  directory up) was tried and did not fix it, and made other defaults worse
  (a bare `none / cygdrive ...` fstab entry appears to replace rather than
  supplement the DLL's built-in default mounts — `/tmp` stopped resolving
  at all).
- **`\UXXXXXXXX` string escapes above U+FFFF decode to the wrong
  character.** `ucs4tomb()` in `Src/utils.c` calls
  `wctomb(buf, (wchar_t)wval)`, truncating the full codepoint to 16 bits
  before conversion (e.g. `$'\U1F389'` — 🎉 — becomes U+F389, an unrelated
  Private Use Area character) on any platform where `wchar_t` is 16 bits.
  A working direct-to-UTF-8 path already exists (`ucs4toutf8()`, same file)
  but is compiled out here because it's gated on `!defined(__STDC_ISO_10646__)`,
  which this toolchain defines despite `wchar_t` not actually being wide
  enough. Not patched here: `ucs4tomb()` is a widely-shared utility
  function, and changing its behavior needs wider testing than this
  packaging effort covers. Workaround: use raw byte escapes
  (`$'\xf0\x9f\x8e\x89'`) instead of `\U`/`\u` for non-BMP characters.
- Windows ships no `xargs.exe` at all, and its `find.exe` is a different,
  incompatible tool from GNU findutils' — both are bundled to cover this
  (see "compile.sh" above), but any *other* GNU coreutils command a script
  assumes (e.g. `sed`, `awk`, `grep`) is similarly not guaranteed to exist
  on a machine without MSYS2/Git for Windows on `PATH` unless it's bundled
  the same way.

## Known non-fatal warnings

During `make`, you may see:

```
sh: line 1: man: command not found
sh: line 1: nroff: command not found
```

These only affect regeneration of `Doc/help.txt` (interactive `run-help`
text) and don't fail the build. Install `man`/`groff` via pacman if you need
that file regenerated.
