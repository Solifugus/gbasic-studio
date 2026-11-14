@echo off
rem Launch gBASIC Studio on Windows.
rem
rem   studio [mode] [home] [folder]       the window by default
rem   studio mcp <home> [folder]          Studio over MCP on stdin/stdout
rem
rem The interpreter defaults to a sibling gBASIC checkout; set GBASIC (and
rem GBASIC_STDLIB) to use another. Every decision is gBASIC's, in
rem lib\studio_launch.bas, shared with ./studio; app\launch.bas runs the plan.
setlocal
set "GBASIC_STUDIO_CWD=%CD%"
pushd "%~dp0"
if not defined GBASIC set "GBASIC=..\gbasic\gbasic.exe"
if not exist "%GBASIC%" (
    echo no gbasic interpreter at %GBASIC% 1>&2
    echo set GBASIC=C:\path\to\gbasic.exe ^(and GBASIC_STDLIB=C:\path\to\stdlib^) 1>&2
    popd
    exit /b 1
)
set "GBASIC_PATH=lib"
"%GBASIC%" app\launch.bas --run %*
set "rc=%ERRORLEVEL%"
popd
exit /b %rc%
