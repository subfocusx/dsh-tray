# toast-harness3.ps1 - does the closeTimer Tick fire at all? Intercept Close-Toast
# and log every call. Also watch the animTimer: count opacity changes.
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Log = New-Object System.Collections.Generic.List[string]

# Intercept: original would fade; here we record and hard-close (fade disabled via -Fade $false replacement)
function Close-Toast {
    param(
        [System.Windows.Forms.Form]$Form,
        [bool]$Fade = $true
    )
    $script:CloseCalls++
    $script:Log.Add("Close-Toast CALLED #$script:CloseCalls fade=$Fade at $([Math]::Round(((Get-Date) - $birth).TotalSeconds,2))s")
    try { $Form.Close() } catch { }
}
$script:CloseCalls = 0

$events = @(
    @{ At = 0.0; Title = "Toast A"; Text = "first" },
    @{ At = 2.5; Title = "Toast D"; Text = "second (after first's would-be 4s expiry)" }
)

$birth = Get-Date
$script:NextEvent = 0
$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 50
$clock.add_Tick({
    $el = [Math]::Round(((Get-Date) - $birth).TotalSeconds, 2)
    while ($script:NextEvent -lt $events.Count -and $el -ge $events[$script:NextEvent].At) {
        $e = $events[$script:NextEvent]; $script:NextEvent++
        Show-Toast -Title $e.Title -Text $e.Text
    }
    $t = $script:ToastForm
    $visible = $false; $op = -1
    if ($t -and -not $t.IsDisposed) { try { $visible = $t.Visible; $op = [Math]::Round($t.Opacity, 2) } catch { } }
    if ($visible -and ($el % 1) -lt 0.05) { $script:Log.Add("$el VISIBLE opacity=$op calls=$script:CloseToCalls") }
    if ($el -ge 10) {
        $clock.Stop()
        $script:Log.Add("$el END visible=$visible calls=$script:CloseCalls")
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)
$script:Log
"---"
"Close-Toast total calls: $script:CloseCalls"
