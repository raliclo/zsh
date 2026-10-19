/*
 * zsh_launcher.c - native argv-preserving launcher for the portable zsh
 * build. Compiled as bin/zsh-loader.exe -- the native launcher entry point --
 * which forwards to the real interpreter, installed alongside it as zsh.exe.
 * zsh.cmd (a .bat/.cmd file) does the same environment setup for interactive
 * cmd.exe/double-click use.
 *
 * Why this exists: a .bat/.cmd file can only run through cmd.exe's own
 * command-line parser (CreateProcess has no concept of "run this script
 * with these argv"; for a .cmd target it always goes through cmd.exe /c
 * first). That parser re-tokenizes the incoming command line using
 * cmd.exe's own rules -- it splits on a literal newline embedded inside
 * a quoted argument (e.g. a multi-line `-c` script gets silently
 * truncated at the first newline) and can leak '|' and other
 * metacharacters out of what looks like a quoted string to the caller.
 * Neither is fixable from inside a batch script: the corruption happens
 * before any of its lines run. A real PE executable doesn't have this
 * problem -- Windows hands it the process's actual command line
 * unmodified, and the standard argv-parsing convention (used by this
 * program, by zsh.exe itself, and by any well-behaved caller like
 * PowerShell/Swift's Process/etc.) round-trips embedded newlines and
 * shell metacharacters inside quoted arguments correctly.
 *
 * This program does the same environment setup zsh.cmd does (PATH
 * reordering, ZDOTDIR/TERMINFO, console code page), then forwards its
 * parsed argv to zsh.exe with Windows-compatible quoting.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>

static void die(const wchar_t *msg) {
    fwprintf(stderr, L"zsh-launcher: %ls\n", msg);
    exit(1);
}

static wchar_t *skip_raw_token(wchar_t *p) {
    int inquote = 0;
    while (*p) {
        if (*p == L'"') {
            inquote = !inquote;
        } else if (!inquote && (*p == L' ' || *p == L'\t')) {
            break;
        }
        p++;
    }
    while (*p == L' ' || *p == L'\t') p++;
    return p;
}

static wchar_t *skip_raw_argv0(wchar_t *cmdline) {
    wchar_t *p = cmdline;
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p == L'"') p++;
        while (*p == L' ' || *p == L'\t') p++;
        return p;
    }
    return skip_raw_token(p);
}

static int raw_token_takes_command(const wchar_t *start, const wchar_t *end) {
    if (start >= end || *start != L'-') return 0;
    if (start + 1 < end && start[1] == L'-') return 0;
    for (const wchar_t *p = start + 1; p < end; p++) {
        if (*p == L'c') return 1;
    }
    return 0;
}

static wchar_t *trim_outer_raw_quotes(const wchar_t *raw) {
    while (*raw == L' ' || *raw == L'\t') raw++;
    size_t len = wcslen(raw);
    while (len > 0 && (raw[len - 1] == L' ' || raw[len - 1] == L'\t')) len--;

    if (len >= 2 && raw[0] == L'"' && raw[len - 1] == L'"') {
        raw++;
        len -= 2;
    }

    wchar_t *copy = malloc((len + 1) * sizeof(wchar_t));
    if (!copy) die(L"out of memory");
    wmemcpy(copy, raw, len);
    copy[len] = L'\0';
    return copy;
}

/* The raw command-line text after the -c token -- the script AND every
 * operand after it -- or NULL. Points into GetCommandLineW(), not a copy. */
static const wchar_t *raw_command_tail(void) {
    wchar_t *p = skip_raw_argv0(GetCommandLineW());
    while (*p) {
        wchar_t *start = p;
        wchar_t *end = skip_raw_token(p);
        const wchar_t *token_end = end;
        while (token_end > start &&
               (token_end[-1] == L' ' || token_end[-1] == L'\t')) {
            token_end--;
        }
        if (raw_token_takes_command(start, token_end)) {
            return *end ? end : NULL;
        }
        p = end;
    }
    return NULL;
}

/* End of the first argument in raw command-line text, under the same rules
 * CommandLineToArgvW applies: 2n backslashes before a quote are n literal
 * backslashes and the quote toggles quoting, 2n+1 make the quote literal.
 * skip_raw_token() toggles on every quote, so it would end a correctly
 * escaped script like "printf \"A %s\" x" at its first inner space. */
