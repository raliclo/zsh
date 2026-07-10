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
 * reordering, ZDOTDIR/TERMINFO, console code page), then forwards the
 * original command line's argument tail to zsh.exe byte-for-byte.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>

static void die(const wchar_t *msg) {
    fwprintf(stderr, L"zsh-launcher: %ls\n", msg);
    exit(1);
}

/* Skip argv[0] in a raw Win32 command line, per the standard CRT rule:
 * if it starts with '"', argv[0] runs to the next '"'; otherwise it runs
 * to the next whitespace. Returns a pointer to the (possibly empty)
 * remainder, with leading whitespace stripped. */
static wchar_t *skip_argv0(wchar_t *cmdline) {
    wchar_t *p = cmdline;
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p == L'"') p++;
    } else {
        while (*p && *p != L' ' && *p != L'\t') p++;
    }
    while (*p == L' ' || *p == L'\t') p++;
    return p;
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
        wchar_t *tmp = wcsdup(oldPath);
        wchar_t *tok = wcstok(tmp, L";", &ctx);
        while (tok) {
            if (wcscasecmp(tok, sys32) != 0 && wcscasecmp(tok, syswow) != 0 &&
                wcscasecmp(tok, sysroot) != 0) {
                wcscat(newPath, tok);
                wcscat(newPath, L";");
            }
            tok = wcstok(NULL, L";", &ctx);
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
     * caller's real ZDOTDIR (or HOME) so .zshenv can hand control back
     * to it after setting up module_path/TERMINFO for the portable dir. */
    wchar_t origZdotdir[MAX_PATH];
    DWORD zdlen = GetEnvironmentVariableW(L"ZDOTDIR", origZdotdir, MAX_PATH);
    if (zdlen == 0 || zdlen >= MAX_PATH) {
        GetEnvironmentVariableW(L"USERPROFILE", origZdotdir, MAX_PATH);
    }
    SetEnvironmentVariableW(L"ZSH_ORIG_ZDOTDIR", origZdotdir);
    SetEnvironmentVariableW(L"ZSH_WIN_HOME", origZdotdir[0] ? origZdotdir : NULL);
    {
        wchar_t userprofile[MAX_PATH];
        if (GetEnvironmentVariableW(L"USERPROFILE", userprofile, MAX_PATH))
            SetEnvironmentVariableW(L"ZSH_WIN_HOME", userprofile);
    }
    SetEnvironmentVariableW(L"ZDOTDIR", dir);
    SetEnvironmentVariableW(L"ZSH_PORTABLE_DIR", dir);

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

    /* --- Forward the original command line's argument tail verbatim -- */
    wchar_t *fullCmdLine = GetCommandLineW();
    wchar_t *args = skip_argv0(fullCmdLine);

    wchar_t newCmdLine[32768];
    swprintf(newCmdLine, 32768, L"\"%ls\" %ls", zshExe, args);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    BOOL ok = CreateProcessW(zshExe, newCmdLine, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    DWORD exitCode = 1;
    if (!ok) {
        fwprintf(stderr, L"zsh-launcher: failed to launch %ls (error %lu)\n", zshExe, GetLastError());
    } else {
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &exitCode);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    SetConsoleOutputCP(origOutCP);
    SetConsoleCP(origInCP);

    return (int)exitCode;
}
