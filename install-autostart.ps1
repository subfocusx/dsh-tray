# =============================================================================
# install-autostart.ps1 - install / remove the dsh-tray startup shortcut
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1        # install
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove # uninstall
# =============================================================================
param(
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$TrayRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$StartupDir = [Environment]::GetFolderPath("Startup")
$LnkPath = Join-Path $StartupDir "dsh-tray.lnk"

$ws = New-Object -ComObject WScript.Shell

if ($Remove) {
    if (Test-Path -LiteralPath $LnkPath) {
        Remove-Item -LiteralPath $LnkPath -Force
        Write-Host "Removed: $LnkPath"
    }
    else {
        Write-Host "No startup shortcut found (already removed)."
    }
    exit 0
}

$launchVbs = Join-Path $TrayRoot "dsh-tray-launch.vbs"
if (-not (Test-Path -LiteralPath $launchVbs)) {
    throw "Missing: $launchVbs"
}

$lnk = $ws.CreateShortcut($LnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
$lnk.Arguments = "//nologo `"$launchVbs`""
$lnk.WorkingDirectory = $TrayRoot
$lnk.Description = "DeepSeek Harness (dsh) web tray controller"
$lnk.Save()

Write-Host "Installed startup shortcut: $LnkPath"
Write-Host "Target: wscript.exe //nologo `"$launchVbs`""
