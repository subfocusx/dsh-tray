# toast-harness5.ps1 - real Close-Toast (no intercept) with DebugLog from the tray.
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms
$script:DebugLog = New-Object System.Collections.Generic.List[string]

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Summary = New-Object System.Collections.Generic.List[string]

$events = @(
    @{ At = 0.0; Title = "Toast A"; Text = "first" },
    @{ At = 2.5; Title = "Toast D"; Text = "fourth (last)" }
)

$birth = Get-Date
$script:NextEvent = 0
$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 100
$clock.add_Tick({
    $el = [Math]::Round(((Get-Date) - $birth).TotalSeconds, 2)
    while ($script:NextEvent -lt $events.Count -and $el -ge $events[$script:NextEvent].At) {
        $e = $events[$script:NextEvent]; $script:NextEvent++
        Show-Toast -Title $e.Title -Text $e.Text
    }
    $t = $script:ToastForm
    $visible = $false; $op = -1
    if ($t -and -not $t.IsDisposed) { try { $visible = $t.Visible; $op = [Math]::Round($t.Opacity, 2) } catch { } }
    if ($visible -and ($el % 1) -lt 0.05) { $script:Summary.Add("$el VISIBLE op=$op") }
    if ($el -ge 11) {
        $clock.Stop()
        $script:Summary.Add("$el END visible=$visible op=$op")
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)

"== visible summary =="
$script:Summary
"== tray DebugLog (fade ticks) =="
if ($script:DebugLog.Count -eq 0) { "(no fade-tick logs at all)" } else { $script:DebugLog }
"---"
