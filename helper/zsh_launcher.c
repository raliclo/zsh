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

/* Build "/cygdrive/<lower-drive-letter>/rest/of/path" from an absolute
 * Windows path, matching what zsh.cmd / .zshenv already assume. */
static void to_cygdrive(const wchar_t *winpath, wchar_t *out, size_t outlen) {
    wchar_t drive = winpath[0];
    if (drive >= L'A' && drive <= L'Z') drive += (L'a' - L'A');
    swprintf(out, outlen, L"/cygdrive/%lc", drive);
    size_t base = wcslen(out);
    size_t i = 2; /* skip "C:" */
    while (winpath[i] && base + 1 < outlen) {
        wchar_t c = winpath[i] == L'\\' ? L'/' : winpath[i];
        out[base++] = c;
        i++;
    }
    out[base] = L'\0';
}

static int from_cygdrive(const wchar_t *posix, wchar_t *out, size_t outlen) {
    const wchar_t *p = NULL;
    wchar_t drive = L'\0';
    size_t base = 0;

    if (wcsncmp(posix, L"/cygdrive/", 10) == 0 && posix[10] &&
        (posix[11] == L'\0' || posix[11] == L'/')) {
        drive = posix[10];
        p = posix + 11;
    } else if (posix[0] == L'/' && posix[1] &&
               (posix[2] == L'\0' || posix[2] == L'/')) {
        drive = posix[1];
        p = posix + 2;
    } else {
        return 0;
    }

    if (!((drive >= L'a' && drive <= L'z') ||
          (drive >= L'A' && drive <= L'Z')) || outlen < 4) {
        return 0;
    }
    if (drive >= L'a' && drive <= L'z') drive -= (L'a' - L'A');
    out[base++] = drive;
    out[base++] = L':';

    if (!*p) {
        out[base++] = L'\\';
    }
    while (*p && base + 1 < outlen) {
        out[base++] = (*p == L'/') ? L'\\' : *p;
        p++;
    }
    out[base] = L'\0';
    return *p == L'\0';
}

int main(void) {
    wchar_t exePath[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exePath, MAX_PATH)) die(L"GetModuleFileNameW failed");

    wchar_t dir[MAX_PATH];
    wcscpy(dir, exePath);
    wchar_t *lastSlash = wcsrchr(dir, L'\\');
    if (!lastSlash) die(L"unexpected exe path (no backslash)");
    *lastSlash = L'\0';

    /* The real interpreter is installed as zsh.exe; this launcher is
     * packaged as zsh-loader.exe and used by the Scoop shim named zsh for
     * programmatic callers that need argv preserved exactly. */
    wchar_t zshExe[MAX_PATH];
    swprintf(zshExe, MAX_PATH, L"%ls\\zsh.exe", dir);

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

    wchar_t newPath[65536];
    swprintf(newPath, 65536, L"%ls;", dir);
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
    DWORD zdlen = GetEnvironmentVariableW(L"ZDOTDIR", origZdotdir, MAX_PATH);
    if (zdlen > 0 && zdlen < MAX_PATH && _wcsicmp(origZdotdir, dir) != 0) {
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
        to_cygdrive(termDir, terminfoPath, MAX_PATH);
    }
    SetEnvironmentVariableW(L"TERMINFO", terminfoPath);

    /* --- Console code page: switch to UTF-8, restore on exit --- */
    UINT origOutCP = GetConsoleOutputCP();
    UINT origInCP = GetConsoleCP();
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);

    /* --- Forward the launcher's argv to zsh.exe ---------------------- */
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) die(L"CommandLineToArgvW failed");

    wchar_t *newCmdLine = build_child_cmdline(zshExe, argc, argv);

    wchar_t childCwd[MAX_PATH];
    wchar_t pwd[MAX_PATH];
    wchar_t *currentDirectory = NULL;
    if (GetEnvironmentVariableW(L"PWD", pwd, MAX_PATH) > 0 &&
        from_cygdrive(pwd, childCwd, MAX_PATH)) {
        currentDirectory = childCwd;
        SetEnvironmentVariableW(L"ZSH_START_CWD", pwd);
        SetCurrentDirectoryW(childCwd);
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
    SetConsoleCP(origInCP);

    return (int)exitCode;
}