static const wchar_t *skip_crt_token(const wchar_t *p) {
    int inquote = 0;
    while (*p) {
        if (*p == L'\\') {
            size_t bs = 0;
            while (*p == L'\\') { bs++; p++; }
            if (*p == L'"' && (bs & 1)) p++;   /* escaped, literal quote */
            continue;
        }
        if (*p == L'"') {
            inquote = !inquote;
        } else if (!inquote && (*p == L' ' || *p == L'\t')) {
            break;
        }
        p++;
    }
    return p;
}

/*
 * NOTE on the toolchain: this file must be compiled as a NATIVE Windows
 * PE binary (mingw-w64 clang, /clang64/bin/clang.exe), never with the
 * MSYS/Cygwin-runtime gcc. Two independent reasons:
 * - an MSYS-linked loader invoked from a running MSYS zsh re-enters the
 *   runtime's child-copy protocol, and nested shells can die before
 *   main() with a signal-pipe creation error;
 * - the MSYS runtime keeps most of the environment in its own POSIX
 *   environ and mirrors only a handful of variables (PATH, SystemRoot,
 *   ...) into the Win32 block, so in an MSYS-linked build the
 *   GetEnvironmentVariableW calls below silently come back empty for
 *   e.g. USERPROFILE or the caller's ZDOTDIR, breaking the handshake.
 * In a native build the Win32 environment APIs used below see the full
 * environment in every calling context: native callers (cmd, PowerShell,
 * another program) obviously, and an MSYS zsh parent too, since the MSYS
 * runtime fully exports its POSIX environ into the Win32 environment of
 * any non-MSYS child it spawns. compile.sh enforces this with an objdump
 * check that the built loader does not import msys-2.0.dll.
 */

static void append_wstr(wchar_t **buf, size_t *len, size_t *cap,
                        const wchar_t *s) {
    size_t add = wcslen(s);
    if (*len + add + 1 > *cap) {
        size_t newcap = *cap ? *cap : 256;
        while (*len + add + 1 > newcap) newcap *= 2;
        wchar_t *newbuf = realloc(*buf, newcap * sizeof(wchar_t));
        if (!newbuf) die(L"out of memory");
        *buf = newbuf;
        *cap = newcap;
    }
    wmemcpy(*buf + *len, s, add);
    *len += add;
    (*buf)[*len] = L'\0';
}

static void append_wch(wchar_t **buf, size_t *len, size_t *cap, wchar_t ch) {
    wchar_t tmp[2] = { ch, L'\0' };
    append_wstr(buf, len, cap, tmp);
}

/* Quote argv using the Windows CRT convention. Passing the launcher raw
 * command-line tail through again is tempting, but MSYS-to-native process
 * creation may use quoting that is correct for the launcher argv and wrong
 * when forwarded verbatim to the MSYS zsh child. Requoting the parsed argv
 * keeps cases like zsh -fc 'ls "#trend"' intact. */
static void append_quoted_arg(wchar_t **buf, size_t *len, size_t *cap,
                              const wchar_t *arg) {
    size_t backslashes = 0;
    append_wch(buf, len, cap, L'"');
    for (const wchar_t *p = arg; *p; p++) {
        if (*p == L'\\') {
            backslashes++;
            continue;
        }
        if (*p == L'"') {
            while (backslashes--) append_wstr(buf, len, cap, L"\\\\");
            append_wstr(buf, len, cap, L"\\\"");
            backslashes = 0;
            continue;
        }
        while (backslashes--) append_wch(buf, len, cap, L'\\');
        backslashes = 0;
        append_wch(buf, len, cap, *p);
    }
    while (backslashes--) append_wstr(buf, len, cap, L"\\\\");
    append_wch(buf, len, cap, L'"');
}

static wchar_t *build_child_cmdline(const wchar_t *zshExe, int argc,
                                    wchar_t **argv) {
    wchar_t *cmdline = NULL;
    size_t len = 0, cap = 0;

    append_quoted_arg(&cmdline, &len, &cap, zshExe);
    for (int i = 1; i < argc; i++) {
        append_wch(&cmdline, &len, &cap, L' ');
        append_quoted_arg(&cmdline, &len, &cap, argv[i]);
    }
    return cmdline;
}

static int option_takes_command(const wchar_t *arg) {
    if (arg[0] != L'-' || arg[1] == L'-') return 0;
    for (const wchar_t *p = arg + 1; *p; p++) {
        if (*p == L'c') return 1;
    }
    return 0;
}

/* True for an option that consumes the FOLLOWING argv entry as its value,
 * so the scan below does not mistake that value for the script operand.
 * zsh accepts both `-o optname` / `+o optname` and `--emulate shell`. */
