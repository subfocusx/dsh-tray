# toast-harness6.ps1 - v1.9.0 stacked toasts: verify the stack never overlaps,
# honours ToastMax, updates a young same-kind toast in place, and auto-dismisses
# everything (no zombie toasts). Runs the real Show-Toast/New-ToastForm/animators
# inside a message loop and samples the stack every 200 ms.
$env:DSH_TRAY_TEST_MODE = "1"
$ErrorActionPreference = "Continue"
. "$PSScriptRoot\..\..\dsh-tray.ps1"
Add-Type -AssemblyName System.Windows.Forms

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Log = New-Object System.Collections.Generic.List[string]
$script:ToastDurationMs = 2500   # shorter hold so the run finishes fast
$script:ToastMax = 4

$events = @(
    @{ At = 0.2; Title = "A";  Text = "first info" }
    @{ At = 0.4; Title = "A2"; Text = "rapid same kind (in-place)" }
    @{ At = 1.2; Title = "B";  Text = "warning" }
    @{ At = 1.3; Title = "C";  Text = "error" }
    @{ At = 1.4; Title = "D";  Text = "fourth (at cap)" }
    @{ At = 1.5; Title = "E";  Text = "fifth (oldest must be trimmed)" }
)

function Get-VisibleStack {
    $out = @()
    foreach ($r in @($script:Toasts)) {
        if (-not $r -or -not $r.Form) { continue }
        try { if ($r.Form.IsDisposed -or -not $r.Form.Visible) { continue } } catch { continue }
        $out += $r
    }
    return @($out)
}

function Test-NoOverlap {
    param($Recs)
    $list = @($Recs)
    for ($i = 0; $i -lt $list.Count; $i++) {
        for ($j = $i + 1; $j -lt $list.Count; $j++) {
            $a = $list[$i].Form.Bounds
            $b = $list[$j].Form.Bounds
            $overlap = -not ($a.Right -le $b.Left -or $a.Left -ge $b.Right -or $a.Bottom -le $b.Top -or $a.Top -ge $b.Bottom)
            if ($overlap) { return $false }
        }
    }
    return $true
}

$birth = Get-Date
$script:NextEvent = 0
$script:maxConcurrent = 0
$script:sawInPlace = $false
$script:sawTrim = $false
$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 200
$clock.add_Tick({
    $el = [Math]::Round(((Get-Date) - $birth).TotalSeconds, 2)
    while ($script:NextEvent -lt $events.Count -and $el -ge $events[$script:NextEvent].At) {
        $e = $events[$script:NextEvent]; $script:NextEvent++
        if ($e.Text -eq "warning") {
            Show-Toast -Title $e.Title -Text $e.Text -Kind ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
        elseif ($e.Text -eq "error") {
            Show-Toast -Title $e.Title -Text $e.Text -Kind ([System.Windows.Forms.ToolTipIcon]::Error)
        }
        else {
            Show-Toast -Title $e.Title -Text $e.Text -Kind ([System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
    $vis = @(Get-VisibleStack)
    if ($vis.Count -gt $script:maxConcurrent) { $script:maxConcurrent = $vis.Count }
    if (-not $script:sawTrim -and $vis.Count -gt $script:ToastMax) { $script:sawTrim = $true }
    if (-not $script:sawInPlace -and $script:Toasts.Count -ge 1) {
        $top = $script:Toasts[0]
        try { if ($top.Title -eq "A2") { $script:sawInPlace = $true } } catch { }
    }
    if ($el -ge 0.5 -and ($el % 1) -lt 0.2) {
        $ov = Test-NoOverlap -Recs $vis
        $pos = if ($vis.Count -gt 0) { ($vis | ForEach-Object { "($($_.Form.Left),$($_.Form.Top))" }) -join " " } else { "-" }
        $script:Log.Add("t=$el visible=$($vis.Count) max=$($script:maxConcurrent) overlap=$ov pos=$pos")
    }
    if ($el -ge 12) {
        $clock.Stop()
        $final = @(Get-VisibleStack)
        $script:Log.Add("t=$el FINAL visible=$($final.Count) (expect 0 after auto-dismiss) maxConcurrent=$($script:maxConcurrent) (expect 4) inPlace=$($script:sawInPlace) overlap=$(Test-NoOverlap -Recs $final)")
        $script:Context.ExitThread()
    }
})
$clock.Start()
[System.Windows.Forms.Application]::Run($script:Context)
$script:Log
"---"
"maxConcurrent=$($script:maxConcurrent) (expect <= 4) sawInPlace=$($script:sawInPlace) (expect True) noOverlap=$(Test-NoOverlap -Recs @(Get-VisibleStack))"
