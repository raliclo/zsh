# Windows / WSL environment traps — index

Findings that cost real debugging time on this port. They share a shape: the
tooling does not fail, it returns **plausible wrong data**, so the mistake
surfaces far from its cause and the first conclusion drawn from it is wrong.

Each entry records what was measured, not what was assumed.

## Filed by cause, not by symptom

**A trap goes in the file for whatever *causes* it, never for the program it
happens to surface on.** That rule was bought: the non-conversion in
[bugs-msys.md](bugs-msys.md) was first written up citing `cmd.exe`, because
`cmd.exe echo` was the probe used to see the argument. Filing it as a cmd
problem would have been wrong in the way that matters — `attrib.exe` shows the
identical behaviour and reports it as `Invalid switch`, and a Swift binary
reports it as `does not exist`. One cause, three unrecognisable faces. Filed by
symptom, the same finding would have been written three times and connected
never.

When a new entry is ambiguous, ask which layer you would have to change to fix
it. That layer names the file.

| file | cause |
|---|---|
| [bugs-wsl.md](bugs-wsl.md) | `wsl.exe` itself — what it does to a command crossing into WSL |
| [bugs-msys.md](bugs-msys.md) | the MSYS2 runtime — argv conversion, and path resolution in `msys-2.0.dll` |
| [bugs-zsh.md](bugs-zsh.md) | zsh the language — deliberate behaviour a script can walk into |
| [bugs-build.md](bugs-build.md) | this repo's own build — things that make a correct tree look wrong |

## The entries

**[bugs-wsl.md](bugs-wsl.md)**

- `wsl.exe` runs your arguments through the WSL login shell — `$var` and globs
  are expanded a second time on the far side even when no shell was asked for.
  `--exec` is the fix; it costs you the login environment, which is its own trap.

**[bugs-msys.md](bugs-msys.md)**

- `/mnt/...` paths are rewritten before `wsl.exe` sees them.
- MSYS declines to convert a path when a middle component is a regular file —
  the conversion *fails* with ENOTDIR and the argv path swallows the error.
- `MSYS2_ARG_CONV_EXCL='*'` breaks `//F`, and the kill silently does not happen.
- Bundled tools do not resolve `/c/...` when invoked from outside.

**[bugs-zsh.md](bugs-zsh.md)**

- `local path` (and `path=`, `for path in`) silently empties `PATH`.
- Modules do not load under `zsh -f` in the portable package.

**[bugs-build.md](bugs-build.md)**

- "Sources newer than the binary" is normal here, for exactly four files.
- An interrupted build leaves patched sources and live children.

## The pattern worth carrying away

Three of these are the same operation seen from different sides: an argument
rewritten when it should not have been, not rewritten when it should have been,
and rewritten *twice*. The common defence is not a rule about any one of them —
it is to **print what the callee actually received** before concluding anything
about the file system, the toolchain, or the other machine.