static int option_takes_value(const wchar_t *arg) {
    if ((arg[0] == L'-' || arg[0] == L'+') && arg[1] == L'o' && arg[2] == L'\0')
        return 1;
    if (wcscmp(arg, L"--emulate") == 0)
        return 1;
    return 0;
}

/* True once argv[i] is an operand -- the script or command name -- rather
 * than an option. zsh stops interpreting options there, and so must we. */
static int ends_option_section(const wchar_t *arg) {
    if (arg[0] != L'-' && arg[0] != L'+') return 1;   /* plain operand */
    if (arg[1] == L'\0') return 1;                    /* bare "-" or "+" */
    if (arg[0] == L'-' && arg[1] == L'-' && arg[2] == L'\0') return 1;  /* "--" */
    return 0;
}

/* True if s contains a double quote that is NOT backslash-escaped (an even
 * number of backslashes precedes it, zero included). */
static int has_bare_quote(const wchar_t *s) {
    for (const wchar_t *p = s; *p; p++) {
        if (*p == L'"') {
            size_t bs = 0;
            const wchar_t *q = p;
            while (q > s && q[-1] == L'\\') { bs++; q--; }
            if ((bs & 1) == 0) return 1;
        }
    }
    return 0;
}

static void protect_command_arg(int argc, wchar_t **argv) {
    static wchar_t evalCommand[] =
        L"eval $ZSH_LOADER_SCRIPT; _zsh_loader_status=$?; "
        L"unset ZSH_LOADER_SCRIPT; exit $_zsh_loader_status";

    /* Only the leading OPTION section may contain the -c being protected.
     * Scanning the whole of argv corrupted script arguments: everything
     * after the script name is an operand, and a single-dash operand that
     * merely contains a 'c' (`-backup` -> b,a,c,k,u,p) looked like an
     * option cluster, so the argument after it was overwritten with
     * evalCommand below. Real zsh stops option parsing at the first
     * operand, and `--profile` was never affected only because
     * option_takes_command() rejects a leading "--". */
    for (int i = 1; i + 1 < argc; i++) {
        if (ends_option_section(argv[i])) break;
        if (option_takes_value(argv[i])) { i++; continue; }
        if (option_takes_command(argv[i])) {
            const wchar_t *script;
            /* Callers disagree on how to quote the -c script, and the two
             * conventions are mutually exclusive on the wire:
             *  - MSYS/Cygwin (Git Bash), cmd, and PowerShell 7.3+ escape
             *    embedded quotes as \" , so CommandLineToArgvW parses the
             *    script back into a single, correct argv[i+1]. After
             *    stripping the raw tail's outer quote pair the interior
             *    still shows every embedded quote as \" -- no bare quotes.
             *  - Windows PowerShell 5.1 passes embedded quotes bare, so
             *    CommandLineToArgvW loses or splits them (argv[i+1] is
             *    wrong), while stripping the raw tail's outer quote pair
             *    recovers the script verbatim -- and its interior still
             *    contains bare, unescaped quotes.
             * So: if the script's own raw argument, outer quotes stripped,
             * has a bare quote it is the PS 5.1 form, and the raw tail is
             * used; otherwise trust the CommandLineToArgvW parse. Either way
             * the script reaches the child out-of-band via ZSH_LOADER_SCRIPT,
             * never re-quoted onto a command line.
             *
             * Only the script's OWN argument may decide that, never the whole
             * tail. The tail runs to the end of the command line, operands
             * included, and checking all of it was a code-injection bug: from
             * Git Bash, zsh -c 'printf "A %s\n" "$1"' _ hello arrives as
             *   "printf \"A %s\n\" \"$1\"" _ hello
             * which does not end in a quote, so nothing was stripped, the
             * leading quote counted as bare, and script plus operands went to
             * eval as one string -- an operand holding "; cmd; " ran cmd.
             * The cost of the narrower check: under PS 5.1, a script with
             * embedded quotes AND operands after it still cannot be told
             * apart from its operands, and the raw tail (operands included)
             * is used as before. That form has no correct parse; PS 5.1
             * callers should write such a script to a file. */
            const wchar_t *tail = raw_command_tail();
            wchar_t *rawScript = NULL;
            if (tail) {
                size_t n = (size_t)(skip_crt_token(tail) - tail);
                wchar_t *first = malloc((n + 1) * sizeof(wchar_t));
                if (!first) die(L"out of memory");
                wmemcpy(first, tail, n);
                first[n] = L'\0';
                wchar_t *firstScript = trim_outer_raw_quotes(first);
                if (has_bare_quote(firstScript))
                    rawScript = trim_outer_raw_quotes(tail);
                free(firstScript);
                free(first);
            }
            script = rawScript ? rawScript : argv[i + 1];
            SetEnvironmentVariableW(L"ZSH_LOADER_SCRIPT", script);
            free(rawScript);
            argv[i + 1] = evalCommand;
            return;
        }
    }
}

