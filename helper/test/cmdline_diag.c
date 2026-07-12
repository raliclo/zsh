/*
 * cmdline_diag.c - diagnostic for how a caller's shell quotes a command
 * line by the time a native Windows program receives it.
 *
 * The portable-zsh launcher (helper/zsh_launcher.c) has to recover the
 * original -c script from a command line that different callers quote
 * incompatibly:
 *   - MSYS/Cygwin (Git Bash), cmd, and PowerShell 7.3+ escape embedded
 *     quotes as \" (CommandLineToArgvW parses them back correctly);
 *   - Windows PowerShell 5.1 passes embedded quotes bare (CommandLineToArgvW
 *     then loses or splits them).
 * When that recovery misbehaves for some caller, build and run this to see
 * exactly what that caller produced -- the raw GetCommandLineW() string and
 * the CommandLineToArgvW() token split -- and decide which branch of
 * protect_command_arg() should handle it.
 *
 * Build (native PE, same toolchain as the launcher):
 *   /clang64/bin/clang.exe -O2 -o cmdline_diag.exe cmdline_diag.c -lshell32
 *
 * Run the SAME argument form that misbehaves, from the shell in question:
 *   ./cmdline_diag.exe -c 'echo "x"; [[ "test" == t* ]] && echo ok'
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>

int main(void) {
    wchar_t *raw = GetCommandLineW();
    fwprintf(stderr, L"RAW: [%ls]\n", raw);

    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(raw, &argc);
    if (!argv) {
        fwprintf(stderr, L"CommandLineToArgvW failed\n");
        return 1;
    }
    fwprintf(stderr, L"ARGC: %d\n", argc);
    for (int i = 0; i < argc; i++) {
        fwprintf(stderr, L"  argv[%d]: [%ls]\n", i, argv[i]);
    }
    LocalFree(argv);
    return 0;
}
