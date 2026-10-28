@echo off
rem compile.bat - Build zsh on Windows: upgrade MSYS2, then run compile.sh.
rem
rem Usage:
rem   helper\compile.bat [-f] [source-dir]   arguments go to compile.sh as-is
rem   helper\compile.bat --help
rem
rem   set ZSH_SKIP_MSYS2_UPGRADE=1   skip the upgrade (offline builds)
rem   set MSYS2_ROOT=C:\msys64       MSYS2 location, Windows form; default is
rem                                  scoop's msys2, then C:\msys64
rem
rem Run it from cmd or PowerShell. Started from Git Bash it still completes,
rem but the Git Bash that started it is killed if a core package is upgraded.
rem
rem Why this is a .bat and not part of compile.sh:
rem When pacman upgrades a core package (msys2-runtime, pacman, filesystem...;
rem measured for pacman+filesystem on 2026-10-29) it kills every process that has a
rem module named msys-2.0.dll loaded -- by name, whichever tree it came from.
rem Git for Windows ships a DLL with that name, so Git Bash dies along with
rem MSYS2's own shells and the packaged zsh, and a shell script driving the
rem upgrade dies with it: nothing after pass 1 runs. Measured 2026-10-19, the
rem build ended at "[exited with code 1]" with no pass 2 and no build. cmd.exe
rem loads no msys-2.0.dll, so it survives and starts pass 2 and the build as
rem fresh processes on the new runtime. See helper/bugs/bugs-msys.md.
rem
rem Side effect nothing here can prevent: the same kill closes every other
rem open zsh, Git Bash and MSYS2 window on the machine.
rem
rem Keep this file ASCII. cmd reads a .bat in the console code page (950 on a
rem Traditional Chinese system), where the tail byte of a UTF-8 character can
rem be taken as a DBCS lead byte and swallow the newline after it.
setlocal EnableExtensions

if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
if "%~1"=="/?" goto usage

for %%I in ("%~dp0..") do set "REPO=%%~fI"
rem Forward slashes: compile.sh finds the repo from dirname "$0", and dirname
rem does not split a path on backslashes.
set "REPO_FWD=%REPO:\=/%"

if not defined MSYS2_ROOT if defined SCOOP if exist "%SCOOP%\apps\msys2\current\usr\bin\bash.exe" set "MSYS2_ROOT=%SCOOP%\apps\msys2\current"
if not defined MSYS2_ROOT if exist "%USERPROFILE%\scoop\apps\msys2\current\usr\bin\bash.exe" set "MSYS2_ROOT=%USERPROFILE%\scoop\apps\msys2\current"
if not defined MSYS2_ROOT if exist "C:\msys64\usr\bin\bash.exe" set "MSYS2_ROOT=C:\msys64"
if not defined MSYS2_ROOT (
    echo error: MSYS2 not found; set MSYS2_ROOT or run helper/install_build_tool.sh 1>&2
    exit /b 1
)
set "MSYS2_BASH=%MSYS2_ROOT%\usr\bin\bash.exe"
if not exist "%MSYS2_BASH%" (
    echo error: no bash.exe under MSYS2_ROOT=%MSYS2_ROOT% 1>&2
    exit /b 1
)
rem MSYS2 bash warns "could not find /tmp" at startup when its root /tmp is
rem missing; create it before the first launch, as compile.sh does.
if not exist "%MSYS2_ROOT%\tmp" mkdir "%MSYS2_ROOT%\tmp"

if "%ZSH_SKIP_MSYS2_UPGRADE%"=="1" (
    echo ==^> Skipping MSYS2 package update ^(ZSH_SKIP_MSYS2_UPGRADE=1^)
    goto build
)

rem Pass 1 may be killed by a runtime swap; that is expected, so its status
rem is reported and not acted on. Pass 2 is a fresh process on the new runtime
rem and must succeed.
"%MSYS2_BASH%" -l "%REPO_FWD%/helper/msys2_upgrade.sh" --pass 1 "%MSYS2_ROOT%"
if errorlevel 1 echo    pass 1 ended with exit code %errorlevel% (expected if a core package was upgraded); running pass 2 in a fresh process
"%MSYS2_BASH%" -l "%REPO_FWD%/helper/msys2_upgrade.sh" --pass 2 "%MSYS2_ROOT%"
if errorlevel 1 (
    echo error: MSYS2 upgrade pass 2 failed; not building 1>&2
    exit /b 1
)

:build
set "ZSH_SKIP_MSYS2_UPGRADE=1"
rem An MSYS2 login shell starts with a minimal PATH that has no git, and
rem compile.sh runs git while patching (first run here: "git: command not
rem found"). inherit appends the Windows PATH after MSYS2's own directories,
rem so git is found and MSYS2's tools still come first.
set "MSYS2_PATH_TYPE=inherit"
"%MSYS2_ROOT%\usr\bin\sh.exe" -l "%REPO_FWD%/helper/compile.sh" %*
exit /b %errorlevel%

:usage
rem Print the header block above: every line from the second up to the first
rem one that is not a comment. goto leaves the for loop at that line.
setlocal EnableDelayedExpansion
for /f "usebackq skip=1 tokens=* delims=" %%L in ("%~f0") do (
    set "line=%%L"
    if not "!line:~0,3!"=="rem" goto usage_end
    echo(!line:~4!
)
:usage_end
exit /b 0