/* Build "/<lower-drive-letter>/rest/of/path" from an absolute
 * Windows path, matching what zsh.cmd / .zshenv already assume. */
static void to_msys_drive(const wchar_t *winpath, wchar_t *out, size_t outlen) {
    wchar_t drive = winpath[0];
    if (drive >= L'A' && drive <= L'Z') drive += (L'a' - L'A');
    swprintf(out, outlen, L"/%lc", drive);
    size_t base = wcslen(out);
    size_t i = 2; /* skip "C:" */
    while (winpath[i] && base + 1 < outlen) {
        wchar_t c = winpath[i] == L'\\' ? L'/' : winpath[i];
        out[base++] = c;
        i++;
    }
    out[base] = L'\0';
}

/* Rewrite path in place to its final form, with junctions and symlinks
 * resolved. Scoop launches us as apps\zsh\current\zsh-loader.exe, and
 * current is a JUNCTION to the versioned directory. GetModuleFileNameW keeps
 * the junction spelling, but the MSYS runtime knows its root by the real
 * path, so with ...\current on PATH it did not recognize that entry as '/'
 * and every PATH-found external (sleep, ls, uname, ...) exited 127 with no
 * message -- seen 2026-10-19 with msys2-runtime 3.6.11. Everything below
 * derives from the directory found here, so resolving it once fixes all of
 * it. On any failure the path is left as it was. */
