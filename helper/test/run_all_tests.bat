@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "TEST_DIR=%~dp0"
for %%I in ("%TEST_DIR%..\..") do set "ROOT=%%~fI"

if "%~1"=="" (
    set "BINDIR=%ROOT%\build\bin"
) else (
    set "BINDIR=%~f1"
)

set "LAUNCHER=%BINDIR%\zsh-loader.exe"
if not exist "%LAUNCHER%" (
    echo error: zsh-loader.exe not found: "%LAUNCHER%" 1>&2
    echo usage: %~nx0 [path-to-build-bin] 1>&2
    exit /b 2
)

set /a TOTAL=0
set /a PASSED=0
set /a FAILED=0

echo Running Windows packaging tests with:
echo   %LAUNCHER%
echo.

for %%T in ("%TEST_DIR%*.zsh") do (
    if not exist "%%~fT" (
        goto after_tests
    )
    set /a TOTAL+=1
    echo ==^> %%~nxT
    "%LAUNCHER%" -f "%%~fT" "%BINDIR%" "%ROOT%"
    if errorlevel 1 (
        set /a FAILED+=1
        echo FAIL: %%~nxT
    ) else (
        set /a PASSED+=1
        echo PASS: %%~nxT
    )
    echo.
)

:after_tests

if %TOTAL% equ 0 (
    echo error: no *.zsh tests found in "%TEST_DIR%" 1>&2
    exit /b 2
)

echo Results: %PASSED% passed, %FAILED% failed, %TOTAL% total
if %FAILED% neq 0 exit /b 1
exit /b 0
