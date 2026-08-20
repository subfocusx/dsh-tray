# toast-harness4.ps1 - on the FIXED dsh-tray.ps1 (v1.8.0): intercept Close-Toast to
# see if the closeTimer fires at all, and inspect the timer registry.
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Log = New-Object System.Collections.Generic.List[string]

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

$script:Log.Add("version=$script:Version  toastTimersGranted=$($script:ToastTimers.Count)")

$events = @(
    @{ At = 0.0; Title = "Toast A"; Text = "first" },
    @{ At = 2.5; Title = "Toast D"; Text = "fourth (last)" }
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
    if ($visible -and ($el % 1) -lt 0.05) {
        $ct = $null
        try { $ct = if ($t.Tag) { $t.Tag.CloseTimer } else { $null } } catch { }
        $script:Log.Add("$el VISIBLE op=$op closeTimerSet=$($null -ne $ct) registry=$($script:ToastTimers.Count)")
    }
    if ($el -ge 9) {
        $clock.Stop()
        $script:Log.Add("$el END visible=$visible calls=$script:CloseCalls registry=$($script:ToastTimers.Count)")
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)
$script:Log
"---"
"Close-Toast total calls: $script:CloseCalls"
