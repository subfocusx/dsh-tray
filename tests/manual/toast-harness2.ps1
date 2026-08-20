# toast-harness2.ps1 - test the GC hypothesis: pin the toast CloseTimer in script
# scope as soon as it appears. If toasts then auto-dismiss while the unpinned run
# hangs, the close/fade timers are being collected / their Tick is never delivered.
param([int]$Pin = 0)
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:PinnedTimers = New-Object System.Collections.ArrayList
$script:Log = New-Object System.Collections.Generic.List[string]

$events = @(
    @{ At = 0.0; Title = "Toast A"; Text = "first" },
    @{ At = 0.8; Title = "Toast B"; Text = "second" },
    @{ At = 1.6; Title = "Toast C"; Text = "third" },
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
        $script:Log.Add("$el fired ($($e.Title))")
    }
    $t = $script:ToastForm
    if ($t -and -not $t.IsDisposed) {
        $ctx = $t.Tag
        if ($Pin -eq 1 -and $ctx -and $ctx.CloseTimer) {
            $ct = $ctx.CloseTimer
            if (-not $script:PinnedTimers.Contains($ct)) { [void]$script:PinnedTimers.Add($ct) }
        }
    }
    $visible = $false; $op = -1
    if ($t -and -not $t.IsDisposed) {
        try { $visible = $t.Visible; $op = [Math]::Round($t.Opacity, 2) } catch { }
    }
    if ($visible -and ($el % 2) -ge 1.94) { $script:Log.Add("$el VISIBLE opacity=$op pinned=$($script:PinnedTimers.Count)") }
    if ($el -ge 9) {
        $clock.Stop()
        if ($t -and -not $t.IsDisposed -and $t.Visible) {
            $script:Log.Add("$el STILL-VISIBLE-AT-END pin=$($script:PinnedTimers.Count) => HANG")
        } else {
            $script:Log.Add("$el all toasts auto-closed (OK) pin=$($script:PinnedTimers.Count)")
        }
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)
$script:Log
"---"
"result: pin=$Pin pinnedTimers=$($script:PinnedTimers.Count) toastForms=$($null -ne $script:ToastForm)"
