@echo off
rem Project 1944 (Call of Duty 3 native port) - fallback launcher.
rem The package root has Project1944.exe for this; use this file only if an
rem antivirus or Windows blocks that program.
rem Double-click this file. It opens the launcher window; the game itself is
rem started from there. Your own Call of Duty 3 data is required and is never
rem included in this package.
setlocal
set "LAUNCHER=%~dp0launcher\Cod3Launcher.ps1"
if not exist "%LAUNCHER%" set "LAUNCHER=%~dp0Cod3Launcher.ps1"
if not exist "%LAUNCHER%" (
  echo Cod3Launcher.ps1 not found next to this file.
  pause
  exit /b 1
)

rem A signed package runs under AllSigned, so Windows verifies every script it
rem executes instead of being told to skip the check. Without a signature there
rem is nothing to verify and Bypass is the only way a double-click works on a
rem default machine. tools\signing\Set-Cod3Signature.ps1 produces the receipt.
set "POLICY=Bypass"
if exist "%~dp0..\signing-receipt.json" set "POLICY=AllSigned"

set "PS=powershell.exe"
where pwsh.exe >nul 2>&1
if %errorlevel%==0 set "PS=pwsh.exe"

rem A plain double-click opens the launcher window. Its console is started
rem minimised so it stays out of the way; the launcher reports its own errors
rem in a message box. With arguments (-Play, -CheckRebuild, -RebuildNow) the
rem output belongs in this console, so it runs here instead.
if "%~1"=="" (
  start "Call of Duty 3 PC" /min "%PS%" -NoProfile -STA -ExecutionPolicy %POLICY% -File "%LAUNCHER%"
  exit /b 0
)
"%PS%" -NoProfile -STA -ExecutionPolicy %POLICY% -File "%LAUNCHER%" %*
if errorlevel 1 pause
