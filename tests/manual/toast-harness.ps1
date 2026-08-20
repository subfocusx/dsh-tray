# toast-harness.ps1 - drives the real Show-Toast through a WinForms message loop
# and records whether toasts auto-dismiss. Run:  powershell -STA -File toast-harness.ps1
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext

$events = @(
    @{ At = 0.0; Title = "Toast A"; Text = "first toast" },
    @{ At = 0.8; Title = "Toast B"; Text = "second (debounce window passed => old fades)" },
    @{ At = 1.6; Title = "Toast C"; Text = "third within 500ms of B => in-place update" },
    @{ At = 2.5; Title = "Toast D"; Text = "fourth" }
)

$birth = Get-Date
$script:NextEvent = 0
$script:Log = New-Object System.Collections.Generic.List[string]
$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 50
$clock.add_Tick({
    $el = [Math]::Round(((Get-Date) - $birth).TotalSeconds, 2)
    while ($script:NextEvent -lt $events.Count -and $el -ge $events[$script:NextEvent].At) {
        $e = $events[$script:NextEvent]; $script:NextEvent++
        Show-Toast -Title $e.Title -Text $e.Text
        $script:Log.Add("$el fired ($($e.Title))")
    }
    $t = $script:ToastForm
    $visible = $false; $op = -1
    if ($t -and -not $t.IsDisposed) {
        try { $visible = $t.Visible; $op = [Math]::Round($t.Opacity, 2) } catch { }
    }
    if ($visible) { $script:Log.Add("$el TOAST-VISIBLE opacity=$op") }
    if ($el -ge 8) {
        $clock.Stop()
        if ($t -and -not $t.IsDisposed -and $t.Visible) {
            $script:Log.Add("$el STILL-VISIBLE-AT-END (BUG REPRODUCED)")
        } else {
            $script:Log.Add("$el all toasts auto-closed (OK)")
        }
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)

# keep only the last 4 lines per second so the dump is readable
$dedup = $script:Log | Select-Object -Unique
$dedup[0..([Math]::Min(160, $dedup.Count - 1))]
"---"
"NotifyIcon disposed by Closed handler properly: $($null -eq $script:ToastForm)"
