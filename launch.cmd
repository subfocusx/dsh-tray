@echo off
rem ===========================================================================
rem launch.cmd - desktop shortcut target for DeepSeek Harness
rem
rem What it does (one double-click):
rem   1. Start the dsh-tray (watchdog + server if not already running)
rem   2. Wait until the web UI is listening on port 3080
rem   3. Open the DeepSeek Harness PWA in a standalone window
rem
rem Lifecycle (start/stop/restart) is owned by dsh-tray, not by this file.
rem ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0"

rem 1) Start the tray host (hidden, no console; it supervises dsh web)
wscript //nologo "dsh-tray-launch.vbs"

rem 2) Wait until :3080 is listening (dsh-tray starts + supervises the server)
for /L %%i in (1,1,40) do (
  netstat -ano | findstr /c:":3080" | findstr /c:"LISTENING" >nul 2>&1 && goto ready
  timeout /t 1 /nobreak >nul
)

:ready
rem 3) Open DeepSeek Harness in a standalone Chrome app window (PWA).
rem    Launch the user's "DeepSeek Harness" app shortcut so we open the SAME
rem    installed PWA (own profile-directory + --app-id) instead of a new tab.
set "CHROME_APP_LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Chrome Apps\DeepSeek Harness.lnk"
if exist "%CHROME_APP_LNK%" (
  start "" "%CHROME_APP_LNK%"
) else (
  start "" "http://127.0.0.1:3080/"
)