static void resolve_final_path(wchar_t *path, size_t cap) {
    HANDLE h = CreateFileW(path, 0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    wchar_t final[MAX_PATH];
    DWORD n = GetFinalPathNameByHandleW(h, final, MAX_PATH,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (n == 0 || n >= MAX_PATH) return;

    /* The result is in \\?\ form: \\?\C:\dir or \\?\UNC\server\share. */
    const wchar_t *p = final;
    wchar_t unc[MAX_PATH];
    if (wcsncmp(p, L"\\\\?\\UNC\\", 8) == 0) {
        swprintf(unc, MAX_PATH, L"\\\\%ls", p + 8);
        p = unc;
    } else if (wcsncmp(p, L"\\\\?\\", 4) == 0) {
        p += 4;
    }
    if (wcslen(p) < cap) wcscpy(path, p);
}

int main(void) {
    wchar_t exePath[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exePath, MAX_PATH)) die(L"GetModuleFileNameW failed");
    resolve_final_path(exePath, MAX_PATH);

    wchar_t dir[MAX_PATH];
    wcscpy(dir, exePath);
    wchar_t *lastSlash = wcsrchr(dir, L'\\');
    if (!lastSlash) die(L"unexpected exe path (no backslash)");
    *lastSlash = L'\0';

    /* The real interpreter is installed as usr\bin\zsh.exe; this launcher is
     * packaged as zsh-loader.exe and used by the Scoop shim named zsh for
     * programmatic callers that need argv preserved exactly. */
    wchar_t zshExe[MAX_PATH];
    swprintf(zshExe, MAX_PATH, L"%ls\\usr\\bin\\zsh.exe", dir);
    if (GetFileAttributesW(zshExe) == INVALID_FILE_ATTRIBUTES) {
        swprintf(zshExe, MAX_PATH, L"%ls\\zsh.exe", dir);
    }

    /* --- PATH: prepend our dir, push Windows system dirs to the end ---
     * Mirrors zsh.cmd: those dirs ship their own find/sort/more/where
     * etc. with non-POSIX behavior and must not shadow the real tools
     * bundled next to zsh.exe (or anything earlier on the caller's own
     * PATH). */
    wchar_t sysroot[MAX_PATH] = L"";
    GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH);
    wchar_t sys32[MAX_PATH], syswow[MAX_PATH];
    swprintf(sys32, MAX_PATH, L"%ls\\System32", sysroot);
    swprintf(syswow, MAX_PATH, L"%ls\\SysWOW64", sysroot);

    wchar_t oldPath[32768] = L"";
    GetEnvironmentVariableW(L"PATH", oldPath, 32768);

    /* usr\bin only, not our own directory. Inside MSYS our directory IS '/',
     * and zsh looks a name up by joining it to each PATH entry: '/' plus
     * '/head' is //head, a UNC path, so every PATH-found external waited
     * ~2.7 s on a network-name lookup before falling through, and $(...)
     * sometimes came back empty and hung. Seen 2026-10-19, once the junction
     * fix above made our directory recognizable as '/'. The tools at our
     * root are copies of usr\bin's, so nothing is lost. */
    wchar_t newPath[65536];
    swprintf(newPath, 65536, L"%ls\\usr\\bin;", dir);
    {
        wchar_t *ctx = NULL;
        wchar_t *tmp = _wcsdup(oldPath);
        wchar_t *tok = wcstok_s(tmp, L";", &ctx);
        while (tok) {
            if (_wcsicmp(tok, sys32) != 0 && _wcsicmp(tok, syswow) != 0 &&
                _wcsicmp(tok, sysroot) != 0) {
                wcscat(newPath, tok);
                wcscat(newPath, L";");
            }
            tok = wcstok_s(NULL, L";", &ctx);
        }
        free(tmp);
    }
    wcscat(newPath, sys32);
    wcscat(newPath, L";");
    wcscat(newPath, syswow);
    wcscat(newPath, L";");
    wcscat(newPath, sysroot);
    SetEnvironmentVariableW(L"PATH", newPath);

    /* --- ZDOTDIR / HOME bootstrap, same handshake as zsh.cmd: stash the
     * caller's real ZDOTDIR (or profile dir) in ZSH_ORIG_ZDOTDIR, and
     * point ZDOTDIR at the portable dir. ZDOTDIR stays pointing there
     * for the whole session tree (the portable rc stubs forward to the
     * user's real ones -- see .zshenv in compile.sh), which is what
     * makes a nested zsh.exe started from inside the session pick up
     * the same bootstrap instead of a consumed, half-restored one.
     * If ZSH_ORIG_ZDOTDIR is already set we ARE that nested case (or a
     * nested launcher inside it): keep the original caller's value
     * rather than clobbering it with the portable dir. */
    /* Precedence for what counts as the user's dot dir:
     * 1. a ZDOTDIR the caller set explicitly (and that isn't just the
     *    portable dir inherited from an enclosing session) -- an
     *    explicit override must win even inside a nested session;
     * 2. an inherited ZSH_ORIG_ZDOTDIR -- we're nested, keep the
     *    original caller's value instead of clobbering it;
     * 3. USERPROFILE. */
    wchar_t origZdotdir[MAX_PATH];
    wchar_t inheritedPortableDir[MAX_PATH];
    DWORD zdlen = GetEnvironmentVariableW(L"ZDOTDIR", origZdotdir, MAX_PATH);
    DWORD pdirLen = GetEnvironmentVariableW(L"ZSH_PORTABLE_DIR",
                                             inheritedPortableDir, MAX_PATH);
    int zdotdirIsPortable =
        zdlen > 0 && zdlen < MAX_PATH &&
        (_wcsicmp(origZdotdir, dir) == 0 ||
         (pdirLen > 0 && pdirLen < MAX_PATH &&
          _wcsicmp(origZdotdir, inheritedPortableDir) == 0));
    if (zdlen > 0 && zdlen < MAX_PATH && !zdotdirIsPortable) {
        SetEnvironmentVariableW(L"ZSH_ORIG_ZDOTDIR", origZdotdir);
    } else {
        DWORD origLen = GetEnvironmentVariableW(L"ZSH_ORIG_ZDOTDIR",
                                                origZdotdir, MAX_PATH);
        if (origLen == 0 || origLen >= MAX_PATH) {
            GetEnvironmentVariableW(L"USERPROFILE", origZdotdir, MAX_PATH);
            SetEnvironmentVariableW(L"ZSH_ORIG_ZDOTDIR", origZdotdir);
        }
    }
    {
        wchar_t userprofile[MAX_PATH];
        if (GetEnvironmentVariableW(L"USERPROFILE", userprofile, MAX_PATH))
            SetEnvironmentVariableW(L"ZSH_WIN_HOME", userprofile);
    }
    SetEnvironmentVariableW(L"ZDOTDIR", dir);
    SetEnvironmentVariableW(L"ZSH_PORTABLE_DIR", dir);
    SetEnvironmentVariableW(L"CHERE_INVOKING", L"1");

    wchar_t terminfoPath[MAX_PATH];
    {
        wchar_t termDir[MAX_PATH];
        swprintf(termDir, MAX_PATH, L"%ls\\share\\terminfo", dir);
        to_msys_drive(termDir, terminfoPath, MAX_PATH);
    }
    SetEnvironmentVariableW(L"TERMINFO", terminfoPath);

    /* Cygwin uses the process locale for multibyte (Unicode filename, ZLE
     * line-editing) conversion. The name MUST be one Cygwin actually has --
     * "C.utf8" as it appears in `locale -a`, NOT "C.UTF-8": the dashed/
     * uppercase spelling is not a real locale here and is mis-handled
     * (mbrtowc decodes inconsistently), which puts ZLE into multibyte mode
     * with unreliable decoding and desyncs the cursor from the display, so
     * even plain ASCII line editing gets scrambled. */
    SetEnvironmentVariableW(L"LC_CTYPE", L"C.utf8");
    if (GetEnvironmentVariableW(L"LANG", NULL, 0) == 0) {
        SetEnvironmentVariableW(L"LANG", L"C.utf8");
    }

    /* Cygwin's `ln -s` defaults to silently copying the target instead of
     * creating a symlink when it can't get a native NTFS reparse point --
     * no error, no warning, exit code 0. Any script or test fixture built
     * with the default MSYS policy ends up with a plain file where it
     * expects a symlink, and nothing downstream notices. `nativestrict`
     * makes `ln -s` either create a real symlink or fail loudly, so a
     * missing SeCreateSymbolicLinkPrivilege shows up as an error instead
     * of a wrong-but-successful copy. Respect an explicit override. */
    if (GetEnvironmentVariableW(L"MSYS", NULL, 0) == 0) {
        SetEnvironmentVariableW(L"MSYS", L"winsymlinks:nativestrict");
    }

    /* --- Console OUTPUT code page: switch to UTF-8, restore on exit.
     * Deliberately NOT SetConsoleCP() (the INPUT code page): Cygwin reads
     * console input as wide characters and decodes via the locale above,
     * so forcing the Win32 input code page to 65001 is unnecessary and
     * corrupts interactive input (dropped/duplicated/reordered keys). */
    UINT origOutCP = GetConsoleOutputCP();
    SetConsoleOutputCP(CP_UTF8);

    /* --- Forward the launcher's argv to zsh.exe ---------------------- */
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) die(L"CommandLineToArgvW failed");
    protect_command_arg(argc, argv);

    wchar_t *newCmdLine = build_child_cmdline(zshExe, argc, argv);

    /* Start the child in the caller's directory. We take it from this
     * loader's OWN inherited working directory (CreateProcess set it to the
     * caller's cwd), not from the caller's PWD env var: an MSYS parent
     * mangles POSIX-looking env values when spawning a native child -- e.g.
     * PWD "/c/x" arrives as "C:/Users/.../git/.../c/x" --
     * so PWD can't be trusted (and the drive-path handoff silently rejected it,
     * leaving ZSH_START_CWD unset and this whole handoff dead). The cwd is
     * handed to the child both as its process working directory and, in
     * POSIX form, via ZSH_START_CWD, which the packaged .zshenv cd's into --
     * a belt-and-suspenders guard against the standalone-MSYS runtime
     * resolving a fresh process's cwd unreliably. */
    wchar_t childCwd[MAX_PATH];
    wchar_t *currentDirectory = NULL;
    DWORD cwdLen = GetCurrentDirectoryW(MAX_PATH, childCwd);
    if (cwdLen > 0 && cwdLen < MAX_PATH) {
        wchar_t startCwdPosix[MAX_PATH + 16];
        currentDirectory = childCwd;
        to_msys_drive(childCwd, startCwdPosix, MAX_PATH + 16);
        SetEnvironmentVariableW(L"ZSH_START_CWD", startCwdPosix);
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    BOOL ok = CreateProcessW(zshExe, newCmdLine, NULL, NULL, TRUE, 0,
                             NULL, currentDirectory, &si, &pi);
    DWORD exitCode = 1;
    if (!ok) {
        fwprintf(stderr, L"zsh-launcher: failed to launch %ls (error %lu)\n", zshExe, GetLastError());
    } else {
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &exitCode);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    free(newCmdLine);
    LocalFree(argv);

    SetConsoleOutputCP(origOutCP);

    return (int)exitCode;
}
