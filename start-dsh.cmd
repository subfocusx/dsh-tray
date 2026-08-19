@echo off
REM ===========================================================================
REM start-dsh.cmd - default dsh web launcher for dsh-tray
REM
REM dsh-tray runs this with the configured port as %1. Override the launcher
REM via dsh-tray.json (startscript) if you need a custom launch, e.g. a fixed
REM DSH_HOME or extra flags.
REM ===========================================================================
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=3080"

if "%DSH_HOME%"=="" set "DSH_HOME=%USERPROFILE%\.dsh"
set "DSH_WEB_LOG=%~dp0logs\dsh-web.log"
if not exist "%~dp0logs" mkdir "%~dp0logs"

echo [%date% %time%] starting dsh web DSH_HOME=%DSH_HOME% port=%PORT% >> "%DSH_WEB_LOG%"
where dsh >> "%DSH_WEB_LOG%" 2>&1
dsh web --port %PORT% >> "%DSH_WEB_LOG%" 2>&1
