@echo off
REM ============================================================
REM build.cmd - wrapper that bypasses the PowerShell execution policy.
REM This machine forbids running .ps1 directly, so we use -ExecutionPolicy Bypass.
REM Usage: build.cmd  |  build.cmd -Clean  |  build.cmd -Mode release
REM NOTE: keep this file ASCII-only. cmd.exe reads it in the OEM codepage,
REM       so UTF-8 CJK comments get mangled into bogus commands.
REM ============================================================
setlocal
set "SCRIPT=%~dp0build.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
