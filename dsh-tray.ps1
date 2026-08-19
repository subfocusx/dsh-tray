# =============================================================================
# dsh-tray.ps1 - DeepSeek Harness (dsh web) Windows-native tray controller
#
# Version: 1.7.1
#
# 1.7.1 (stability): crash-loop backoff actually escalates + restart cap
#   - RestartCount (which drives the 5s -> 30s restart backoff) is no longer
#     zeroed inside Start-DshProxy right after every Start-Process. It is only
#     reset once the service has *stably/probe-confirmed* become Healthy (in
#     Invoke-HealthDecision), so a permanently crashing dsh is no longer
#     restarted every ~5s forever.
#   - New config maxconsecutiverestarts (default 10): once the consecutive
#     crash-restart counter reaches the cap the tray stops auto-restarting,
#     shows a "needs intervention" status + one final error toast and logs the
#     current HealthFailures/RestartCount. The manual "Restart dsh" menu item
#     resets the counter and re-enables auto-restart.
#   - "New Conversation" and "Stop agent" menu actions now run their slow
#     UI-Automation / RPC work on the same background runspace infrastructure
#     (Start-AsyncJob / Invoke-AsyncJobSweep) instead of blocking the UI thread
#     on the click handler (up to ~8s of sleeps / 10s RPC timeouts).
#   - Read-Config validates numeric fields (port, intervals, delays, counts,
#     uifontsize...): a non-numeric / non-positive / out-of-range value is
#     logged as a WARN (field, original value, applied default) instead of
#     being silently accepted as garbage.
#
# 1.7.0: async + debounced watchdog, no UI-thread network, calm notifications
#   - Health checks, agent polls and update checks run on background runspaces;
#     the UI thread never blocks on the network. The tray icon and menu appear
#     immediately; the first health probe completes asynchronously and the
#     watchdog makes its start/no-start decision from the completed result.
#   - Health state is debounced (healthconfirmations / healthdebounceseconds):
#     a single flapping probe no longer toasts "unhealthy"/"recovered". Toasts
#     fire only on *stable* transitions (became Healthy after start/recovery,
#     regressed after being Healthy, first crash of an episode).
#   - Toasts now fade out on close and reuse the visible toast (update text +
#     colour) when a new event arrives within ~500ms, killing the startup
#     "blinking" flicker.
#   - Start-DshApp logs + falls back to a browser tab when the Chrome App
#     shortcut (chromeapplnk) is missing, broken, or its target is gone.
#
# 1.6.1 (bugfix): update checker no longer reports a false "update available"
#   when the installed build matches the npm "latest" prerelease dist-tag.
#   Get-LatestDshVersion previously stripped the "-rc.x" suffix (0.1.0-rc.7 ->
#   0.1.0), so a stable release that was never published looked newer than the
#   installed prerelease. The full version string (core + prerelease) is now
#   preserved through parsing.
#
# The tray is the switch + watchdog for the Windows-native dsh web instance
# (default port 3080). It starts / restarts / stops dsh, watches health, and
# auto-recovers crashes. All knobs live in dsh-tray.json next to this script.
# Menu text follows the system UI language (zh / ru / en); override in config.
#
# Process model:
#   dsh-tray.lnk (Startup) -> wscript dsh-tray-launch.vbs
#     -> powershell -WindowStyle Hidden -> this script
#       -> Start-Process cmd.exe /c dsh-win-start.cmd
#            -> dsh web --port <port>   (DSH_HOME=%USERPROFILE%\.dsh; default 3080)
#
# Watchdog policy (since 1.1.0):
#   - the tray manages the *lifecycle*, not liveness:
#     a live-but-slow process is never killed; only a crash (process gone)
#     schedules a restart, with 5s -> 30s backoff.
#   - Stop only taskkills a process positively identified as dsh web
#     (node/bun runtime + command line referencing dsh).
#
# There is intentionally NO Exit menu item: the tray runs forever and the
# watchdog owns dsh's lifecycle. To fully stop: menu Stop dsh, then kill the
# tray process (taskkill /PID <tray-pid> /F).
# =============================================================================

$script:Version = "1.7.1"

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Per-monitor/global DPI awareness: without this WinForms gets DPI-virtualised
# (>100% scale), which makes small text/menu look fuzzy and "jagged". Best-effort.
try {
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class DshDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' -ErrorAction SilentlyContinue
    [DshDpi]::SetProcessDPIAware() | Out-Null
} catch { }

# --- script state -----------------------------------------------------------
$script:TrayRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LogDir     = Join-Path $script:TrayRoot "logs"
$script:TrayLog    = Join-Path $script:LogDir "dsh-tray.log"
$script:LogRotationBytes = 1MB    # tray log auto-rotation threshold
$script:TrayStartedAt = Get-Date  # tray process uptime baseline
$script:ManagedByTray    = $false    # did THIS tray start the healthy service?
$script:StartedAt        = $null
$script:LastHealthCheck  = [DateTime]::MinValue
$script:RestartAfter     = [DateTime]::MinValue
$script:HealthFailures   = 0
$script:RestartCount     = 0    # consecutive crash-restarts (drives restart backoff)
$script:RestartCapHit    = $false   # maxconsecutiverestarts exceeded -> auto-restart stopped
$script:AutoRestartEnabled = $true
$script:Exiting          = $false
$script:Context          = $null
$script:Timer            = $null
$script:NotifyIcon       = $null
$script:StatusItem       = $null
$script:WhaleIcon        = $null    # DeepSeek whale icon (assets\dsh-whale.png)
$script:LastState        = $null    # last status state, for icon composition
$script:LastStatusState  = $null    # last status state, for transition balloons
$script:SawUnhealthy     = $false   # have we ever observed an unhealthy state?
$script:SuppressAutostartEvents = $false   # guard: setting Checked at build time must not toggle the lnk
$script:MouseTypeDefined = $false   # Add-Type guard for the P/Invoke mouse helper
$script:Config           = $null
$script:Port             = 3080
$script:HealthUrl        = $null
$script:DashboardUrl     = $null
$script:StartScript      = $null
$script:DshLogFile       = $null
$script:HealthIntervalSeconds = 10
$script:StartupGraceSeconds   = 120
$script:RestartDelaySeconds   = 5
$script:Lang             = "en"
$script:L                = @{}    # localized UI strings

# --- v1.4.0: agent monitor / notifications / icon badge state ---
$script:BaseWhaleIcon    = $null    # pristine whale HICON, base for the composited badge
$script:BadgeIconCache   = @{}      # count -> composited Icon cache
$script:AgentMenu        = $null    # Agents submenu (ToolStripMenuItem)
$script:AgentMenuHost    = $null    # host item for the submenu (always present, disabled when none)
$script:AgentTimer       = $null    # dedicated poll timer for the agent monitor
$script:AgentLastPoll    = [DateTime]::MinValue
$script:AgentPrevRunning = @{}      # sessionId -> agent info of previously running agents
$script:AgentKnown       = @{}      # sessionId -> last seen status (running/inactive) for diffing
$script:AgentCount       = 0
$script:AgentWaitingCount = 0
$script:AgentMonitorLogged = $false # have we logged a successful agent poll once
$script:AgentBaseline      = $false # first successful poll establishes baseline (no notifications)
$script:AgentPollFailureCount = 0

# --- v1.7.0: async + debounced health/state machine ---
# All network operations (health probe, agent session.list, npm update check)
# run on background runspaces. The UI thread consumes the *completed* results in
# the 1s timer tick; it never calls GetResponse/Invoke-RestMethod directly from
# the message loop, so clicks and the tray icon stay responsive while dsh boots.
$script:AsyncJobs            = @{}      # id -> @{ PS; Handle; Rs; Started } of in-flight runspace jobs
$script:HealthProbeInFlight  = $false
$script:HealthResult         = $null    # @{ Healthy = [bool]; At = [datetime] } latest completed probe
$script:HealthApplyPending   = $false   # a completed probe is queued to drive the next watchdog decision
$script:FirstProbeAt         = $null    # timestamp of the first completed probe (boot timing)
$script:FirstProbeHealthy    = $null
$script:UiShownAt            = $null    # timestamp when NotifyIcon.Visible = $true (boot timing)

# Debounced health state: "Healthy"/"Unhealthy" only flips after N consecutive
# probes (healthconfirmations) or after healthdebounceseconds in the same
# direction. This is what gates *notification* transitions - the tray icon/text
# may follow the raw probe, but toasts only fire on stable flips.
$script:StableHealth             = $null
$script:StableHealthSince        = [DateTime]::MinValue
$script:HealthFlipCandidate      = $null
$script:HealthFlipCandidateSince = [DateTime]::MinValue
$script:HealthFlipStreak         = 0
$script:StableHealthFlippedTo    = $null    # set by Update-StableHealth on a real flip
$script:HealthyEver              = $false   # has dsh ever been (stably) healthy this session
$script:CrashNotified            = $false   # crash toast sent for the current down-episode
$script:LastErrorBalloonAt       = [DateTime]::MinValue   # rate-limit watchdog error toasts

# Toast debounce: rapid successive events update the visible toast instead of
# recreating it (the startup "blinking" flicker).
$script:ToastShownAt     = [DateTime]::MinValue
$script:ToastDebounceMs  = 500

# Chrome App (PWA) shortcut diagnostics - warn once, fall back to a browser tab.
$script:ChromeAppLnkWarned = $false

# v1.7.1: "New Conversation" menu item, toggled disabled/"..." while the async
# new-conversation job (GUI automation + RPC fallback) is in flight.
$script:NewChatMenuItem = $null

# Agent poll async state.
$script:AgentPollInFlight    = $false
$script:AgentPollForceRefresh = $false

# Update check / apply async state.
$script:UpdateManual  = $false      # the in-flight check was user-initiated (-> "up to date" toast)
$script:UpdateProcess = $null       # @{ Process; LogPath; Started } in-flight `npm install -g`
$script:UpdateCheckScript = $null   # cached composed runspace script for the version query
$script:RpcWarnCooldown = @{}       # method -> last WARN timestamp (rate-limit RPC failure logs)

New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

# --- helpers ----------------------------------------------------------------
function Write-TrayLog {
    param(
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$Level = "INFO"
    )
    # Back-compat: legacy call sites embed the level in the message ("WARN foo",
    # "ERROR foo", "FATAL <exception>"); normalize them to the -Level form so
    # every line has a uniform, filterable "[LEVEL]" field.
    if ($Message -match '^(FATAL|ERROR|WARN)\s+(.*)$') {
        $Level = $Matches[1]
        $Message = $Matches[2]
    }
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    try {
        # Cheap rotation guard: keep the tray log bounded. When it grows past
        # $script:LogRotationBytes the current file is archived as dsh-tray.log.1
        # and a fresh one is started, so a runaway (e.g. repeated stack traces)
        # can never grow forever. File stats at tray write rates are negligible.
        $max = $script:LogRotationBytes
        $fi = Get-Item -LiteralPath $script:TrayLog -ErrorAction SilentlyContinue
        if ($null -ne $fi -and $fi.Length -gt $max) {
            $archive = "$script:TrayLog.1"
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $script:TrayLog -NewName "dsh-tray.log.1" -Force -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $script:TrayLog -Value ("{0} [INFO] log rotated: previous file archived as dsh-tray.log.1" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
        }
        Add-Content -LiteralPath $script:TrayLog -Value $line -Encoding UTF8
    }
    catch {
        # A failed log write must never take the tray down (that would hide the
        # very problem we are logging). Swallow silently.
    }
}

# --- modern UI / icons / toast (v1.5.0) ----------------------------------------
# Windows 11 styling is done self-contained: no external icon assets or modules.
#   * menu item icons  -> Segoe MDL2 Assets glyphs drawn onto 16x16 bitmaps
#   * rounded corners  -> DwmSetWindowAttribute on the menu / toast HWNDs
#   * notifications    -> custom Win11-style toast window (rounded + accent bar)
# The DeepSeek whale stays as the brand; only the *standard Windows* icons
# (SystemIcons.Error/Warning/Application/Information) are replaced.

$script:UiHelpersDefined = $false   # Add-Type guard for the PInvoke + color/renderer types

function Initialize-UiHelpers {
    if ($script:UiHelpersDefined) { return }
    $script:UiHelpersDefined = $true

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $src = @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class DshDwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    // DWMWA_WINDOW_CORNER_PREFERENCE=33  (1=default, 2=round)
    // DWMWA_SYSTEMBACKDROP_TYPE = 38   (2=acrylic, 3=mica, 4=mica-no-accent)
    public static void ApplyRoundCorners(IntPtr hwnd) {
        int round = 2;
        try { DwmSetWindowAttribute(hwnd, 33, ref round, 4); } catch {}
    }
    public static void TryMica(IntPtr hwnd) {
        int mica = 3;
        try { DwmSetWindowAttribute(hwnd, 38, ref mica, 4); } catch {}
    }
}

// Fluent-ish color table so the ContextMenuStrip follows light/dark cleanly.
public sealed class DshFluentColorTable : ProfessionalColorTable {
    public bool Dark;
    private Color MenuBg()    { return Dark ? Color.FromArgb(32, 32, 32) : Color.White; }
    private Color Hover()     { return Dark ? Color.FromArgb(62, 62, 62) : Color.FromArgb(229, 243, 255); }
    private Color Border()    { return Dark ? Color.FromArgb(45, 45, 45) : Color.FromArgb(0, 0, 0, 0); }
    private Color Sep()       { return Dark ? Color.FromArgb(58, 58, 58) : Color.FromArgb(0, 0, 0, 0); }

    public override Color ToolStripDropDownBackground { get { return Dark ? Color.FromArgb(38,38,38) : Color.White; } }
    public override Color ImageMarginGradientBegin   { get { return MenuBg(); } }
    public override Color ImageMarginGradientMiddle  { get { return MenuBg(); } }
    public override Color ImageMarginGradientEnd     { get { return MenuBg(); } }
    public override Color MenuBorder                 { get { return Border(); } }
    public override Color MenuItemBorder             { get { return Border(); } }
    public override Color MenuItemSelected           { get { return Hover(); } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover(); } }
    public override Color MenuItemSelectedGradientEnd   { get { return Hover(); } }
    public override Color MenuItemPressedGradientBegin  { get { return Hover(); } }
    public override Color MenuItemPressedGradientMiddle { get { return Hover(); } }
    public override Color MenuItemPressedGradientEnd    { get { return Hover(); } }
    public override Color SeparatorDark   { get { return Sep(); } }
    public override Color SeparatorLight  { get { return Sep(); } }
    public override Color CheckBackground { get { return Hover(); } }
    public override Color CheckSelectedBackground { get { return Hover(); } }
    public override Color CheckPressedBackground  { get { return Hover(); } }
    public override Color ButtonSelectedHighlight { get { return Hover(); } }
    public override Color ButtonSelectedHighlightBorder { get { return Border(); } }
}
'@
    # C# here derives from System.Windows.Forms/Drawing types, which need explicit
    # references even though those assemblies are already loaded via Add-Type.
    $refs = @(
        ([System.Windows.Forms.Form].Assembly).Location,
        ([System.Drawing.Bitmap].Assembly).Location
    )
    Add-Type -TypeDefinition $src -ReferencedAssemblies $refs
}

function Get-SystemDarkMode {
    # true when the user's apps follow the dark theme (Win10/11).
    try {
        $val = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction Stop
        if ($null -ne $val) { return ([int]$val -eq 0) }
    } catch { }
    return $false
}

function Resolve-MenuTheme {
    # 'auto' follows the system; explicit light/dark overrides.
    $t = if ($script:Config -and $script:Config.menutheme) { [string]$script:Config.menutheme } else { "auto" }
    if ($t -eq "light") { return $false }
    if ($t -eq "dark")  { return $true }
    return (Get-SystemDarkMode)
}

function Get-AccentColor {
    # Windows accent (system) colour from the registry; fall back to DeepSeek blue.
    try {
        $deflt = (Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "AccentColor" -ErrorAction Stop)
        if ($null -ne $deflt) {
            $a = [int]$deflt
            # AccentColor is 0xAABBGGRR
            $r = $a -band 0xFF; $g = ($a -shr 8) -band 0xFF; $b = ($a -shr 16) -band 0xFF
            return [System.Drawing.Color]::FromArgb($r, $g, $b)
        }
    } catch { }
    return [System.Drawing.Color]::FromArgb(38, 163, 255)  # DeepSeek blue fallback
}

function New-GlyphImage {
    # Draw a Segoe MDL2 Assets glyph onto a 16x16 transparent bitmap. Kept
    # dependency-free: no external PNG/ICO needed for menu icons.
    param(
        [int]$Code = 0xE80F,
        [System.Drawing.Color]$Fore = ([System.Drawing.Color]::FromArgb(28, 28, 28)),
        [int]$Size = 16,
        [string]$FontName = "Segoe MDL2 Assets"
    )
    try {
        $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        # AntiAlias (not AntiAliasGridFit): grid-fit hinting snaps glyphs to the
        # pixel grid, producing stepped/"jagged" edges at small sizes. Smooth
        # grayscale anti-aliasing looks cleaner on the menu icons.
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $font = New-Object System.Drawing.Font($FontName, [single]($Size * 0.62), [System.Drawing.FontStyle]::Regular)
        $brush = New-Object System.Drawing.SolidBrush($Fore)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
        $g.DrawString([char]$Code, $font, $brush, $rect, $sf)
        $sf.Dispose(); $brush.Dispose(); $font.Dispose(); $g.Dispose()
        return $bmp
    }
    catch {
        return $null
    }
}

function Get-WhaleBitmap {
    # Load the DeepSeek whale PNG as a generic Bitmap (used for state icons + toasts).
    $path = Join-Path $script:TrayRoot "assets\dsh-whale.png"
    if (Test-Path -LiteralPath $path) {
        try { return [System.Drawing.Bitmap]::FromFile($path) } catch { }
    }
    return $null
}

function Resolve-UiFont {
    # Single source of truth for the UI font (menu + toasts). Uses the configured
    # $script:Config.uifont with graceful fallbacks: configured -> "Segoe UI" ->
    # the system default font. Keeps every surface rendering with the same
    # smooth font instead of scattered hard-coded "Segoe UI" constructors.
    param(
        [single]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    $names = @()
    try { if ($script:Config -and -not [string]::IsNullOrWhiteSpace([string]$script:Config.uifont)) { $names += [string]$script:Config.uifont } } catch { }
    $names += "Segoe UI"
    $names += [System.Drawing.SystemFonts]::DefaultFont.Name
    foreach ($n in $names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        try {
            $f = New-Object System.Drawing.Font($n, $Size, $Style)
            # A real font was created -> good.
            if ($f) { return $f }
        } catch { }
    }
    try { return New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont, $Style) } catch { }
    return $null
}

function Apply-FluentThemeToMenu {
    # Theme a ContextMenuStrip (and all nested ToolStripItems, except images)
    # with the fluent color table + text colours, matching the resolved theme.
    param(
        [System.Windows.Forms.ContextMenuStrip]$Menu
    )
    try {
        $dark = Resolve-MenuTheme
        $ct = New-Object DshFluentColorTable
        $ct.Dark = $dark
        $Menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer($ct)
        $fg = if ($dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
        foreach ($item in $Menu.Items) {
            try { $item.ForeColor = $fg } catch { }
        }
    } catch { }
}

function New-WhaleStateIcon {
    # Brand the tray state icons with the whale instead of SystemIcons:
    # a coloured ring (green/amber/red/grey) is drawn around the whale so the
    # state stays readable while keeping the DeepSeek brand everywhere.
    param(
        [ValidateSet("Healthy", "Warning", "Error", "Stopped")]
        [string]$State = "Healthy"
    )
    try {
        # Draw the pristine whale onto a raster copy (avoids the DrawIcon
        # overload problem that produced the old cosmetic WARN).
        $src = if ($script:WhaleIcon) {
            $tmp = New-Object System.Drawing.Bitmap($script:WhaleIcon.Width, $script:WhaleIcon.Height)
            $tg = [System.Drawing.Graphics]::FromImage($tmp)
            $tg.DrawIconUnstretched($script:WhaleIcon, (New-Object System.Drawing.Rectangle(0, 0, $tmp.Width, $tmp.Height)))
            $tg.Dispose()
            $tmp
        } else { Get-WhaleBitmap }
        if (-not $src) { return $null }
        $size = $src.Width
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, 0, 0, $size, $size)
        $src.Dispose()

        switch ($State) {
            "Error"   { $ring = [System.Drawing.Color]::FromArgb(255, 232, 17, 35) }
            "Warning" { $ring = [System.Drawing.Color]::FromArgb(255, 246, 191, 38) }
            "Stopped" { $ring = [System.Drawing.Color]::FromArgb(220, 128, 128, 128) }
            default   { $ring = [System.Drawing.Color]::FromArgb(255, 0, 180, 128) }
        }
        $pen = New-Object System.Drawing.Pen($ring, [single]([Math]::Max(2, $size * 0.08)))
        $pad = [single]([Math]::Max(1, $size * 0.06))
        $g.DrawEllipse($pen, $pad, $pad, $size - 2 * $pad, $size - 2 * $pad)
        $pen.Dispose()
        $g.Dispose()
        $h = $bmp.GetHicon()
        $ic = [System.Drawing.Icon]::FromHandle($h)
        $returnIco = $ic.Clone()
        $bmp.Dispose()
        return $returnIco
    }
    catch {
        return $null
    }
}

function Show-Balloon {
    # Unified notification entry point. All call sites keep passing
    # -Title/-Text/-Icon (ToolTipIcon); here we route to the modern Win11 toast
    # when enabled, otherwise fall back to the classic WinForms balloon.
    param(
        [string]$Title,
        [string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    if (-not $script:Config -or -not $script:Config.notifications) { return }
    $useToasts = $true
    try { $useToasts = [bool]$script:Config.toastson } catch { }
    if (($useToasts) -and $script:NotifyIcon) {
        try { Show-Toast -Title $Title -Text $Text -Kind $Icon; return } catch {
            Write-TrayLog "WARN toast failed, falling back to balloon: $($_.Exception.Message)"
        }
    }
    if (-not $script:NotifyIcon) { return }
    try {
        $script:NotifyIcon.BalloonTipTitle = $Title
        $script:NotifyIcon.BalloonTipText  = $Text
        $script:NotifyIcon.BalloonTipIcon  = $Icon
        $script:NotifyIcon.ShowBalloonTip(3000)
    }
    catch {
        Write-TrayLog "WARN balloon failed: $($_.Exception.Message)"
    }
}

$script:ToastForm = $null     # currently visible toast form (only one at a time)

function Close-Toast {
    # Close a toast form, optionally with a fade-out (symmetric with the
    # fade-in). The fade runs on its own timer so the UI thread never blocks.
    param(
        [System.Windows.Forms.Form]$Form,
        [bool]$Fade = $true
    )
    if (-not $Form) { return }
    if (-not $Fade) {
        try { $Form.Close() } catch { }
        return
    }
    try {
        $fadeTimer = New-Object System.Windows.Forms.Timer
        $fadeTimer.Tag = $Form
        $fadeTimer.Interval = 24
        $fadeTimer.add_Tick({
            $ft = $this
            $ff = $ft.Tag
            try {
                $ff.Opacity = [Math]::Max(0, $ff.Opacity - 0.18)
                if ($ff.Opacity -le 0) {
                    $ft.Stop()
                    try { $ff.Close() } catch { }
                }
            } catch {
                try { $ft.Stop() } catch { }
            }
        })
        $fadeTimer.Start()
    }
    catch {
        try { $Form.Close() } catch { }
    }
}

function Show-Toast {
    # A custom Windows-11-style toast: borderless, rounded corners (DWM),
    # accent bar on the left coloured by severity, whale icon, bold title,
    # body text, close button; opens top-right with a fade, auto-dismisses.
    # Debounce: if the visible toast was shown less than $ToastDebounceMs ago,
    # it is *updated in place* (title/body/accent) instead of recreated - this
    # kills the startup "blinking" flicker from rapid successive transitions.
    param(
        [string]$Title,
        [string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Kind = [System.Windows.Forms.ToolTipIcon]::Info
    )
    if (-not $script:NotifyIcon) { return }

    $dark = Resolve-MenuTheme
    $accent = Get-AccentColor
    $bg        = if ($dark) { [System.Drawing.Color]::FromArgb(32, 32, 32) }       else { [System.Drawing.Color]::White }
    $fg        = if ($dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) }    else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
    $fgDim     = if ($dark) { [System.Drawing.Color]::FromArgb(160, 160, 160) }    else { [System.Drawing.Color]::FromArgb(110, 110, 110) }
    $closeHov  = if ($dark) { [System.Drawing.Color]::FromArgb(60, 60, 60) }       else { [System.Drawing.Color]::FromArgb(235, 235, 235) }

    switch ($Kind) {
        ([System.Windows.Forms.ToolTipIcon]::Warning) { $bar = [System.Drawing.Color]::FromArgb(246, 191, 38) }
        ([System.Windows.Forms.ToolTipIcon]::Error)   { $bar = [System.Drawing.Color]::FromArgb(232, 17, 35) }
        default                                       { $bar = $accent }
    }

    # Rapid-succession debounce: update the already-visible toast in place.
    if ($script:ToastForm) {
        try {
            $age = (Get-Date) - $script:ToastShownAt
            if ($age.TotalMilliseconds -lt $script:ToastDebounceMs) {
                $c = $script:ToastForm.Tag
                $c.TitleLbl.Text = $Title
                $c.BodyLbl.Text = $Text
                $c.Bar.BackColor = $bar
                # Restart the auto-dismiss countdown so the updated toast stays visible.
                try { if ($c.CloseTimer) { $c.CloseTimer.Stop(); $c.CloseTimer.Start() } } catch { }
                $script:ToastShownAt = Get-Date
                return
            }
        } catch { }
        # Outside the debounce window: fade the old toast out first.
        Close-Toast -Form $script:ToastForm -Fade $true
    }

    # Whale image for the toast (24 px).
    $whaleImg = $null
    try {
        $wb = Get-WhaleBitmap
        if ($wb) {
            $whaleImg = New-Object System.Drawing.Bitmap(24, 24)
            $wg = [System.Drawing.Graphics]::FromImage($whaleImg)
            $wg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $wg.DrawImage($wb, 0, 0, 24, 24)
            $wg.Dispose(); $wb.Dispose()
        }
    } catch { }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition    = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ShowInTaskbar    = $false
    $form.TopMost          = $true
    $form.BackColor        = $bg
    $form.Padding          = New-Object System.Windows.Forms.Padding(0)
    $form.Height           = 84
    $form.Width            = 350

    # Context bag carried on the form's and each control's .Tag so event
    # handlers can reach the form/colors/image via $this.Tag — PowerShell
    # delegates do NOT reliably capture local variables once the defining
    # function returns, so referencing $form here would break (e.g. the
    # asynchronous Shown/Tick/Click handlers crash on 'property not found').
    $ctx = @{ Form = $form; CloseHov = $closeHov; Whale = $whaleImg; CloseTimer = $null }
    $form.Tag = $ctx

    # Accent bar (left).
    $barPanel = New-Object System.Windows.Forms.Panel
    $barPanel.Width = 5
    $barPanel.Dock = [System.Windows.Forms.DockStyle]::Left
    $barPanel.BackColor = $bar
    $form.Controls.Add($barPanel)

    # Close button.
    $close = New-Object System.Windows.Forms.Label
    $close.Text = "×"
    $close.ForeColor = $fgDim
    $close.BackColor = [System.Drawing.Color]::Transparent
    $close.Font = (Resolve-UiFont -Size 12 -Style ([System.Drawing.FontStyle]::Regular))
    $close.Size = New-Object System.Drawing.Size(24, 24)
    $close.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $close.Cursor = [System.Windows.Forms.Cursors]::Hand
    $close.Location = New-Object System.Drawing.Point(322, 4)
    $close.Tag = $ctx
    $close.add_MouseEnter({ $this.BackColor = $this.Tag.CloseHov })
    $close.add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::Transparent })
    $close.add_Click({ try { $this.Tag.Form.Close() } catch { } })

    # Icon (whale) top-left.
    $iconPic = New-Object System.Windows.Forms.PictureBox
    $iconPic.Size = New-Object System.Drawing.Size(24, 24)
    $iconPic.Location = New-Object System.Drawing.Point(14, 12)
    $iconPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    if ($whaleImg) { $iconPic.Image = $whaleImg }

    # Title (bold) under/next to icon.
    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = $Title
    $titleLbl.ForeColor = $fg
    $titleLbl.Font = (Resolve-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold))
    $titleLbl.Location = New-Object System.Drawing.Point(46, 10)
    $titleLbl.Size = New-Object System.Drawing.Size(268, 22)
    $titleLbl.AutoEllipsis = $true

    # Body text wraps.
    $bodyLbl = New-Object System.Windows.Forms.Label
    $bodyLbl.Text = $Text
    $bodyLbl.ForeColor = $fgDim
    $bodyLbl.Font = (Resolve-UiFont -Size 9 -Style ([System.Drawing.FontStyle]::Regular))
    $bodyLbl.Location = New-Object System.Drawing.Point(46, 32)
    $bodyLbl.Size = New-Object System.Drawing.Size(286, 44)

    # Click on content opens the dashboard.
    foreach ($c in @($iconPic, $titleLbl, $bodyLbl)) {
        $c.Cursor = [System.Windows.Forms.Cursors]::Hand
        $c.Tag = $ctx
        $c.add_Click({ try { Start-DshApp } catch { } ; try { $this.Tag.Form.Close() } catch { } })
    }

    # Expose the labels/bar for the in-place update path.
    $ctx.TitleLbl = $titleLbl
    $ctx.BodyLbl = $bodyLbl
    $ctx.Bar = $barPanel

    $form.Controls.Add($bodyLbl)
    $form.Controls.Add($titleLbl)
    $form.Controls.Add($iconPic)
    $form.Controls.Add($close)
    $form.Controls.Add($barPanel)

    # Position top-right above the system tray.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $pad = 12
    $toastX = $wa.Right - $form.Width - $pad
    $toastY = $wa.Top + $pad
    $form.Location = New-Object System.Drawing.Point($toastX, $toastY)

    $script:ToastForm = $form

    $form.add_Shown({
        # $this is the toast form (event sender). Rounded corners on Win11;
        # try Mica on 22H2+, ignore failures on Win10.
        $f = $this
        try { [DshDwm]::ApplyRoundCorners($f.Handle) } catch { }
        try { [DshDwm]::TryMica($f.Handle) } catch { }
        try { $f.Opacity = 0 } catch { }
        $animTimer = New-Object System.Windows.Forms.Timer
        $animTimer.Tag = $f
        $animTimer.Interval = 32
        $animTimer.add_Tick({
            # $this is the animation timer; the form rides on .Tag.
            $timer = $this
            $ff = $timer.Tag
            try {
                $ff.Opacity = [Math]::Min(1.0, $ff.Opacity + 0.14)
                if ($ff.Opacity -ge 1.0) {
                    $timer.Stop()
                    $closeTimer = New-Object System.Windows.Forms.Timer
                    $closeTimer.Tag = $ff
                    $closeTimer.Interval = 4000
                    $closeTimer.add_Tick({
                        try {
                            $this.Stop()
                            $tf = $this.Tag
                            Close-Toast -Form $tf -Fade $true
                        } catch { }
                    })
                    # Publish the auto-dismiss timer so the in-place update path
                    # can restart it when the toast content is refreshed.
                    try { $ff.Tag.CloseTimer = $closeTimer } catch { }
                    $closeTimer.Start()
                }
            } catch {
                try { $timer.Stop() } catch { }
            }
        })
        $animTimer.Start()
    })
    $form.add_Closed({
        if ($script:ToastForm -eq $this) { $script:ToastForm = $null }
        try { if ($this.Tag.Whale) { $this.Tag.Whale.Dispose() } } catch { }
    })

    $script:ToastShownAt = Get-Date
    try { $form.Show() } catch { }
}



function Set-TrayStatus {
    param(
        [string]$Text,
        [ValidateSet("Healthy", "Warning", "Error", "Stopped")]
        [string]$State = "Warning"
    )

    if ($script:StatusItem) {
        $script:StatusItem.Text = $Text
    }
    if (-not $script:NotifyIcon) {
        return
    }

    $tooltip = "dsh :$($script:Port) - $Text"
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }
    $script:NotifyIcon.Text = $tooltip

    # Remember the state first so the icon composition (with agent badge)
    # can pick the correct state base icon.
    $script:LastState = $State
    if ($script:Config.badgeicon) {
        # Compose state icon + running-agent badge.
        Update-TrayIcon
    }
    else {
        if ($script:WhaleIcon -and $State -eq "Healthy") {
            $script:NotifyIcon.Icon = $script:WhaleIcon
        }
        else {
            $stateIco = New-WhaleStateIcon -State $State
            $script:NotifyIcon.Icon = if ($stateIco) { $stateIco } elseif ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Application }
        }
    }

    # Pure display: status text, tooltip and icon. Notification *toasts* are
    # NOT fired here (v1.7.0) - they belong to the debounced watchdog decision
    # in Invoke-HealthDecision, so a single flapping health probe can no longer
    # trigger a "recovered"/"unhealthy" toast flicker.
    if ($State -ne $script:LastStatusState) {
        Write-TrayLog "status transition: $($script:LastStatusState) -> $State ($Text)"
        $script:LastStatusState = $State
    }
}

function Test-DshHealth {
    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($script:HealthUrl)
        $request.Method = "GET"
        $request.Timeout = 2000
        $request.ReadWriteTimeout = 2000
        $request.Proxy = $null
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
    finally {
        if ($response) {
            $response.Close()
        }
    }
}

function Get-CachedHealth {
    # Latest *completed* async health probe. Never touches the network - used by
    # everything that runs on the UI thread (Start-DshProxy, Invoke-AgentPoll).
    # Returns $true/$false when fresh enough, $null when unknown/stale.
    $h = $script:HealthResult
    if ($null -eq $h -or -not $h.ContainsKey("Healthy")) { return $null }
    try {
        $age = (Get-Date) - $h.At
        if ($age.TotalSeconds -gt ([Math]::Max($script:HealthIntervalSeconds, 5) * 2)) {
            return $null
        }
    }
    catch { return $null }
    return $h.Healthy
}

# --- v1.7.0: background runspace jobs ------------------------------------------
# All blocking network work (health probe, agent session.list, npm update check)
# runs here. Start-AsyncJob opens a dedicated runspace and BeginInvoke's the
# script; the 1s UI timer collects completed jobs in Invoke-AsyncJobSweep and
# dispatches the result through Invoke-AsyncJobCompleted - always on the UI
# thread, so state counters and WinForms calls stay single-threaded.

function Start-AsyncJob {
    param(
        [string]$Id,
        [string]$Script,
        [object[]]$Arguments = @(),
        [System.Threading.ApartmentState]$Apartment = [System.Threading.ApartmentState]::Unknown
    )
    if ($script:AsyncJobs.ContainsKey($Id)) { return $Id }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    # UI Automation (the "new conversation" GUI driving) must run on an STA
    # thread; health/agent/update jobs are unaffected by this.
    if ($Apartment -ne [System.Threading.ApartmentState]::Unknown) {
        try { $rs.ApartmentState = $Apartment } catch { }
    }
    try { $rs.Open() } catch {
        try { $rs.Dispose() } catch { }
        Write-TrayLog "WARN async job $Id could not open runspace: $($_.Exception.Message)"
        return $null
    }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $script:AsyncJobs[$Id] = @{ PS = $ps; Handle = $handle; Rs = $rs; Started = Get-Date }
    return $Id
}

function Invoke-AsyncJobSweep {
    # Called from the 1s UI timer tick. Polls in-flight runspaces for completion
    # and dispatches results on the UI thread. Never blocks on the job itself.
    if ($script:AsyncJobs.Count -eq 0) { return }
    foreach ($id in @($script:AsyncJobs.Keys)) {
        $job = $script:AsyncJobs[$id]
        try {
            if ($job.PS.InvocationStateInfo.State -ne 'Running') {
                $output = @($job.PS.EndInvoke($job.Handle))
                $errors = @($job.PS.Streams.Error | ForEach-Object { $_.ToString() })
                try { $job.PS.Dispose() } catch { }
                try { $job.Rs.Dispose() } catch { }
                $script:AsyncJobs.Remove($id)
                Invoke-AsyncJobCompleted -Id $id -Output $output -Errors $errors
            }
        }
        catch {
            Write-TrayLog "ERROR async job $id sweep: $($_.Exception.Message)"
            try { $job.PS.Dispose() } catch { }
            try { $job.Rs.Dispose() } catch { }
            $script:AsyncJobs.Remove($id)
            if ($id -eq "newconv") {
                # A job that died in the sweep must never leave the "New
                # Conversation" menu item stuck disabled/"...".
                if ($script:NewChatMenuItem) {
                    $script:NewChatMenuItem.Enabled = $true
                    $script:NewChatMenuItem.Text = $script:L.MenuNewChat
                }
            }
        }
    }
}

function Invoke-AsyncJobCompleted {
    param(
        [string]$Id,
        [object[]]$Output,
        [string[]]$Errors
    )
    switch ($Id) {
        "healthprobe" {
            $healthy = $false
            if ($Output.Count -gt 0) { $healthy = [bool]$Output[0] }
            $script:HealthProbeInFlight = $false
            $script:HealthResult = @{ Healthy = $healthy; At = Get-Date }
            if ($null -eq $script:FirstProbeAt) {
                $script:FirstProbeAt = Get-Date
                $script:FirstProbeHealthy = $healthy
                Write-TrayLog "first health probe completed after $([int]((Get-Date) - $script:TrayStartedAt).TotalMilliseconds)ms (healthy=$healthy)"
            }
            $script:HealthApplyPending = $true
        }
        "agentpoll" {
            $script:AgentPollInFlight = $false
            Complete-AgentPoll -Output $Output
        }
        "updatecheck" {
            Complete-UpdateCheck -Output $Output
        }
        "newconv" {
            # v1.7.1: "New Conversation" (GUI automation + RPC fallback) ran in
            # the background; apply the result (balloon / open the app) here.
            Complete-NewConversation -Output $Output
        }
        default {
            if ($Id -like "agentstop-*") {
                # v1.7.1: per-agent "Stop" RPC completed in the background.
                Complete-AgentStop -Id $Id -Output $Output
            }
            else {
                Write-TrayLog "WARN unknown async job completed: $Id"
            }
        }
    }
}

function Start-HealthProbe {
    # Kick one non-blocking health probe in a background runspace. The result
    # lands in $script:HealthResult and drives the next watchdog decision.
    if ($script:HealthProbeInFlight) { return }
    if (-not $script:HealthUrl) { return }
    $script:HealthProbeInFlight = $true
    $url = $script:HealthUrl
    $probeScript = @'
    param([string]$Url)
    $r = $null
    $resp = $null
    try {
        $r = [System.Net.HttpWebRequest]::Create($Url)
        $r.Method = "GET"
        $r.Timeout = 2000
        $r.ReadWriteTimeout = 2000
        $r.Proxy = $null
        $resp = $r.GetResponse()
        return ([int]$resp.StatusCode -eq 200)
    } catch {
        return $false
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
'@
    $jobId = Start-AsyncJob -Id "healthprobe" -Script $probeScript -Arguments @($url)
    if ($null -eq $jobId) {
        $script:HealthProbeInFlight = $false
    }
}

# --- v1.7.0: debounced health state machine -------------------------------------
# Gates *notification* transitions. The raw probe may flap (a server can accept
# TCP but not serve 200 yet); we only count a flip to Healthy/Unhealthy after
# healthconfirmations consecutive probes in the same direction, or after
# healthdebounceseconds of a persistent candidate. During the startup grace
# window unhealthy probes are expected and never start a confirmation.

function Update-StableHealth {
    param(
        [bool]$Healthy,
        [bool]$GraceActive = $false,
        [datetime]$Now = (Get-Date)
    )
    $want = if ($Healthy) { "Healthy" } else { "Unhealthy" }

    # First probe of a session: baseline, never a "transition".
    if ($null -eq $script:StableHealth) {
        $script:StableHealth = $want
        $script:StableHealthSince = $Now
        $script:HealthFlipCandidate = $null
        $script:HealthFlipStreak = 0
        if ($want -eq "Healthy") { $script:HealthyEver = $true }
        return $script:StableHealth
    }

    # During startup grace an unhealthy probe is the *expected* warming state:
    # it must not start an Unhealthy confirmation (and it cancels any half-made
    # flip candidate so the server has to prove itself again).
    if ($GraceActive -and $want -eq "Unhealthy") {
        $script:HealthFlipCandidate = $null
        $script:HealthFlipStreak = 0
        return $script:StableHealth
    }

    if ($want -eq $script:StableHealth) {
        $script:HealthFlipCandidate = $null
        $script:HealthFlipStreak = 0
        return $script:StableHealth
    }

    # A flip away from the current stable state is being confirmed.
    if ($script:HealthFlipCandidate -eq $want) {
        $script:HealthFlipStreak++
        $elapsed = ($Now - $script:HealthFlipCandidateSince).TotalSeconds
        $conf = [int]$script:Config.healthconfirmations
        if ($conf -lt 1) { $conf = 1 }
        $debSec = [double]$script:Config.healthdebounceseconds
        if ($debSec -lt 0) { $debSec = 0 }
        if ($script:HealthFlipStreak -ge $conf -or ($debSec -gt 0 -and $elapsed -ge $debSec)) {
            $script:StableHealth = $want
            $script:StableHealthSince = $Now
            $script:HealthFlipCandidate = $null
            $script:HealthFlipStreak = 0
            $script:StableHealthFlippedTo = $want
        }
        return $script:StableHealth
    }

    # Direction changed while confirming -> start over from the new direction.
    $script:HealthFlipCandidate = $want
    $script:HealthFlipCandidateSince = $Now
    $script:HealthFlipStreak = 1
    return $script:StableHealth
}

function Show-ErrorBalloon {
    # Watchdog-driven error toast with a 30s rate limit so a crash-loop cannot
    # spam the same "start failed" message on every backoff attempt.
    param([string]$Text)
    $now = Get-Date
    if ($script:LastErrorBalloonAt -ne [DateTime]::MinValue) {
        if (($now - $script:LastErrorBalloonAt).TotalSeconds -lt 30) { return }
    }
    $script:LastErrorBalloonAt = $now
    Show-Balloon -Title $script:L.BalloonError -Text $Text -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
}

function Get-DshLogTail {
    # The tail of dsh-web.log, dumped into the tray log when the watchdog detects
    # a crash - the highest-value context for answering "why did dsh die?".
    param([int]$Count = 20)
    if (Test-Path -LiteralPath $script:DshLogFile) {
        try { return @(Get-Content -LiteralPath $script:DshLogFile -Tail $Count -ErrorAction Stop) } catch { }
    }
    return @()
}

function Write-DshCrashContext {
    $tail = Get-DshLogTail
    Write-TrayLog "web log tail (last $($tail.Count) lines of $(Split-Path -Leaf $script:DshLogFile)):"
    foreach ($t in $tail) { Write-TrayLog "  web| $t" }
}

function Find-DshProcessId {
    # Find the PID listening on our port (the dsh web server).
    $conn = Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        return $conn.OwningProcess
    }
    return $null
}

function Test-DshProcessIdentity {
    # Only kill a process we can positively attribute to dsh web. The PID is
    # looked up by port number, so without this check a foreign process
    # squatting on :$Port would be taskkilled /T /F.
    param([int]$ProcessId)

    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $false
    }

    $name = $proc.Name.ToLowerInvariant()
    $cmdLine = [string]$proc.CommandLine

    # dsh web runs as a Node CLI (npm global shim -> node <cli>\bin.js web);
    # require both a known runtime and a command line that references dsh.
    if ($name -notin @("node.exe", "node", "bun.exe", "bun", "dsh.exe", "dsh")) {
        return $false
    }
    if ($cmdLine -notmatch "dsh") {
        return $false
    }
    return $true
}

# --- config & i18n ----------------------------------------------------------
function Assert-ConfigNumeric {
    # Validate a numeric config field read from dsh-tray.json. Accepts real
    # numbers and numeric strings (back-compat: a quoted "10" used to flow into
    # an [int] cast). Garbage - a non-number, or a value outside [Min..Max] -
    # is logged as a WARN (field name + original value + applied default) and
    # the safe default is returned instead of silently accepting it.
    param(
        [string]$Key,
        [object]$Value,
        [object]$Default,
        [double]$Min,
        [double]$Max
    )
    $num = $null
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [float] -or $Value -is [single]) {
        $num = [double]$Value
    }
    elseif ($Value -is [string]) {
        $t = $Value.Trim()
        if ($t -match '^[+-]?\d+(\.\d+)?$') { $num = [double]$t }
    }
    if ($null -eq $num -or [double]::IsNaN($num) -or [double]::IsInfinity($num)) {
        Write-TrayLog "WARN config key '$Key': value '$Value' is not a number; using default $Default"
        return $Default
    }
    if ($num -lt $Min -or $num -gt $Max) {
        Write-TrayLog "WARN config key '$Key': value '$Value' out of range [$Min..$Max]; using default $Default"
        return $Default
    }
    return $num
}

function Read-Config {
    param([string]$ConfigPath)
    $cfg = @{}
    # Defaults are generic; a dsh-tray.json next to the script overrides them.
    # 3080 is dsh web's out-of-the-box default port (official README + the
    # web-app bundle's own patch). The author's machine overrides to 3090 via
    # its profile patch (~/.dsh/profiles/web/cordis.patch.yml) to coexist with
    # the WSL instance - that stays in the local dsh-tray.json.
    $defaults = @{
        port                 = 3080
        startscript          = (Join-Path $script:TrayRoot "start-dsh.cmd")
        dshlogfile           = (Join-Path $script:TrayRoot "logs\dsh-web.log")
        healthintervalseconds = 10
        startupgraceseconds  = 120
        restartdelayseconds  = 5
        # --- v1.7.1: crash-loop protection ---
        # Consecutive crash-restart attempts before the tray stops auto-restarting
        # and demands a manual "Restart dsh" (resets the counter). Safe default;
        # the backoff itself still grows 5s -> 30s (restartdelayseconds * min(n,6)).
        maxconsecutiverestarts = 10
        # --- v1.7.0: health-flap debounce (see Update-StableHealth) ---
        # A health flip to Healthy/Unhealthy only counts once the new state is
        # confirmed by this many consecutive probes (healthconfirmations) OR has
        # persisted for healthdebounceseconds - so a server that opens its port
        # before it can serve 200 does not cause "unhealthy"/"recovered" toast
        # flapping during startup.
        healthconfirmations   = 2
        healthdebounceseconds = 20
        language             = "auto"
        notifications        = $true
        whaleicon            = $true
        # --- v1.4.0: agent monitor / notifications / icon badge ---
        agentmonitor         = $true   # include the "Agents" submenu + polling
        agentpollseconds     = 5       # cadence of the agent poll (min 2)
        agentnotifications   = $true   # balloon on agent start / finish / waiting
        badgeicon            = $true   # overlay running-agent count on the tray icon
        maxagentloglines     = 200     # line cap for the agent log window
        agenthistorylines    = 40      # events pulled from subagent.history for the log tail
        # --- v1.4.1: open the dashboard in the installed Chrome App (PWA), not a tab ---
        # Path to the "DeepSeek Harness" Chrome App shortcut
        # (Chrome Apps\DeepSeek Harness.lnk). If empty/missing the tray falls
        # back to opening a regular browser tab.
        chromeapplnk         = $null
        # --- v1.5.0: modern Windows-11 UI ---
        menutheme            = "auto"   # auto | light | dark (auto follows the system)
        toastson             = $true    # true -> modern Win11 toasts; false -> classic balloon
        menubicons           = $true    # show MDL2 glyph icons on menu items
        # --- v1.6.0: unified smooth fonts + dsh update checks ---
        uifont               = "Segoe UI Variable Text"  # menu + toast font (falls back to Segoe UI)
        uifontsize           = 9        # base body font size (pt) for menu + toasts
        updatecheck          = $true    # enable checking for a newer @deepseek-ai/dsh on npm
        updateintervalhours  = 24       # auto-check cadence (0 disables the periodic check)
        updateapply          = $true    # allow one-click "Update" via `npm i -g @deepseek-ai/dsh@latest`
    }
    $defaults.GetEnumerator() | ForEach-Object { $cfg[$_.Key] = $_.Value }

    if (-not $ConfigPath) { $ConfigPath = Join-Path $script:TrayRoot "dsh-tray.json" }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $user = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $user.PSObject.Properties | ForEach-Object {
                $key = $_.Name.ToLowerInvariant()
                if ($defaults.ContainsKey($key)) {
                    $cfg[$key] = $_.Value
                }
                else {
                    Write-TrayLog "WARN unknown config key: $($_.Name)"
                }
            }
        }
        catch {
            Write-TrayLog "WARN failed to parse dsh-tray.json: $($_.Exception.Message)"
        }
    }

    # --- v1.7.1: numeric validation -----------------------------------------
    # Garbage in dsh-tray.json (a string instead of a number, a zero/negative
    # where that is meaningless, or an out-of-range value) must not silently
    # corrupt the watchdog. Each check logs a WARN (field, original, applied
    # default) and falls back to the safe default; valid values pass through.
    $cfg['port']                 = [int](Assert-ConfigNumeric -Key 'port' -Value $cfg['port'] -Default 3080 -Min 1 -Max 65535)
    $cfg['healthintervalseconds'] = [int](Assert-ConfigNumeric -Key 'healthintervalseconds' -Value $cfg['healthintervalseconds'] -Default 10 -Min 1 -Max 3600)
    $cfg['startupgraceseconds']   = [int](Assert-ConfigNumeric -Key 'startupgraceseconds' -Value $cfg['startupgraceseconds'] -Default 120 -Min 0 -Max 86400)
    $cfg['restartdelayseconds']   = [int](Assert-ConfigNumeric -Key 'restartdelayseconds' -Value $cfg['restartdelayseconds'] -Default 5 -Min 1 -Max 3600)
    $cfg['healthconfirmations']   = [int](Assert-ConfigNumeric -Key 'healthconfirmations' -Value $cfg['healthconfirmations'] -Default 2 -Min 1 -Max 100)
    $cfg['healthdebounceseconds'] = [double](Assert-ConfigNumeric -Key 'healthdebounceseconds' -Value $cfg['healthdebounceseconds'] -Default 20 -Min 0 -Max 86400)
    $cfg['agentpollseconds']      = [int](Assert-ConfigNumeric -Key 'agentpollseconds' -Value $cfg['agentpollseconds'] -Default 5 -Min 2 -Max 3600)
    $cfg['maxagentloglines']      = [int](Assert-ConfigNumeric -Key 'maxagentloglines' -Value $cfg['maxagentloglines'] -Default 200 -Min 1 -Max 10000)
    $cfg['agenthistorylines']     = [int](Assert-ConfigNumeric -Key 'agenthistorylines' -Value $cfg['agenthistorylines'] -Default 40 -Min 1 -Max 1000)
    $cfg['updateintervalhours']   = [int](Assert-ConfigNumeric -Key 'updateintervalhours' -Value $cfg['updateintervalhours'] -Default 24 -Min 0 -Max 8760)
    $cfg['uifontsize']            = [int](Assert-ConfigNumeric -Key 'uifontsize' -Value $cfg['uifontsize'] -Default 9 -Min 6 -Max 72)
    $cfg['maxconsecutiverestarts'] = [int](Assert-ConfigNumeric -Key 'maxconsecutiverestarts' -Value $cfg['maxconsecutiverestarts'] -Default 10 -Min 1 -Max 1000)

    # URL fields are derived from the port unless explicitly set.
    $cfg['healthurl']    = "http://127.0.0.1:$($cfg['port'])/"
    $cfg['dashboardurl'] = "http://127.0.0.1:$($cfg['port'])/"
    return $cfg
}

function Resolve-Language {
    param([string]$Lang)
    if ($Lang -eq 'zh') { return 'zh' }
    if ($Lang -eq 'ru') { return 'ru' }
    if ($Lang -eq 'en') { return 'en' }
    $ui = Get-UICulture
    if ($ui.Name -like 'zh*') { return 'zh' }
    if ($ui.Name -like 'ru*') { return 'ru' }
    return 'en'
}

function Init-I18n {
    $lang = Resolve-Language $script:Config.language
    $script:Lang = $lang

    $script:Strings = @{
        zh = @{
            StatusHealthy       = "Healthy (:PORT)"
            StatusStarting      = "Starting..."
            StatusWarming       = "Warming up (Ns grace)"
            StatusUnhealthy     = "Unhealthy (n/3)"
            StatusStopped       = "Stopped"
            StatusRestartPending = "Restart pending"
            StatusScriptMissing = "Start script missing"
            StatusStartFailed   = "Start failed; retry pending"
            StatusNeedsIntervention = "需要人工干预"
            MenuDashboard       = "打开面板"
            MenuNewChat         = "开启新对话"
            MenuRestart         = "重启 dsh"
            MenuStop            = "停止 dsh"
            MenuExit            = "退出"
            MenuCopyLog         = "复制最近日志"
            MenuAutostart       = "开机自启"
            MenuAgents          = "代理 (Agents)"
            MenuAgentsNone      = "(无运行中代理)"
            MenuAgentsWaiting   = "等待输入"
            MenuAgentShowLog    = "查看日志"
            MenuAgentStop       = "停止代理"
            MenuAgentRefresh    = "刷新列表"
            AgentStatusRow      = "运行中代理: N  (等待: M)"
            BalloonAgentStart   = "代理已启动"
            BalloonAgentStartHint = "{0} 开始运行"
            BalloonAgentFinish  = "代理已完成"
            BalloonAgentFinishHint = "{0} 已完成"
            BalloonAgentWaiting = "代理等待输入"
            BalloonAgentWaitingHint = "{0} 等待你的输入"
            BalloonAgentStopped = "代理已停止"
            BalloonAgentStoppedHint = "{0} 已停止"
            BalloonAgentLog     = "代理日志"
            BalloonStarted      = "dsh 已启动"
            BalloonStopped      = "dsh 已停止"
            BalloonRestarting   = "dsh 正在重启"
            BalloonRecovered    = "dsh 已恢复"
            BalloonUnhealthy    = "dsh 异常"
            BalloonCopied       = "日志已复制"
            BalloonNewChat      = "新对话已就绪"
            BalloonNewChatHint = "新对话已开启"
            BalloonError        = "出错"
            BalloonRestartCapExceeded = "dsh 连续崩溃 {0} 次，已停止自动重启。请手动点击「重启 dsh」"
            MenuCheckUpdates    = "检查更新"
            MenuUpdateNow       = "更新到 v{0}"
            BalloonUpdateChecking = "检查更新中…"
            BalloonUpToDate     = "已是最新版本"
            BalloonUpdateAvailable = "发现新版本 {0} → {1}"
            BalloonUpdateAvailableHint = "有新版本可用"
            BalloonUpdating     = "正在更新…"
            BalloonUpdateApplied = "dsh 已更新"
            BalloonUpdateFailed = "更新失败"
        }
        en = @{
            StatusHealthy       = "Healthy (:PORT)"
            StatusStarting      = "Starting..."
            StatusWarming       = "Warming up (Ns grace)"
            StatusUnhealthy     = "Unhealthy (n/3)"
            StatusStopped       = "Stopped"
            StatusRestartPending = "Restart pending"
            StatusScriptMissing = "Start script missing"
            StatusStartFailed   = "Start failed; retry pending"
            StatusNeedsIntervention = "Needs intervention"
            MenuDashboard       = "Open Dashboard"
            MenuNewChat         = "New Conversation"
            MenuRestart         = "Restart dsh"
            MenuStop            = "Stop dsh"
            MenuExit            = "Exit"
            MenuCopyLog         = "Copy Recent Log"
            MenuAutostart       = "Start with Windows"
            MenuAgents          = "Agents"
            MenuAgentsNone      = "(no running agents)"
            MenuAgentsWaiting   = "waiting for input"
            MenuAgentShowLog    = "Show log"
            MenuAgentStop       = "Stop agent"
            MenuAgentRefresh    = "Refresh"
            AgentStatusRow      = "Running agents: N  (waiting: M)"
            BalloonAgentStart   = "agent started"
            BalloonAgentStartHint = "{0} started running"
            BalloonAgentFinish  = "agent finished"
            BalloonAgentFinishHint = "{0} finished"
            BalloonAgentWaiting = "agent waiting"
            BalloonAgentWaitingHint = "{0} is waiting for your input"
            BalloonAgentStopped = "agent stopped"
            BalloonAgentStoppedHint = "{0} stopped"
            BalloonAgentLog     = "agent log"
            BalloonStarted      = "dsh started"
            BalloonStopped      = "dsh stopped"
            BalloonRestarting   = "dsh restarting"
            BalloonRecovered    = "dsh recovered"
            BalloonUnhealthy    = "dsh unhealthy"
            BalloonCopied       = "log copied"
            BalloonNewChat      = "new conversation ready"
            BalloonNewChatHint = "new conversation opened"
            BalloonError        = "error"
            BalloonRestartCapExceeded = "dsh crashed {0} times in a row; auto-restart stopped. Restart manually."
            MenuCheckUpdates    = "Check for Updates"
            MenuUpdateNow       = "Update to v{0}"
            BalloonUpdateChecking = "Checking for updates…"
            BalloonUpToDate     = "You're on the latest version"
            BalloonUpdateAvailable = "New version {0} → {1}"
            BalloonUpdateAvailableHint = "An update is available"
            BalloonUpdating     = "Updating…"
            BalloonUpdateApplied = "dsh updated"
            BalloonUpdateFailed = "Update failed"
        }
        ru = @{
            StatusHealthy       = "Работает (:PORT)"
            StatusStarting      = "Запуск..."
            StatusWarming       = "Прогрев (Ns grace)"
            StatusUnhealthy     = "Нездоров (n/3)"
            StatusStopped       = "Остановлен"
            StatusRestartPending = "Ожидание рестарта"
            StatusScriptMissing = "Скрипт запуска не найден"
            StatusStartFailed   = "Запуск не удался; повторим"
            StatusNeedsIntervention = "Требуется вмешательство"
            MenuDashboard       = "Открыть панель"
            MenuNewChat         = "Новый диалог"
            MenuRestart         = "Перезапустить dsh"
            MenuStop            = "Остановить dsh"
            MenuExit            = "Выход"
            MenuCopyLog         = "Скопировать лог"
            MenuAutostart       = "Автозапуск с Windows"
            MenuAgents          = "Агенты"
            MenuAgentsNone      = "(нет запущенных агентов)"
            MenuAgentsWaiting   = "ждёт ввода"
            MenuAgentShowLog    = "Показать лог"
            MenuAgentStop       = "Остановить агента"
            MenuAgentRefresh    = "Обновить"
            AgentStatusRow      = "Агентов запущено: N  (ждут: M)"
            BalloonAgentStart   = "агент запущен"
            BalloonAgentStartHint = "{0} начал работу"
            BalloonAgentFinish  = "агент завершил работу"
            BalloonAgentFinishHint = "{0} закончил"
            BalloonAgentWaiting = "агент ждёт"
            BalloonAgentWaitingHint = "{0} ждёт вашего ввода"
            BalloonAgentStopped = "агент остановлен"
            BalloonAgentStoppedHint = "{0} остановлен"
            BalloonAgentLog     = "лог агента"
            BalloonStarted      = "dsh запущен"
            BalloonStopped      = "dsh остановлен"
            BalloonRestarting   = "dsh перезапускается"
            BalloonRecovered    = "dsh восстановлен"
            BalloonUnhealthy    = "dsh нездоров"
            BalloonCopied       = "лог скопирован"
            BalloonNewChat      = "новый диалог готов"
            BalloonNewChatHint = "открыт новый диалог"
            BalloonError        = "ошибка"
            BalloonRestartCapExceeded = "dsh упал {0} раз подряд; автозапуск остановлен. Перезапустите вручную."
            MenuCheckUpdates    = "Проверить обновления"
            MenuUpdateNow       = "Обновить до v{0}"
            BalloonUpdateChecking = "Проверка обновлений…"
            BalloonUpToDate     = "Установлена последняя версия"
            BalloonUpdateAvailable = "Доступна новая версия {0} → {1}"
            BalloonUpdateAvailableHint = "Доступно обновление"
            BalloonUpdating     = "Обновление…"
            BalloonUpdateApplied = "dsh обновлён"
            BalloonUpdateFailed = "Не удалось обновить"
        }
    }
    $script:L = $script:Strings[$lang]
}

# --- dsh lifecycle -----------------------------------------------------------
function Start-DshProxy {
    if (-not $script:AutoRestartEnabled -or $script:Exiting) {
        return
    }

    # Use the latest *completed* health probe - never a blocking network call on
    # the UI thread. The watchdog kicks fresh probes asynchronously every
    # healthintervalseconds and applies the result in the next timer tick.
    $h = Get-CachedHealth
    if ($h -eq $true) {
        Set-TrayStatus -Text ($script:L.StatusHealthy -replace ':PORT', ":$($script:Port)") -State Healthy
        $script:RestartAfter = [DateTime]::MinValue
        return
    }
    if ($h -eq $null -and (Find-DshProcessId)) {
        # A listener exists but its health is unconfirmed (first probe still in
        # flight): do not spawn a duplicate server. The next completed probe
        # resolves the state.
        return
    }

    if (-not (Test-Path -LiteralPath $script:StartScript)) {
        Write-TrayLog "ERROR missing start script: $($script:StartScript)"
        Set-TrayStatus -Text $script:L.StatusScriptMissing -State Error
        return
    }

    try {
        $attempt = $script:RestartCount + 1
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$($script:StartScript)`" $($script:Port)" -WindowStyle Hidden | Out-Null
        $script:ManagedByTray = $true
        $script:StartedAt = Get-Date
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        # v1.7.1: RestartCount is NOT reset here. It drives the crash-restart
        # backoff and must survive every start attempt until the service has
        # *proven* itself Healthy (reset in Invoke-HealthDecision). Otherwise a
        # permanently crashing dsh is restarted every ~5s forever (the backoff
        # never escalates because the counter collapses to 0 after each launch).
        Write-TrayLog "Started dsh web (Windows-native) port=$($script:Port) attempt=$attempt"
        Set-TrayStatus -Text $script:L.StatusStarting -State Warning
        # No "dsh started" toast here: startup notifications fire only when the
        # server has *stably* become Healthy (see Invoke-HealthDecision), so a
        # crash-restart loop can never spam toasts.
    }
    catch {
        $script:ManagedByTray = $false
        $script:RestartAfter = (Get-Date).AddSeconds($script:RestartDelaySeconds)
        Write-TrayLog "ERROR start failed: $($_.Exception.Message)"
        Set-TrayStatus -Text $script:L.StatusStartFailed -State Error
        Show-ErrorBalloon -Text $_.Exception.Message
    }
}

function Stop-DshProxy {
    param([string]$Reason = "requested")

    Write-TrayLog "Stopping dsh web reason=$Reason"
    $procId = Find-DshProcessId
    if ($procId) {
        if (-not (Test-DshProcessIdentity -ProcessId $procId)) {
            Write-TrayLog "WARN port $($script:Port) owned by PID $procId is not identified as dsh web; skipping kill"
        }
        else {
            try {
                & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-TrayLog "WARN taskkill exit $LASTEXITCODE for PID $procId"
                }
            }
            catch {
                Write-TrayLog "WARN stop error: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-TrayLog "No listener found on port $($script:Port); nothing to stop"
    }

    # Invalidate the health cache and reset the debounced state machine: the
    # next probe must start from a clean slate so a stale "healthy" cache can
    # never prevent the next Start-DshProxy from launching the server.
    $script:HealthResult = $null
    $script:HealthApplyPending = $false
    $script:StableHealth = $null
    $script:StableHealthSince = [DateTime]::MinValue
    $script:HealthFlipCandidate = $null
    $script:HealthFlipCandidateSince = [DateTime]::MinValue
    $script:HealthFlipStreak = 0
    $script:SawUnhealthy = $false
    $script:HealthyEver = $false
    $script:CrashNotified = $false
    $script:ManagedByTray = $false
    $script:StartedAt = $null
    $script:HealthFailures = 0
    $script:RestartCount = 0
}

function Restart-DshProxy {
    # v1.7.1: a manual Restart explicitly re-enables auto-restart and resets
    # the consecutive-crash counter / cap flag, so after the tray stopped
    # auto-restarting (maxconsecutiverestarts exceeded) one click starts the
    # cycle over again.
    $script:AutoRestartEnabled = $true
    $script:RestartCapHit = $false
    $script:RestartCount = 0

    # Stop if something is listening on our port (identity is re-checked inside
    # Stop-DshProxy before the kill) or if this tray started the service. No
    # health probe is needed here, so a manual restart never blocks the UI.
    if ($script:ManagedByTray -or (Find-DshProcessId)) {
        Stop-DshProxy -Reason "tray restart"
    }

    $script:RestartAfter = (Get-Date).AddSeconds(1)
    Set-TrayStatus -Text $script:L.StatusRestartPending -State Warning
    Show-Balloon -Title $script:L.BalloonRestarting -Text "dsh :$($script:Port)"
}

# --- monitor loop -------------------------------------------------------------
function Notify-Crash {
    # One "dsh crashed" toast per down-episode (cleared when health recovers),
    # so a crash-loop reports the problem once instead of spamming.
    if ($script:CrashNotified) { return }
    $script:CrashNotified = $true
    $script:SawUnhealthy = $true
    Show-Balloon -Title $script:L.BalloonUnhealthy -Text "dsh :$($script:Port) (crash)" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
}

function Invoke-RestartCapHit {
    # v1.7.1: maxconsecutiverestarts exceeded - the tray stops auto-restarting
    # and demands manual intervention. Runs once per episode; the manual
    # "Restart dsh" menu item clears the flag and re-enables auto-restart.
    if ($script:RestartCapHit) { return }
    $script:RestartCapHit = $true
    $script:AutoRestartEnabled = $false
    $script:RestartAfter = [DateTime]::MinValue
    Write-TrayLog "ERROR restart cap exceeded: maxconsecutiverestarts=$($script:Config.maxconsecutiverestarts) consecutive restarts=$($script:RestartCount) healthFailures=$($script:HealthFailures); auto-restart disabled - manual Restart required"
    Set-TrayStatus -Text $script:L.StatusNeedsIntervention -State Error
    Show-Balloon -Title $script:L.BalloonError -Text ($script:L.BalloonRestartCapExceeded -f $script:RestartCount) -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
}

function Invoke-CrashRestartSchedule {
    # v1.7.1: single owner of "a crash was detected, schedule the next attempt".
    # Increments the consecutive-crash counter, applies the 5s -> 30s backoff
    # (RestartDelaySeconds * min(RestartCount,6)) and arms RestartAfter. Once
    # the restart cap is reached this hands off to Invoke-RestartCapHit instead
    # of hammering the process again.
    param([string]$Context = "post-grace")
    $cap = [int]$script:Config.maxconsecutiverestarts
    if ($script:RestartCount -ge $cap) {
        Invoke-RestartCapHit
        return
    }
    $script:RestartCount++
    $backoff = $script:RestartDelaySeconds * [Math]::Min($script:RestartCount, 6)
    $script:RestartAfter = (Get-Date).AddSeconds($backoff)
    if ($Context -eq "grace") {
        Write-TrayLog "dsh process disappeared during startup grace; scheduling restart attempt=$($script:RestartCount) in ${backoff}s"
    }
    else {
        Write-TrayLog "dsh process no longer listening after startup grace; scheduling restart attempt=$($script:RestartCount) in ${backoff}s"
    }
    Write-DshCrashContext
    Notify-Crash
}

function Invoke-HealthDecision {
    # Runs on the UI thread for every *completed* health probe. This is the
    # single owner of watchdog state ($script:HealthFailures, RestartCount,
    # RestartAfter, ManagedByTray...) and of the transition toasts - nothing
    # else mutates those counters, and the runspace threads never touch them.
    param([bool]$Healthy)
    $now = Get-Date

    $graceActive = $false
    if ($script:ManagedByTray -and $script:StartedAt) {
        $ageSeconds = ($now - $script:StartedAt).TotalSeconds
        if ($ageSeconds -lt $script:StartupGraceSeconds) { $graceActive = $true }
    }

    # Debounced stable-health tracking (gates which transitions are "real").
    $null = Update-StableHealth -Healthy $Healthy -GraceActive $graceActive
    $flippedTo = $script:StableHealthFlippedTo
    $script:StableHealthFlippedTo = $null

    if ($Healthy) {
        $script:HealthFailures = 0
        # v1.7.1: the crash-restart counter (which drives the restart backoff)
        # only resets once the service has actually become Healthy again - this
        # is the ONLY place it is zeroed (Start-DshProxy no longer does it).
        $script:RestartCount = 0
        Set-TrayStatus -Text ($script:L.StatusHealthy -replace ':PORT', ":$($script:Port)") -State Healthy

        # Toast only on a *stable* flip to Healthy (not on a flapping probe).
        if ($flippedTo -eq "Healthy") {
            $script:CrashNotified = $false
            if ($script:SawUnhealthy) {
                Show-Balloon -Title $script:L.BalloonRecovered -Text "dsh :$($script:Port)"
                $script:SawUnhealthy = $false
            }
            elseif (-not $script:HealthyEver -and $script:ManagedByTray) {
                Show-Balloon -Title $script:L.BalloonStarted -Text "dsh :$($script:Port)"
            }
            $script:HealthyEver = $true
        }
        return
    }

    # Unhealthy probe.
    if ($flippedTo -eq "Unhealthy") {
        $script:SawUnhealthy = $true
        # "regressed after being Healthy" - meaningful even if the process is
        # still listening. (A crash path is already announced by Notify-Crash.)
        if ($script:HealthyEver -and -not $script:CrashNotified) {
            Show-Balloon -Title $script:L.BalloonUnhealthy -Text "dsh :$($script:Port)" -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    if (-not $script:AutoRestartEnabled) {
        if ($script:RestartCapHit) {
            # v1.7.1: the restart cap was exceeded - keep showing the "needs
            # intervention" status instead of the plain Stopped row so the
            # user knows a manual Restart is required.
            Set-TrayStatus -Text $script:L.StatusNeedsIntervention -State Error
        }
        else {
            Set-TrayStatus -Text $script:L.StatusStopped -State Stopped
        }
        return
    }

    if ($script:ManagedByTray -and $script:StartedAt) {
        $ageSeconds = ($now - $script:StartedAt).TotalSeconds

        if ($ageSeconds -lt $script:StartupGraceSeconds) {
            # During grace we only wait for a *live* process; a crash during
            # boot should not wait out the whole grace period.
            if (-not (Find-DshProcessId)) {
                Invoke-CrashRestartSchedule -Context "grace"
            }
            if ($script:RestartCapHit) { return }
            $remaining = [Math]::Max(0, [Math]::Ceiling($script:StartupGraceSeconds - $ageSeconds))
            Set-TrayStatus -Text ($script:L.StatusWarming -replace 'Ns', "${remaining}s") -State Warning
            return
        }

        # Watchdog policy: the tray manages the *lifecycle*, not liveness.
        #  - Process still listening: never kill it just for being slow to
        #    serve / (a slow cordis boot used to be killed every ~3 min).
        #  - Process gone: that is a crash; schedule a bounded restart with
        #    backoff so a broken install is not hammered every few seconds.
        if (Find-DshProcessId) {
            $script:HealthFailures++
            $display = [Math]::Min($script:HealthFailures, 3)
            Set-TrayStatus -Text ($script:L.StatusUnhealthy -replace 'n/3', "$display/3") -State Error
            return
        }

        $script:HealthFailures = 0
        Invoke-CrashRestartSchedule -Context "post-grace"
        return
    }

    if ($script:RestartAfter -eq [DateTime]::MinValue -or $now -ge $script:RestartAfter) {
        Start-DshProxy
    }
}

function Invoke-MonitorTick {
    $now = Get-Date

    # 1) Collect completed background jobs (health probe, agent poll, update
    #    check, npm install). All completion handlers run on the UI thread.
    Invoke-AsyncJobSweep
    Invoke-UpdateProcessSweep

    # 2) A completed health probe is applied to the watchdog as the *next* tick
    #    so the decision always runs on the UI thread with a fresh result.
    if ($script:HealthApplyPending) {
        $script:HealthApplyPending = $false
        $h = $script:HealthResult
        if ($null -ne $h -and $h.ContainsKey("Healthy")) {
            Invoke-HealthDecision -Healthy ([bool]$h.Healthy)
        }
        else {
            # Probe completed without a usable result - treat as unhealthy.
            Invoke-HealthDecision -Healthy $false
        }
    }

    # Defensive: guard against a cleared/null LastHealthCheck so the tick
    # never hits `DateTime - $null` (PS 5.1 op_Subtraction crash).
    $lastCheck = $script:LastHealthCheck
    if (-not $lastCheck) {
        $lastCheck = [DateTime]::MinValue
    }
    if (($now - $lastCheck).TotalSeconds -lt $script:HealthIntervalSeconds) {
        # Fast path (between health polls): only fire a pending restart once it
        # is due. No HTTP probe here - Start-DshProxy uses the cached probe
        # result, so a down service never blocks the UI thread.
        if (
            $script:AutoRestartEnabled -and
            $script:RestartAfter -ne [DateTime]::MinValue -and
            $now -ge $script:RestartAfter
        ) {
            Start-DshProxy
        }
        return
    }

    # 3) Probe cadence reached: kick a *non-blocking* probe. The completed
    #    result is applied on a later tick (step 2).
    $script:LastHealthCheck = $now
    Start-HealthProbe
}

# --- agent monitor (v1.4.0) ----------------------------------------------------
# Agent detection relies on the harness web RPC surface exposed on the same
# loopback port the tray already health-checks. No WebSocket/SSE needed: we
# poll session.list and diff the set of running subagents between ticks.
#   session.list        -> every session summary; subagent sessions carry
#                          origin='subagent', parentSessionId and subagent.label
#   subagent.history    -> event tail (assistant/message, turn/end reason) for the log
#   subagent.interrupt  -> request a stop on a continuable subagent

function Invoke-DshRpc {
    param(
        [string]$Method,
        [hashtable]$Payload = @{},
        [int]$TimeoutSec = 10
    )
    try {
        $body = @{
            type    = "client-request"
            rpcId   = "tray-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
            method  = $Method
            payload = $Payload
        } | ConvertTo-Json -Compress -Depth 12
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:Port)/api/$Method" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
        if ($resp -and $resp.result -and $resp.result.ok) {
            return $resp.result.value
        }
        return $null
    }
    catch {
        # Rate-limit repeated RPC failures (e.g. session.list while the server
        # is busy): log the first failure and any new error message, then only
        # re-log once every 30 s so the tray log does not flood with identical
        # lines on every poll tick.
        $now = Get-Date
        $last = $script:RpcWarnCooldown[$Method]
        if ($null -eq $last -or ($now - $last).TotalSeconds -gt 30) {
            Write-TrayLog "WARN rpc $Method failed: $($_.Exception.Message)"
            $script:RpcWarnCooldown[$Method] = $now
        }
        return $null
    }
}

function Get-AgentDisplayName {
    param($Session)
    # Prefer the subagent label; fall back to a short id.
    if ($Session.subagent -and $Session.subagent.label) {
        $label = [string]$Session.subagent.label
        if ($label.Trim().Length -gt 0) { return $label }
    }
    $id = [string]$Session.sessionId
    if ($id.Length -ge 12) { return $id.Substring(0, 12) }
    return $id
}

function Convert-AgentReport {
    # Pure parsing of the session.list RPC value into the agent report list.
    # Shared by the synchronous path (menu rebuild) and the async poll result.
    param($Value)
    if ($null -eq $Value -or $null -eq $Value.items) {
        return @()
    }
    $report = @()
    foreach ($s in $Value.items) {
        $isSub = [bool]$s.origin -and $s.origin -eq 'subagent'
        if (-not $isSub) { continue }
        $parent = if ($s.parentSessionId) { [string]$s.parentSessionId } else { "" }
        $mode = if ($s.subagent) { [string]$s.subagent.mode } else { "one-shot" }
        $running = [bool]$s.running
        $state = if ($running) { "running" } elseif ($mode -eq "continuable") { "waiting" } else { "inactive" }
        $report += [pscustomobject]@{
            sessionId       = [string]$s.sessionId
            parentSessionId = $parent
            mode            = $mode
            label           = (Get-AgentDisplayName $s)
            state           = $state
        }
    }
    return $report
}

function Get-RunningAgentReport {
    # Returns a list of { sessionId, parentSessionId, mode, label, state }
    # state: 'running' | 'waiting' | 'inactive'
    # A running subagent = session origin 'subagent' with running=true.
    # A continuable subagent that is not running but still catalogued is treated
    # as 'waiting' (paused awaiting a steer) - best-effort, non-misleading.
    $items = Invoke-DshRpc -Method "session.list"
    return @(Convert-AgentReport -Value $items)
}

function Get-AgentLogTail {
    param(
        [string]$ChildSessionId,
        [string]$ParentSessionId,
        [string]$Mode = "one-shot"
    )
    $payload = @{
        parentSessionId = $ParentSessionId
        childSessionId  = $ChildSessionId
        mode            = $Mode
        maxMessages     = [int]$script:Config.agenthistorylines
    }
    $value = Invoke-DshRpc -Method "subagent.history" -Payload $payload
    if ($null -eq $value -or $null -eq $value.events) {
        return @("<no log available for $ChildSessionId>")
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($h in $value.events) {
        $ev = $h.event
        if (-not $ev -or -not $ev.type) { continue }
        switch -Regex ($ev.type) {
            "assistant/message" {
                try {
                    $content = $ev.data.message.content
                    $text = ""
                    if ($content -is [System.Array]) {
                        foreach ($b in $content) {
                            if ($b.type -eq "text") { $text += $b.text }
                            elseif ($b.type -eq "reasoning") { $text += "[reasoning] " + $b.text }
                        }
                    }
                    elseif ($content) { $text = [string]$content }
                    if ($text.Trim().Length -gt 0) {
                        $lines.Add("assistant: " + $text)
                    }
                } catch { }
            }
            "turn/end" {
                $reason = ""
                try { $reason = [string]$ev.data.reason.kind } catch { }
                if (-not $reason) { $reason = "completed" }
                $lines.Add("--- turn end: $reason ---")
            }
            "agent/start|goal/start|task/start" {
                $lines.Add("--- agent turn started ---")
            }
        }
    }
    if ($lines.Count -eq 0) {
        $lines.Add("<no assistant output yet>")
    }
    return @($lines)
}

function Stop-RunningAgent {
    # v1.7.1: non-blocking kick. The "stop agent" RPC (session.cancel /
    # subagent.interrupt, up to a 10s network timeout) runs on a background
    # runspace via Start-AsyncJob instead of blocking the click handler. The
    # result is applied by Complete-AgentStop on the next timer tick.
    param(
        [string]$ChildSessionId,
        [string]$ParentSessionId,
        [string]$Mode = "continuable",
        [string]$Label = ""
    )
    $jobId = "agentstop-$ChildSessionId"
    if ($script:AsyncJobs.ContainsKey($jobId)) { return }
    $port = $script:Port
    $method = if (-not $ParentSessionId -or $Mode -ne "continuable") { "session.cancel" } else { "subagent.interrupt" }
    $stopScript = @'
    param([int]$Port, [string]$Method, [string]$ChildSessionId, [string]$ParentSessionId, [string]$Mode, [string]$Label)
    $payload = @{}
    if ($Method -eq "session.cancel") {
        $payload.sessionId = $ChildSessionId
    }
    else {
        $payload.parentSessionId = $ParentSessionId
        $payload.childSessionId  = $ChildSessionId
        $payload.mode            = $Mode
    }
    $body = @{
        type    = "client-request"
        rpcId   = "tray-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
        method  = $Method
        payload = $payload
    } | ConvertTo-Json -Compress -Depth 12
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/$Method" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10
        if ($resp -and $resp.result -and $resp.result.ok) {
            return @{ Ok = $true; SessionId = $ChildSessionId; Label = $Label }
        }
    } catch { }
    return @{ Ok = $false; SessionId = $ChildSessionId; Label = $Label }
'@
    $jobId = Start-AsyncJob -Id $jobId -Script $stopScript -Arguments @($port, $method, $ChildSessionId, $ParentSessionId, $Mode, $Label)
    if ($null -eq $jobId) {
        Show-Balloon -Title $script:L.BalloonError -Text "stop could not start" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Complete-AgentStop {
    # v1.7.1: UI-thread completion of the background stop-agent RPC. Preserves
    # the old synchronous Stop-RunningAgent behaviour: success -> "stopped"
    # balloon + mark the agent stopping + force a poll; failure -> error balloon.
    param([string]$Id, [object[]]$Output)
    $result = $null
    if ($Output.Count -gt 0) { $result = $Output[0] }
    $ok = $false; $sid = ""; $label = ""
    if ($result) {
        try {
            $ok = [bool]$result.Ok
            $sid = [string]$result.SessionId
            $label = [string]$result.Label
        } catch { }
    }
    if ($ok) {
        Write-TrayLog "Agent stop requested: $sid"
        Show-Balloon -Title $script:L.BalloonAgentStopped -Text ($script:L.BalloonAgentStoppedHint -f $label)
        $script:AgentKnown[$sid] = "stopping"
        Invoke-AgentPoll -ForceRefresh $true
    }
    else {
        Show-Balloon -Title $script:L.BalloonError -Text "interrupt failed" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function New-AgentBadgeIcon {
    # Composite a small numeric badge (running-agent count) onto the base whale
    # icon. Cached per count so we do not redraw every second.
    param([int]$Count)
    if (-not $script:Config.badgeicon -or $null -eq $script:BaseWhaleIcon) {
        return $script:BaseWhaleIcon
    }
    if ($script:BadgeIconCache.ContainsKey($Count)) {
        return $script:BadgeIconCache[$Count]
    }
    try {
        $ico = $script:BaseWhaleIcon
        $size = $ico.Width
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        # Draw the whale onto the raster via DrawIconUnstretched (avoids the old
        # "Cannot find an overload for DrawIcon" WARN that used a 5-arg overload).
        $g.DrawIconUnstretched($ico, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)))

        if ($Count -gt 0) {
            $text = if ($Count -gt 99) { "99+" } else { [string]$Count }
            $font = New-Object System.Drawing.Font("Segoe UI", [single]9, [System.Drawing.FontStyle]::Bold)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 220, 53, 69))
            $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center

            # Red circle in the top-right corner.
            $pad = 1
            $d = [Math]::Max(14, [int]($size * 0.55))
            $x = $size - $d - $pad
            $y = $pad
            $g.FillEllipse($brush, $x, $y, $d, $d)
            # White outline for legibility.
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]1.5)
            $g.DrawEllipse($pen, $x, $y, $d, $d)

            $rect = New-Object System.Drawing.RectangleF($x, $y, $d, $d)
            $g.DrawString($text, $font, $white, $rect, $sf)

            $sf.Dispose(); $pen.Dispose(); $white.Dispose(); $brush.Dispose(); $font.Dispose()
        }
        $g.Dispose()
        $hIcon = $bmp.GetHicon()
        $ic = [System.Drawing.Icon]::FromHandle($hIcon)
        $bmp.Dispose()
        $script:BadgeIconCache[$Count] = $ic
        return $ic
    }
    catch {
        Write-TrayLog "WARN badge icon failed: $($_.Exception.Message)"
        return $script:BaseWhaleIcon
    }
}

function Update-TrayIcon {
    # Apply the tray icon: the state icon normally; when Healthy and the badge is
    # enabled, composite the running-agent count onto the whale icon instead.
    if (-not $script:NotifyIcon) { return }
    if ($script:LastState -ne "Healthy") {
        if ($null -eq $script:BaseWhaleIcon -and $script:WhaleIcon) {
            $script:BaseWhaleIcon = $script:WhaleIcon
        }
        # Branded whale + coloured state ring (never the stock Windows system icons).
        $stateIco = New-WhaleStateIcon -State $script:LastState
        $script:NotifyIcon.Icon = if ($stateIco) { $stateIco } elseif ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Application }
        return
    }
    if (-not $script:Config.badgeicon -or $null -eq $script:BaseWhaleIcon) {
        $script:NotifyIcon.Icon = if ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Information }
        return
    }
    $script:NotifyIcon.Icon = New-AgentBadgeIcon -Count $script:AgentCount
}

function Show-AgentLogWindow {
    param(
        [string]$Title,
        [string[]]$Lines
    )
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.Width = 640
        $form.Height = 460
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.MinimizeBox = $false
        $form.TopMost = $true

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $tb.Dock = [System.Windows.Forms.DockStyle]::Fill
        $tb.Font = New-Object System.Drawing.Font("Consolas", 9)
        $tb.WordWrap = $false
        $tb.Text = ($Lines -join [Environment]::NewLine)
        $tb.SelectionStart = $tb.TextLength
        $tb.ScrollToCaret()

        $form.Controls.Add($tb)
        [void]$form.ShowDialog()
    }
    catch {
        Write-TrayLog "WARN agent log window failed: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonAgentLog -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Rebuild-AgentMenu {
    param([object[]]$Report = $null)
    if (-not $script:AgentMenuHost) { return }
    $menu = $script:AgentMenu
    $menu.Items.Clear()
    Apply-FluentThemeToMenu -Menu $menu
    try {
        $h = $menu.Handle
    } catch { }
    if (-not $script:Config.agentmonitor) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem
        $none.Text = $script:L.MenuAgentsNone
        $none.Enabled = $false
        [void]$menu.Items.Add($none)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $off = New-Object System.Windows.Forms.ToolStripMenuItem
        $off.Text = $script:L.MenuAgentRefresh
        $off.add_Click({ Invoke-AgentPoll -ForceRefresh $true })
        [void]$menu.Items.Add($off)
        $script:AgentMenuHost.Text = $script:L.MenuAgents
        return
    }

    if ($null -eq $Report) {
        # Only reached from menu handlers that have no fresh async result yet
        # (e.g. the very first rebuild); a real RPC would otherwise block the
        # UI thread, so callers are expected to pass a report when they have one.
        $Report = @(Get-RunningAgentReport)
    }
    $running = @($Report | Where-Object { $_.state -eq "running" })
    $waiting = @($Report | Where-Object { $_.state -eq "waiting" })

    if ($running.Count -eq 0 -and $waiting.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem
        $none.Text = $script:L.MenuAgentsNone
        $none.Enabled = $false
        [void]$menu.Items.Add($none)
    } else {
        foreach ($a in $running) {
            $label = $a.label
            $sid = $a.sessionId; $pid = $a.parentSessionId; $md = $a.mode
            $item = New-Object System.Windows.Forms.ToolStripMenuItem
            $item.Text = "▶ " + $label
            $item.ToolTipText = $sid
            $dark = Resolve-MenuTheme
            $item.ForeColor = if ($dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
            $sub = New-Object System.Windows.Forms.ContextMenuStrip
            $show = New-Object System.Windows.Forms.ToolStripMenuItem
            $show.Text = $script:L.MenuAgentShowLog
            $hdl = { Show-AgentLogWindow -Title ($script:L.BalloonAgentLog + " - " + $label) -Lines (Get-AgentLogTail -ChildSessionId $sid -ParentSessionId $pid -Mode $md) }.GetNewClosure()
            $show.add_Click($hdl)
            $stop = New-Object System.Windows.Forms.ToolStripMenuItem
            $stop.Text = $script:L.MenuAgentStop
            # v1.7.1: Stop-RunningAgent is now a non-blocking kick - the RPC runs
            # on a background runspace; Complete-AgentStop shows the balloon and
            # forces the poll on the next timer tick.
            $stopHdl = {
                Stop-RunningAgent -ChildSessionId $sid -ParentSessionId $pid -Mode $md -Label $label
            }.GetNewClosure()
            $stop.add_Click($stopHdl)
            [void]$sub.Items.Add($show)
            [void]$sub.Items.Add($stop)
            Apply-FluentThemeToMenu -Menu $sub
            $item.DropDown = $sub
            [void]$menu.Items.Add($item)
        }
        foreach ($a in $waiting) {
            $label = $a.label
            $sid = $a.sessionId; $pid = $a.parentSessionId; $md = $a.mode
            $item = New-Object System.Windows.Forms.ToolStripMenuItem
            $item.Text = "⏸ " + $label + "  (" + $script:L.MenuAgentsWaiting + ")"
            $item.ToolTipText = $sid
            $dark = Resolve-MenuTheme
            $item.ForeColor = if ($dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
            $sub = New-Object System.Windows.Forms.ContextMenuStrip
            $show = New-Object System.Windows.Forms.ToolStripMenuItem
            $show.Text = $script:L.MenuAgentShowLog
            $hdl = { Show-AgentLogWindow -Title ($script:L.BalloonAgentLog + " - " + $label) -Lines (Get-AgentLogTail -ChildSessionId $sid -ParentSessionId $pid -Mode $md) }.GetNewClosure()
            $show.add_Click($hdl)
            [void]$sub.Items.Add($show)
            Apply-FluentThemeToMenu -Menu $sub
            $item.DropDown = $sub
            [void]$menu.Items.Add($item)
        }
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $refresh.Text = $script:L.MenuAgentRefresh
    $refresh.add_Click({ Invoke-AgentPoll -ForceRefresh $true })
    [void]$menu.Items.Add($refresh)

    # Dynamic submenu title reflecting the live running count.
    $row = $script:L.AgentStatusRow.Replace('N', [string]$running.Count).Replace('M', [string]$waiting.Count)
    $script:AgentMenuHost.Text = $row
    Apply-FluentThemeToMenu -Menu $menu
}

function Invoke-AgentPoll {
    param([switch]$ForceRefresh)
    if (-not $script:Config.agentmonitor -or -not $script:NotifyIcon) {
        return
    }
    if ($script:AgentPollInFlight) { return }
    # Health gate uses the cached probe result - never a blocking network call.
    $h = Get-CachedHealth
    if ($h -ne $true) {
        $script:AgentPollFailureCount++
        if ($script:AgentPollFailureCount -le 1) {
            Write-TrayLog "agent poll deferred (dsh not healthy)"
        }
        return
    }
    $script:AgentPollInFlight = $true
    $script:AgentPollForceRefresh = [bool]$ForceRefresh
    $script:AgentPollFailureCount = 0
    $script:RpcWarnCooldown = @{}      # method -> last WARN timestamp (rate-limit)
    $port = $script:Port
    $pollScript = @'
    param([int]$Port)
    $body = @{
        type    = "client-request"
        rpcId   = "tray-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
        method  = "session.list"
        payload = @{}
    } | ConvertTo-Json -Compress -Depth 12
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/session.list" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8
        if ($resp -and $resp.result -and $resp.result.ok) { return $resp.result.value }
    } catch { }
    return $null
'@
    $jobId = Start-AsyncJob -Id "agentpoll" -Script $pollScript -Arguments @($port)
    if ($null -eq $jobId) {
        $script:AgentPollInFlight = $false
    }
}

function Complete-AgentPoll {
    # UI-thread completion of the background session.list RPC: parse the report,
    # diff agent transitions, notify, update the badge and the agents menu.
    param([object[]]$Output)
    $value = $null
    if ($Output.Count -gt 0) { $value = $Output[0] }
    $report = @(Convert-AgentReport -Value $value)
    $ForceRefresh = $script:AgentPollForceRefresh
    $script:AgentPollForceRefresh = $false

    if (-not $script:AgentMonitorLogged) {
        $script:AgentMonitorLogged = $true
        Write-TrayLog "agent monitor poll ok: $($report.Count) subagent sessions"
    }

    $runningNow = @($report | Where-Object { $_.state -eq "running" })
    $waitingNow = @($report | Where-Object { $_.state -eq "waiting" })

    # Notifications: diff transitions, but only once a baseline poll has completed.
    if ($script:AgentBaseline) {
        foreach ($a in $runningNow) {
            if (-not $script:AgentKnown.ContainsKey($a.sessionId)) {
                $script:AgentKnown[$a.sessionId] = "running"
                if ($script:Config.agentnotifications) {
                    Show-Balloon -Title $script:L.BalloonAgentStart -Text ($script:L.BalloonAgentStartHint -f $a.label)
                }
            }
            elseif ($script:AgentKnown[$a.sessionId] -eq "waiting") {
                $script:AgentKnown[$a.sessionId] = "running"
            }
        }
        foreach ($a in $waitingNow) {
            if (-not $script:AgentKnown.ContainsKey($a.sessionId)) {
                $script:AgentKnown[$a.sessionId] = "waiting"
            }
            elseif ($script:AgentKnown[$a.sessionId] -eq "running") {
                $script:AgentKnown[$a.sessionId] = "waiting"
                if ($script:Config.agentnotifications) {
                    Show-Balloon -Title $script:L.BalloonAgentWaiting -Text ($script:L.BalloonAgentWaitingHint -f $a.label)
                }
            }
        }
        # Finished = was running/waiting, now gone from the report.
        foreach ($sid in @($script:AgentKnown.Keys)) {
            $still = $null
            foreach ($a in $report) { if ($a.sessionId -eq $sid) { $still = $a; break } }
            if ($null -eq $still) {
                $prev = $script:AgentKnown[$sid]
                $script:AgentKnown.Remove($sid)
                if ($script:Config.agentnotifications -and ($prev -eq "running" -or $prev -eq "waiting")) {
                    Show-Balloon -Title $script:L.BalloonAgentFinish -Text ($script:L.BalloonAgentFinishHint -f $sid)
                }
            }
            elseif ($still.state -eq "inactive" -and $script:AgentKnown[$sid] -eq "running") {
                $script:AgentKnown[$sid] = "finished"
                if ($script:Config.agentnotifications) {
                    Show-Balloon -Title $script:L.BalloonAgentFinish -Text ($script:L.BalloonAgentFinishHint -f $still.label)
                }
            }
        }
    }

    # First successful poll (or any later rebuild) becomes the diff baseline.
    $script:AgentBaseline = $true

    # Update state + icon badge + menu.
    $script:AgentCount = @($runningNow).Count
    $script:AgentWaitingCount = @($waitingNow).Count
    Update-TrayIcon
    if ($script:AgentMenuHost) {
        $oldCount = @(if ($null -ne $script:AgentMenuHost.Tag) { $script:AgentMenuHost.Tag } else { 0 })
        $newCount = $script:AgentCount + $script:AgentWaitingCount
        if ($ForceRefresh -or $newCount -ne $oldCount -or -not $script:AgentBaseline) {
            Rebuild-AgentMenu -Report $report
            $script:AgentMenuHost.Tag = $newCount
        }
    }
    $script:AgentLastPoll = Get-Date
}

# --- dsh updates (v1.6.0) ---------------------------------------------------------
# Checks the installed @deepseek-ai/dsh version against the latest on npm and, when
# updateapply is enabled, offers a one-click `npm i -g @deepseek-ai/dsh@latest`.
# All npm/dsh invocations are non-blocking, error-tolerant, and guarded against
# re-entrancy (manual + timer must not run concurrently).

$script:UpdateRunning     = $false   # a check or apply is in flight
$script:UpdateTimer       = $null    # periodic auto-check timer
$script:UpdateInfo        = @{ Installed = $null; Latest = $null; Available = $false; LastCheck = $null }
$script:UpdateMenuItem    = $null    # host menu item (hosts the two update items)
$script:UpdateCheckItem   = $null    # "Check for updates"
$script:UpdateApplyItem   = $null    # "Update to vN" (enabled only when an update is available)

$script:NpmCmdPath = $null

function Get-NpmCmdPath {
    # Resolve the real npm.cmd once and pin the full path. Running a bare
    # "npm.cmd" is resolved against the tray process's current directory first,
    # which can pick up a stray local npm shim and fail with "Cannot find module
    # ...\node_modules\npm\bin\npm-cli.js". An absolute path + a neutral working
    # directory makes every npm call hermetic regardless of the tray CWD.
    if ($null -eq $script:NpmCmdPath) {
        $c = Get-Command "npm.cmd" -ErrorAction SilentlyContinue
        $script:NpmCmdPath = if ($c) { $c.Source } else { "npm.cmd" }
    }
    return $script:NpmCmdPath
}

function Invoke-NpmCommand {
    # Run a short-lived npm command with a hard timeout; return trimmed stdout.
    # Never blocks the tray: spawns a process, waits up to $TimeoutMs, and
    # disposes it if it overruns (npm hung on a network stall).
    param(
        [string]$Arguments,
        [int]$TimeoutMs = 15000
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-NpmCmdPath)
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $env:USERPROFILE
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            Write-TrayLog "WARN npm timed out: npm $Arguments"
            return $null
        }
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($err)) { Write-TrayLog "npm stderr: $($err.Trim())" }
        return $out
    }
    catch {
        Write-TrayLog "WARN npm error ($Arguments): $($_.Exception.Message)"
        return $null
    }
}

function Get-InstalledDshVersion {
    # The installed global dsh version, parsed from `dsh --version`.
    $out = Invoke-NpmCommand -Arguments "root -g" -TimeoutMs 10000
    # `npm root -g` gives the global node_modules; find dsh package.json there.
    try {
        $root = ($out -split "`n")[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $pkg = Join-Path $root "@deepseek-ai\dsh\package.json"
            if (Test-Path -LiteralPath $pkg) {
                $pkgData = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
                if ($pkgData.version) { return [string]$pkgData.version }
            }
        }
    } catch { }
    # Fallback: dsh --version. Like Get-LatestDshVersion, keep the FULL version
    # string (core + optional -prerelease) so a "-rc.x" build is never truncated
    # to a stable-looking core (which would trigger a false update check).
    try {
        $o = & dsh --version 2>&1 | Out-String
        if ($o -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)') { return $Matches[1] }
    } catch { }
    return $null
}

function Get-LatestDshVersion {
    # Latest published @deepseek-ai/dsh from the npm registry.
    #
    # IMPORTANT: must keep the FULL semver string, including any prerelease tag.
    # dsh publishes under prerelease dist-tags (e.g. "latest" = 0.1.0-rc.7), so a
    # naive `\d+\.\d+\.\d+` match would strip "-rc.7" down to "0.1.0" and make the
    # tray report a stable release that was never published -> a false "update
    # available" balloon. We parse the whole token and hand it to
    # Test-DshUpdateAvailable untouched.
    $out = Invoke-NpmCommand -Arguments "view @deepseek-ai/dsh version" -TimeoutMs 15000
    if ($null -eq $out) { return $null }
    $line = ($out -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    $v = $line.Trim()
    # npm may print "<pkg>@<version>" on some invocations; drop the package prefix.
    if ($v -match '^.*@([0-9][0-9A-Za-z.\-]*)$') { $v = $Matches[1] }
    # Validate it really is a semver (core + optional -prerelease), then return it whole.
    if ($v -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?$') { return $v }
    return $null
}

function Test-DshUpdateAvailable {
    # true only when both versions are known and latest > installed. Robust to
    # npm prerelease tags like "0.1.0-rc.7": compare the numeric core first, then
    # fall back to a lexical prerelease comparison when the core is equal
    # (a stable build with the same core is newer than any -rc/-beta of it).
    param([string]$Installed, [string]$Latest)
    if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Latest)) { return $false }
    try {
        $Parse = {
            param([string]$v)
            $v = $v.Trim().TrimStart('v')
            if ($v -match '^(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.\-]+))?') {
                $core = [version]$Matches[1]
                $pre = $Matches[2]
                return @{ Core = $core; Pre = $pre }
            }
            return $null
        }
        $iv = & $Parse $Installed
        $lv = & $Parse $Latest
        if ($null -eq $iv -or $null -eq $lv) { return $false }
        if ($lv.Core -gt $iv.Core) { return $true }
        if ($lv.Core -lt $iv.Core) { return $false }
        # Same numeric core -> compare prerelease: a release (no prerelease) is
        # newer than any prerelease of the same version; otherwise lexical.
        $ip = if ($iv.Pre) { $iv.Pre } else { "" }
        $lp = if ($lv.Pre) { $lv.Pre } else { "" }
        if ([string]::IsNullOrEmpty($lp)) { return (-not [string]::IsNullOrEmpty($ip)) }
        if ([string]::IsNullOrEmpty($ip)) { return $false }
        return ([string]::Compare($lp, $ip, [System.StringComparison]::OrdinalIgnoreCase) -gt 0)
    } catch { return $false }
}

function New-UpdateCheckScript {
    # Compose the hermetic runspace script for the version query: the helper
    # functions are serialised by source, so the background runspace runs the
    # exact same code paths as the sync path without sharing script state.
    if ($script:UpdateCheckScript) { return $script:UpdateCheckScript }
    $defs = New-Object System.Collections.Generic.List[string]
    foreach ($fn in @("Write-TrayLog", "Get-NpmCmdPath", "Invoke-NpmCommand", "Get-InstalledDshVersion", "Get-LatestDshVersion")) {
        try {
            $c = Get-Command $fn -ErrorAction Stop
            # Wrap in the function keyword: Get-Command .Definition is just the
            # body, and a bare concatenated body with its own param() block would
            # be parsed as top-level script code (the update check would then
            # silently return nothing).
            $defs.Add("function $fn { $($c.Definition) }")
        } catch { }
    }
    $defs.Add("`$script:TrayLog = '$($script:TrayLog)'")
    $defs.Add("`$script:LogDir = '$($script:LogDir)'")
    $defs.Add("`$script:LogRotationBytes = $($script:LogRotationBytes)")
    $defs.Add("`$script:NpmCmdPath = `$null")
    $defs.Add("`$result = @{ Installed = (Get-InstalledDshVersion); Latest = (Get-LatestDshVersion) }")
    $defs.Add("return `$result")
    $script:UpdateCheckScript = ($defs -join "`n")
    return $script:UpdateCheckScript
}

function Invoke-DshUpdateCheck {
    # Kick one update check in a background runspace; the version queries (npm)
    # never block the UI thread. The result is applied by Complete-UpdateCheck.
    param([bool]$Manual = $false)
    if ($script:UpdateRunning) { return }
    $script:UpdateRunning = $true
    $script:UpdateManual = $Manual
    try {
        if ($Manual) { Show-Balloon -Title $script:L.BalloonUpdateChecking -Text "npm registry" }
        $jobId = Start-AsyncJob -Id "updatecheck" -Script (New-UpdateCheckScript)
        if ($null -eq $jobId) {
            $script:UpdateRunning = $false
            if ($Manual) {
                Show-Balloon -Title $script:L.BalloonUpdateFailed -Text "npm check could not start" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            }
        }
    }
    catch {
        $script:UpdateRunning = $false
        Write-TrayLog "ERROR update check kick: $($_.Exception.Message)"
    }
}

function Complete-UpdateCheck {
    # UI-thread completion of the background version query.
    param([object[]]$Output)
    $installed = $null
    $latest = $null
    if ($Output.Count -gt 0) {
        try {
            $o = $Output[0]
            $installed = $o.Installed
            $latest = $o.Latest
        } catch { }
    }
    if ($null -eq $installed) { Write-TrayLog "WARN update: could not resolve installed dsh version" }
    if ($null -eq $latest)    { Write-TrayLog "WARN update: could not resolve latest dsh version (npm unreachable?)" }

    $script:UpdateInfo.Installed = $installed
    $script:UpdateInfo.Latest    = $latest
    $script:UpdateInfo.LastCheck = Get-Date
    $script:UpdateInfo.Available = (Test-DshUpdateAvailable -Installed $installed -Latest $latest)

    if ($script:UpdateInfo.Available) {
        Write-TrayLog "Update available: $installed -> $latest"
        $title = $script:L.BalloonUpdateAvailable.Replace('{0}', "$installed").Replace('{1}', "$latest")
        Show-Balloon -Title $title -Text $script:L.BalloonUpdateAvailableHint
    }
    elseif ($script:UpdateManual) {
        Show-Balloon -Title $script:L.BalloonUpToDate -Text "v$installed"
    }
    elseif ($null -eq $latest) {
        # silent auto-check failure: log only, don't nag
        Write-TrayLog "update auto-check found no reachable npm registry"
    }

    # Refresh the "Update to vN" menu item state.
    if ($script:UpdateApplyItem) {
        try {
            $applyEnabled = ($script:UpdateInfo.Available) -and ([bool]$script:Config.updateapply) -and (-not $script:UpdateRunning)
            $script:UpdateApplyItem.Enabled = $applyEnabled
            if ($script:UpdateInfo.Latest -and $script:UpdateInfo.Available) {
                $script:UpdateApplyItem.Text = $script:L.MenuUpdateNow.Replace('{0}', "$($script:UpdateInfo.Latest)")
            }
        } catch { }
    }
    $script:UpdateManual = $false
    $script:UpdateRunning = $false
}

function Invoke-DshUpdate {
    # One-click update: `npm i -g @deepseek-ai/dsh@latest` is started as a
    # detached, hidden process that the UI polls (Invoke-UpdateProcessSweep) -
    # the install can take a minute and must never freeze the tray.
    if ($script:UpdateRunning) { return }
    if (-not ([bool]$script:Config.updateapply)) { return }
    $script:UpdateRunning = $true
    try {
        if ($script:UpdateApplyItem) { $script:UpdateApplyItem.Enabled = $false }
        if ($script:UpdateCheckItem) { $script:UpdateCheckItem.Enabled = $false }
        Show-Balloon -Title $script:L.BalloonUpdating -Text "npm install -g @deepseek-ai/dsh@latest"

        $logPath = Join-Path $script:LogDir "dsh-update.log"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-NpmCmdPath)
        $psi.Arguments = "install -g @deepseek-ai/dsh@latest"
        $psi.WorkingDirectory = $env:USERPROFILE
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $script:UpdateProcess = @{ Process = $p; LogPath = $logPath; Started = Get-Date }
        Write-TrayLog "dsh update: npm install started in background (pid=$($p.Id))"
    }
    catch {
        $script:UpdateRunning = $false
        Show-Balloon -Title $script:L.BalloonUpdateFailed -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        Write-TrayLog "ERROR dsh update: $($_.Exception.Message)"
    }
}

function Invoke-UpdateProcessSweep {
    # UI-thread poll of the in-flight npm install process. Runs from the 1s
    # timer tick; reads stdout/stderr only after the process has exited (which
    # avoids the classic ReadToEnd/WaitForExit pipe deadlock).
    $up = $script:UpdateProcess
    if (-not $up) { return }
    try {
        if (-not $up.Process.HasExited) { return }
        $out = $up.Process.StandardOutput.ReadToEnd()
        $err = $up.Process.StandardError.ReadToEnd()
        Add-Content -LiteralPath $up.LogPath -Value "exit=$($up.Process.ExitCode)`n$out`n$err" -Encoding UTF8
        $ok = ($up.Process.ExitCode -eq 0)
        try { $up.Process.Dispose() } catch { }
        $script:UpdateProcess = $null

        if ($ok) {
            # Force-refresh the checked version and restart the server on the new build.
            $script:UpdateInfo.Available = $false
            if ($script:UpdateApplyItem) { $script:UpdateApplyItem.Enabled = $false }
            $newVer = Get-InstalledDshVersion
            Show-Balloon -Title $script:L.BalloonUpdateApplied -Text ("v" + $newVer)
            Write-TrayLog "dsh updated successfully to $newVer; restarting"
            Restart-DshProxy
        }
        else {
            Show-Balloon -Title $script:L.BalloonUpdateFailed -Text ("exit " + $up.Process.ExitCode) -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            Write-TrayLog "ERROR dsh update failed: exit $($up.Process.ExitCode)"
        }
    }
    catch {
        Write-TrayLog "ERROR dsh update sweep: $($_.Exception.Message)"
        try { $script:UpdateProcess = $null } catch { }
    }
    $script:UpdateRunning = $false
    # Re-enable the "check" item; the "apply" item re-enables only if an update is still available.
    if ($script:UpdateCheckItem) { $script:UpdateCheckItem.Enabled = $true }
    if ($script:UpdateApplyItem) {
        try { $script:UpdateApplyItem.Enabled = ($script:UpdateInfo.Available) -and ([bool]$script:Config.updateapply) } catch { }
    }
}

# --- tray actions --------------------------------------------------------------
function Invoke-MouseClick {
    param([int]$X, [int]$Y)
    if (-not $script:MouseTypeDefined) {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DshTrayMouse{ [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e); public static void Click(int x,int y){ SetCursorPos(x,y); System.Threading.Thread.Sleep(100); mouse_event(0x0002,0,0,0,UIntPtr.Zero); mouse_event(0x0004,0,0,0,UIntPtr.Zero);} }' -ErrorAction SilentlyContinue
        $script:MouseTypeDefined = $true
    }
    [DshTrayMouse]::Click($X, $Y)
    return $true
}

function Invoke-UiaElementActivate {
    # Activate a UI element: semantic patterns first (no cursor movement),
    # a real mouse click at the element center only as a last resort.
    param($Element)
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke()
        return $true
    }
    catch {
    }
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $p.Select()
        return $true
    }
    catch {
    }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -gt 0 -and $r.Height -gt 0) {
        return (Invoke-MouseClick -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2)))
    }
    return $false
}

function Invoke-GuiNewConversation {
    # Drive the harness GUI's own "new conversation" flow through UI Automation.
    # The GUI owns session creation, view switching and its localStorage
    # persistence - no RPC hacks needed.
    #
    # Deterministic logic (the GUI button alone proved flaky):
    #   1. An untitled entry already selected  -> GUI is on a fresh conversation
    #   2. An untitled entry exists            -> select it
    #   3. None exists -> click "New conversation", wait for the new entry,
    #      then select it (InvokePattern first; real click after focusing the
    #      window as a fallback).
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $win = $null
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($w.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $w.Current.Name -match 'DeepSeek Harness') {
            $win = $w
            break
        }
    }
    if (-not $win) {
        return $false
    }

    $itemCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TreeItem)
    function Get-UntitledItems {
        $found = @()
        foreach ($t in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond)) {
            if ($t.Current.Name -match '新会话|^New (session|conversation)') {
                $found += $t
            }
        }
        return $found
    }

    $untitled = @(Get-UntitledItems)

    # Case 1 + 2: reuse an existing empty conversation if possible.
    foreach ($t in $untitled) {
        try {
            $p = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($p.Current.IsSelected) {
                try { $win.SetFocus() } catch { }
                return $true
            }
        }
        catch {
        }
    }
    if ($untitled.Count -gt 0) {
        if (Invoke-UiaElementActivate $untitled[0]) {
            try { $win.SetFocus() } catch { }
            return $true
        }
    }

    # Case 3: create a new empty conversation via the GUI button.
    $btnCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
        (New-Object System.Windows.Automation.OrCondition(
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '新建会话')),
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'New conversation')))))
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    if (-not $btn) {
        return $false
    }

    $beforeCount = $untitled.Count
    $clicked = Invoke-UiaElementActivate $btn
    if (-not $clicked) {
        return $false
    }

    $item = $null
    for ($attempt = 0; $attempt -lt 2 -and -not $item; $attempt++) {
        for ($i = 0; $i -lt 10 -and -not $item; $i++) {
            Start-Sleep -Milliseconds 400
            $now = @(Get-UntitledItems)
            if ($now.Count -gt $beforeCount) {
                $item = $now[$now.Count - 1]
            }
        }
        if (-not $item -and $attempt -eq 0) {
            # InvokePattern sometimes does not register; retry with a real click
            # after focusing the window so coordinates are safe.
            try { $win.SetFocus() } catch { }
            $r = $btn.Current.BoundingRectangle
            if ($r.Width -gt 0 -and $r.Height -gt 0) {
                [void](Invoke-MouseClick -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2)))
            }
        }
    }
    if (-not $item) {
        return $false
    }
    if (Invoke-UiaElementActivate $item) {
        try { $win.SetFocus() } catch { }
        return $true
    }
    return $false
}

function Get-ChromeAppTarget {
    # Resolve the target of a .lnk so a stale/broken shortcut (missing
    # chrome_proxy.exe, deleted Chrome profile) can be detected before
    # Start-Process silently no-ops. Returns @{ Target; Exists } or $null.
    param([string]$LnkPath)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($LnkPath)
        if ($sc -and $sc.TargetPath) {
            return @{
                Target = [string]$sc.TargetPath
                Exists = (Test-Path -LiteralPath ([string]$sc.TargetPath))
            }
        }
    }
    catch { }
    return $null
}

function Start-DshApp {
    # Open the DeepSeek Harness UI. Preferred: the installed Chrome App (PWA)
    # as a standalone window, via the user's "Chrome Apps\DeepSeek Harness.lnk"
    # (config: chromeapplnk). Fallback: a regular browser tab.
    #   -Path  optional URL fragment to append when opening a tab (ignored for
    #          the Chrome App, which opens/activates its own registered window).
    # If the shortcut is missing, its target is gone, or Start-Process fails,
    # the fallback must always succeed without throwing (this function runs in
    # UI click handlers, including the toast form).
    param([string]$Path = "")

    $lnk = $null
    try {
        if ($script:Config -and $script:Config.chromeapplnk) { $lnk = [string]$script:Config.chromeapplnk }
    } catch { }
    if ($lnk) {
        try { $lnk = Resolve-TrayPath $lnk } catch { }
    }

    $useChromeApp = $false
    if (-not $lnk) {
        if (-not $script:ChromeAppLnkWarned) {
            $script:ChromeAppLnkWarned = $true
            Write-TrayLog "WARN chromeapplnk not set in dsh-tray.json; PWA mode unavailable, falling back to a browser tab"
        }
    }
    elseif (-not (Test-Path -LiteralPath $lnk)) {
        if (-not $script:ChromeAppLnkWarned) {
            $script:ChromeAppLnkWarned = $true
            Write-TrayLog "WARN chromeapplnk file not found: $lnk; PWA mode unavailable, falling back to a browser tab"
        }
    }
    else {
        $targetInfo = Get-ChromeAppTarget -LnkPath $lnk
        if ($null -eq $targetInfo -or -not $targetInfo.Exists) {
            if (-not $script:ChromeAppLnkWarned) {
                $script:ChromeAppLnkWarned = $true
                $t = if ($targetInfo) { $targetInfo.Target } else { "<unresolved>" }
                Write-TrayLog "WARN chromeapplnk target unavailable ($t); PWA mode unavailable, falling back to a browser tab"
            }
        }
        else {
            $useChromeApp = $true
        }
    }

    if ($useChromeApp) {
        try {
            # Start-Process on a .lnk launches its target (chrome_proxy.exe
            # --profile-directory=... --app-id=...) which opens/activates the
            # PWA window instead of a new tab.
            Start-Process -FilePath $lnk
            Write-TrayLog "Opened DeepSeek Harness via Chrome app: $lnk"
            return
        }
        catch {
            if (-not $script:ChromeAppLnkWarned) {
                $script:ChromeAppLnkWarned = $true
                Write-TrayLog "WARN chrome app shortcut failed ($lnk): $($_.Exception.Message); falling back to a browser tab"
            }
        }
    }

    # Fallback: plain browser tab.
    $url = $script:DashboardUrl
    if ($Path) { $url = $url.TrimEnd("/") + $Path }
    try {
        Start-Process $url
        Write-TrayLog "Opened DeepSeek Harness via browser tab: $url"
    }
    catch {
        Write-TrayLog "WARN failed to open browser tab ($url): $($_.Exception.Message)"
    }
}

function New-NewConversationScript {
    # v1.7.1: compose the hermetic runspace script for the "new conversation"
    # action. The GUI automation functions are serialised by source (wrapped in
    # their function keyword so the runspace re-defines them exactly as the main
    # script does) and the port + cached-health decision are baked in, so the
    # background thread never touches UI state and never blocks the click.
    param([int]$Port, [bool]$HealthyCached)
    if (-not $script:NewConversationScriptDefs) {
        $defs = New-Object System.Collections.Generic.List[string]
        foreach ($fn in @("Invoke-GuiNewConversation", "Invoke-UiaElementActivate", "Invoke-MouseClick")) {
            try {
                $c = Get-Command $fn -ErrorAction Stop
                $defs.Add("function $fn { $($c.Definition) }")
            } catch { }
        }
        $script:NewConversationScriptDefs = ($defs -join "`n")
    }
    $healthyText = if ($HealthyCached) { '$true' } else { '$false' }
    $body = @"
`$script:Port = $Port
`$script:MouseTypeDefined = `$false
`$script:NewConvHealthyCached = $healthyText

`$gui = Invoke-GuiNewConversation
if (`$gui) {
    return @{ Ok = `$true; Mode = "gui" }
}
if (-not `$script:NewConvHealthyCached) {
    return @{ Ok = `$false; Mode = "dashboard"; Error = "dsh not healthy; RPC fallback skipped" }
}

`$workspaceId = `$null
`$wsBody = @{
    type = "client-request"
    rpcId = "tray-ws-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
    method = "workspace.list"
    payload = @{}
} | ConvertTo-Json -Compress
try {
    `$wsResp = Invoke-RestMethod -Uri "http://127.0.0.1:`$script:Port/api/workspace.list" -Method Post -ContentType "application/json" -Body `$wsBody -TimeoutSec 10
    if (`$wsResp.result.ok -and `$wsResp.result.value.items -and `$wsResp.result.value.items.Count -gt 0) {
        `$workspaceId = [string]`$wsResp.result.value.items[0].workspaceId
    }
} catch { }

`$payload = @{}
if (`$workspaceId) { `$payload.workspaceId = `$workspaceId }
`$rpcId = "tray-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
`$body = @{
    type = "client-request"
    rpcId = `$rpcId
    method = "session.create"
    payload = `$payload
} | ConvertTo-Json -Compress
try {
    `$resp = Invoke-RestMethod -Uri "http://127.0.0.1:`$script:Port/api/session.create" -Method Post -ContentType "application/json" -Body `$body -TimeoutSec 10
    if (`$resp.result.ok) {
        `$fragment = "#tray-new-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
        return @{ Ok = `$true; Mode = "rpc"; Fragment = `$fragment; SessionId = [string]`$resp.result.value.sessionId }
    }
    return @{ Ok = `$false; Mode = "error"; Error = "session.create rejected" }
} catch {
    return @{ Ok = `$false; Mode = "error"; Error = `$_.Exception.Message }
}
"@
    return ($script:NewConversationScriptDefs + "`n" + $body)
}

function Start-NewConversation {
    # v1.7.1: non-blocking kick. The slow work (UI Automation up to ~8s of
    # polling sleeps + the RPC fallback with its 10s timeout) runs on a
    # background STA runspace via the shared Start-AsyncJob infrastructure.
    # The click handler returns immediately; the result (balloon / opening the
    # dashboard) is applied by Complete-NewConversation on the next timer tick.
    if ($script:AsyncJobs.ContainsKey("newconv")) { return }
    $healthyCached = (Get-CachedHealth) -eq $true
    if ($script:NewChatMenuItem) {
        $script:NewChatMenuItem.Enabled = $false
        $script:NewChatMenuItem.Text = $script:L.MenuNewChat + " ..."
    }
    $jobId = Start-AsyncJob -Id "newconv" -Script (New-NewConversationScript -Port $script:Port -HealthyCached $healthyCached) -Apartment STA
    if ($null -eq $jobId) {
        if ($script:NewChatMenuItem) {
            $script:NewChatMenuItem.Enabled = $true
            $script:NewChatMenuItem.Text = $script:L.MenuNewChat
        }
        Show-Balloon -Title $script:L.BalloonError -Text "new conversation could not start" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Complete-NewConversation {
    # v1.7.1: UI-thread completion of the background new-conversation job.
    # Mirrors the old synchronous Start-NewConversation behaviour exactly: GUI
    # success -> "new conversation ready"; RPC success -> open the app on a
    # unique fragment + toast; dsh not healthy -> open the dashboard; RPC
    # failure -> error toast + open the dashboard.
    param([object[]]$Output)
    $result = $null
    if ($Output.Count -gt 0) { $result = $Output[0] }
    $mode = "error"; $fragment = ""; $errorText = ""
    if ($result) {
        try {
            $mode = [string]$result.Mode
            $fragment = [string]$result.Fragment
            $errorText = [string]$result.Error
        } catch { }
    }
    if ($script:NewChatMenuItem) {
        $script:NewChatMenuItem.Enabled = $true
        $script:NewChatMenuItem.Text = $script:L.MenuNewChat
    }
    switch ($mode) {
        "gui" {
            Write-TrayLog "New conversation opened via GUI"
            Show-Balloon -Title $script:L.BalloonNewChat -Text $script:L.BalloonNewChatHint
        }
        "rpc" {
            Write-TrayLog "New conversation created via RPC (fragment=$fragment)"
            Start-DshApp -Path $fragment
            Show-Balloon -Title $script:L.BalloonNewChat -Text $script:L.BalloonNewChatHint
        }
        "dashboard" {
            Write-TrayLog "WARN new conversation: GUI unavailable and dsh not healthy; opening dashboard"
            Start-DshApp
        }
        default {
            Write-TrayLog "WARN new conversation failed: $errorText"
            $msg = if ($errorText) { $errorText } else { "new conversation failed" }
            Show-Balloon -Title $script:L.BalloonError -Text $msg -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            Start-DshApp
        }
    }
}

function Copy-RecentLog {
    # Copy the tail of the dsh web log (fall back to the tray log) to the clipboard.
    $source = $script:DshLogFile
    if (-not (Test-Path -LiteralPath $source)) {
        $source = $script:TrayLog
    }
    if (-not (Test-Path -LiteralPath $source)) {
        Show-Balloon -Title $script:L.BalloonError -Text "no log file found" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    try {
        $tail = Get-Content -LiteralPath $source -Tail 25
        $text = "=== $source ===" + [Environment]::NewLine + ($tail -join [Environment]::NewLine)
        Set-Clipboard -Value $text
        Write-TrayLog "Copied $($tail.Count) log lines from $source to clipboard"
        Show-Balloon -Title $script:L.BalloonCopied -Text "$($tail.Count) lines"
    }
    catch {
        Write-TrayLog "WARN copy log failed: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Test-Autostart {
    return (Test-Path -LiteralPath $script:LnkPath)
}

function Set-Autostart {
    param([bool]$Enable)

    $launchVbs = Join-Path $script:TrayRoot "dsh-tray-launch.vbs"
    if ($Enable -and -not (Test-Path -LiteralPath $launchVbs)) {
        Write-TrayLog "WARN missing launcher: $launchVbs"
        Show-Balloon -Title $script:L.BalloonError -Text "dsh-tray-launch.vbs missing" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    try {
        $ws = New-Object -ComObject WScript.Shell
        if ($Enable) {
            $lnk = $ws.CreateShortcut($script:LnkPath)
            $lnk.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
            $lnk.Arguments = "//nologo `"$launchVbs`""
            $lnk.WorkingDirectory = $script:TrayRoot
            $lnk.Description = "DeepSeek Harness (dsh) web tray controller"
            $lnk.Save()
            Write-TrayLog "Autostart enabled: $($script:LnkPath)"
        }
        else {
            if (Test-Path -LiteralPath $script:LnkPath) {
                Remove-Item -LiteralPath $script:LnkPath -Force
                Write-TrayLog "Autostart disabled: $($script:LnkPath)"
            }
        }
    }
    catch {
        Write-TrayLog "WARN autostart toggle failed: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# --- startup -------------------------------------------------------------------
$script:Config = Read-Config
$script:Port = [int]$script:Config.port
$script:HealthUrl = [string]$script:Config.healthurl
$script:DashboardUrl = [string]$script:Config.dashboardurl
# Resolve paths stored in dsh-tray.json. Absolute paths are kept as-is (legacy);
# relative paths are resolved against the tray folder so the whole thing is
# portable and survives being moved (e.g. E:\Code\TypeScript\dsh-tray).
function Resolve-TrayPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $script:TrayRoot $Path))
}
$script:StartScript = Resolve-TrayPath ([string]$script:Config.startscript)
$script:DshLogFile = Resolve-TrayPath ([string]$script:Config.dshlogfile)
$script:HealthIntervalSeconds = [int]$script:Config.healthintervalseconds
$script:StartupGraceSeconds = [int]$script:Config.startupgraceseconds
$script:RestartDelaySeconds = [int]$script:Config.restartdelayseconds
Init-I18n

# Compile the P/Invoke + fluent color table types used by the modern UI/toasts.
Initialize-UiHelpers

$startupDir = [Environment]::GetFolderPath("Startup")
$script:LnkPath = Join-Path $startupDir "dsh-tray.lnk"

# TEST MODE (Pester): when DSH_TRAY_TEST_MODE=1 this file is dot-sourced by the
# test suite. Everything above (functions, state, config, i18n) is loaded, but
# the WinForms tray / mutex / message loop are skipped so the process never opens
# a GUI or claims the single-instance mutex during tests.
if ($env:DSH_TRAY_TEST_MODE) {
    return
}

$createdNew = $false
$mutexName = "Local\DshTray-$($script:Port)"
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    Write-TrayLog "Tray application starting (Windows-native dsh) port=$($script:Port) v$($script:Version) lang=$($script:Lang)"
    Write-TrayLog "boot manifest: pid=$PID ps=$($PSVersionTable.PSVersion) os=$([Environment]::OSVersion.VersionString) tray=$($script:TrayRoot) startscript=$($script:StartScript) dshlog=$($script:DshLogFile) healthurl=$($script:HealthUrl) mutex=$mutexName"
    Write-TrayLog "config: port=$($script:Port) healthinterval=$($script:HealthIntervalSeconds)s grace=$($script:StartupGraceSeconds)s restartdelay=$($script:RestartDelaySeconds)s maxrestarts=$($script:Config.maxconsecutiverestarts) healthconfirmations=$($script:Config.healthconfirmations) healthdebounce=$($script:Config.healthdebounceseconds)s lang=$($script:Lang) notifications=$($script:Config.notifications) whaleicon=$($script:Config.whaleicon) agentmonitor=$($script:Config.agentmonitor) agentpoll=$($script:Config.agentpollseconds)s badgeicon=$($script:Config.badgeicon) updatecheck=$($script:Config.updatecheck) updateintervalh=$($script:Config.updateintervalhours) toastson=$($script:Config.toastson) menubicons=$($script:Config.menubicons)"

    $script:Context = New-Object System.Windows.Forms.ApplicationContext
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon

    # Load the DeepSeek whale icon (PNG -> HICON via GDI+); fall back to the
    # generic application icon if the asset is missing or disabled.
    if ($script:Config.whaleicon) {
        $whalePath = Join-Path $script:TrayRoot "assets\dsh-whale.png"
        if (Test-Path -LiteralPath $whalePath) {
            try {
                $bmp = [System.Drawing.Bitmap]::FromFile($whalePath)
                $script:WhaleIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
                $bmp.Dispose()
            }
            catch {
                $script:WhaleIcon = $null
            }
        }
    }
    $script:NotifyIcon.Icon = if ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Application }
    $script:NotifyIcon.Text = "dsh :$($script:Port)"
    if ($script:WhaleIcon) { $script:BaseWhaleIcon = $script:WhaleIcon }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Unified smooth font for every menu item (v1.6.0).
    try { $menu.Font = (Resolve-UiFont -Size ([single]$script:Config.uifontsize)) } catch { }

    # Modern look: fluent color table + renderer following the system theme.
    $darkTheme = Resolve-MenuTheme
    $menuColorTable = New-Object DshFluentColorTable
    $menuColorTable.Dark = $darkTheme
    # Text colour: renderer alone can't set it, so we colour items explicitly.
    $itemFg = if ($darkTheme) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
    $iconFg = if ($darkTheme) { [System.Drawing.Color]::FromArgb(210, 210, 210) } else { [System.Drawing.Color]::FromArgb(80, 80, 80) }
    $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer($menuColorTable)

    # Default dashboard icon image: the DeepSeek whale (16x16), reused for the
    # welcome/status row and "Open Dashboard". MDL2 glyphs are used for the rest.
    $whale16 = $null
    try {
        $wb = Get-WhaleBitmap
        if ($wb) {
            $whale16 = New-Object System.Drawing.Bitmap(16, 16)
            $wg = [System.Drawing.Graphics]::FromImage($whale16)
            $wg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $wg.DrawImage($wb, 0, 0, 16, 16)
            $wg.Dispose(); $wb.Dispose()
        }
    } catch { }

    function Set-ItemIcon([System.Windows.Forms.ToolStripItem]$Item, [System.Drawing.Image]$Img) {
        if ($script:Config.menubicons -and $Img) { $Item.Image = $Img }
        $Item.ForeColor = $script:_ItemFg
    }
    $script:_ItemFg = $itemFg

    # Status row: welcome header with the whale + current language-neutral text.
    $script:StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:StatusItem.Text = $script:L.StatusStarting
    $script:StatusItem.Enabled = $false
    if ($whale16) { $script:StatusItem.Image = $whale16 }
    $script:StatusItem.ForeColor = if ($darkTheme) { [System.Drawing.Color]::FromArgb(200, 200, 200) } else { [System.Drawing.Color]::FromArgb(120, 120, 120) }
    [void]$menu.Items.Add($script:StatusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $dashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $dashboardItem.Text = $script:L.MenuDashboard
    $dashboardItem.add_Click({ Start-DshApp })
    if ($whale16) { $dashboardItem.Image = $whale16 }
    $dashboardItem.ForeColor = $itemFg
    [void]$menu.Items.Add($dashboardItem)

    $newChatItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $newChatItem.Text = $script:L.MenuNewChat
    $newChatItem.add_Click({ Start-NewConversation })
    Set-ItemIcon -Item $newChatItem -Img (New-GlyphImage -Code 0xE8F1 -Fore $iconFg)
    [void]$menu.Items.Add($newChatItem)
    # v1.7.1: the async new-conversation job toggles this item disabled/"..."
    # while it is in flight.
    $script:NewChatMenuItem = $newChatItem

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $restartItem.Text = $script:L.MenuRestart
    $restartItem.add_Click({ Restart-DshProxy })
    Set-ItemIcon -Item $restartItem -Img (New-GlyphImage -Code 0xE895 -Fore $iconFg)
    [void]$menu.Items.Add($restartItem)

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $stopItem.Text = $script:L.MenuStop
    $stopItem.add_Click({
        $script:AutoRestartEnabled = $false
        Stop-DshProxy -Reason "tray stop"
        Set-TrayStatus -Text $script:L.StatusStopped -State Stopped
        Show-Balloon -Title $script:L.BalloonStopped -Text "dsh :$($script:Port)"
    })
    Set-ItemIcon -Item $stopItem -Img (New-GlyphImage -Code 0xE71A -Fore $iconFg)
    [void]$menu.Items.Add($stopItem)

    # Exit: stop the server (if running) and fully close the tray app itself.
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = $script:L.MenuExit
    $exitItem.add_Click({
        $script:AutoRestartEnabled = $false
        Stop-DshProxy -Reason "tray exit"
        try { if ($script:AgentTimer) { $script:AgentTimer.Stop() } } catch { }
        try { if ($script:UpdateTimer) { $script:UpdateTimer.Stop() } } catch { }
        try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
        if ($script:NotifyIcon) {
            try { $script:NotifyIcon.Visible = $false } catch { }
        }
        Write-TrayLog "Tray exiting on user request (uptime=$([int]((Get-Date) - $script:TrayStartedAt).TotalSeconds)s restarts=$($script:RestartCount) healthFailures=$($script:HealthFailures) agentsSeen=$($script:AgentCount))"
        [System.Windows.Forms.Application]::Exit()
    })
    Set-ItemIcon -Item $exitItem -Img (New-GlyphImage -Code 0xE711 -Fore ([System.Drawing.Color]::FromArgb(212, 60, 60)))
    [void]$menu.Items.Add($exitItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $copyLogItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $copyLogItem.Text = $script:L.MenuCopyLog
    $copyLogItem.add_Click({ Copy-RecentLog })
    Set-ItemIcon -Item $copyLogItem -Img (New-GlyphImage -Code 0xE8C8 -Fore $iconFg)
    [void]$menu.Items.Add($copyLogItem)

    $autoItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $autoItem.Text = $script:L.MenuAutostart
    $autoItem.CheckOnClick = $true
    $script:SuppressAutostartEvents = $true
    $autoItem.Checked = (Test-Autostart)
    $script:SuppressAutostartEvents = $false
    $autoItem.add_CheckedChanged({
        if (-not $script:SuppressAutostartEvents) {
            Set-Autostart -Enable $autoItem.Checked
        }
    })
    Set-ItemIcon -Item $autoItem -Img (New-GlyphImage -Code 0xE7E8 -Fore $iconFg)
    [void]$menu.Items.Add($autoItem)

    # Update section (v1.6.0): check + one-click apply for @deepseek-ai/dsh.
    if ($script:Config.updatecheck) {
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $script:UpdateCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $script:UpdateCheckItem.Text = $script:L.MenuCheckUpdates
        $script:UpdateCheckItem.add_Click({ Invoke-DshUpdateCheck -Manual $true })
        Set-ItemIcon -Item $script:UpdateCheckItem -Img (New-GlyphImage -Code 0xE8E0 -Fore $iconFg)
        [void]$menu.Items.Add($script:UpdateCheckItem)

        $script:UpdateApplyItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $script:UpdateApplyItem.Text = $script:L.MenuUpdateNow.Replace('{0}', "?")
        $script:UpdateApplyItem.Enabled = $false
        $script:UpdateApplyItem.add_Click({ Invoke-DshUpdate })
        Set-ItemIcon -Item $script:UpdateApplyItem -Img (New-GlyphImage -Code 0xE895 -Fore $iconFg)
        [void]$menu.Items.Add($script:UpdateApplyItem)
    }

    # Agents submenu (v1.4.0): live list of running agents with log + stop.
    if ($script:Config.agentmonitor) {
        $script:AgentMenuHost = New-Object System.Windows.Forms.ToolStripMenuItem
        $script:AgentMenuHost.Text = $script:L.MenuAgents
        $script:AgentMenuHost.ForeColor = $itemFg
        Set-ItemIcon -Item $script:AgentMenuHost -Img (New-GlyphImage -Code 0xE716 -Fore $iconFg)
        $script:AgentMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $script:AgentMenuHost.DropDown = $script:AgentMenu
        [void]$menu.Items.Add($script:AgentMenuHost)
    }

    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.add_DoubleClick({ Start-DshApp })
    $script:NotifyIcon.Visible = $true

    # Boot timing: the tray icon and menu are now interactive. From here on the
    # first health probe runs asynchronously - it never delays the first render.
    $script:UiShownAt = Get-Date
    Write-TrayLog "ui-ready: tray icon visible $([int]((Get-Date) - $script:TrayStartedAt).TotalMilliseconds)ms after script start"

    # Round the menu corners (Win11 look). The ContextMenuStrip must be open
    # before its HWND exists, so we attach to the Opened event and apply the
    # DWM attribute with a tiny delay for the popup window to settle.
    $menu.add_Opened({
        try {
            $h = $menu.Handle
            $rt = New-Object System.Windows.Forms.Timer
            $rt.Interval = 80
            $rt.add_Tick({
                try {
                    $this.Stop()
                    [DshDwm]::ApplyRoundCorners($menu.Handle)
                } catch { }
            })
            $rt.Start()
        } catch { }
    })

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 1000
    $script:Timer.add_Tick({
        try { Invoke-MonitorTick } catch { Write-TrayLog "ERROR monitor tick: $($_.Exception.Message)" }
    })
    $script:Timer.Start()

    # Dedicated agent-poll timer (v1.4.0). Runs independently of the 1s watchdog.
    if ($script:Config.agentmonitor) {
        $pollMs = [Math]::Max(2, [int]$script:Config.agentpollseconds) * 1000
        $script:AgentTimer = New-Object System.Windows.Forms.Timer
        $script:AgentTimer.Interval = $pollMs
        $script:AgentTimer.add_Tick({
            try { Invoke-AgentPoll } catch { Write-TrayLog "ERROR agent poll tick: $($_.Exception.Message)" }
        })
        $script:AgentTimer.Start()
        Write-TrayLog "Agent monitor enabled: poll=$($script:Config.agentpollseconds)s notifications=$($script:Config.agentnotifications) badge=$($script:Config.badgeicon)"
    }

    # Unified update checker (v1.6.0): cadence from config. The first tick is
    # deferred a little so the tray is fully up before the npm call; the timer
    # handles the periodic auto-check. updateintervalhours=0 disables it.
    if ($script:Config.updatecheck) {
        $hours = [int]$script:Config.updateintervalhours
        if ($hours -lt 0) { $hours = 24 }
        if ($hours -gt 0) {
            $dayMs = [Math]::Max(1, $hours) * 3600000
            $script:UpdateTimer = New-Object System.Windows.Forms.Timer
            $script:UpdateTimer.Interval = $dayMs
            $script:UpdateTimer.add_Tick({
                try { Invoke-DshUpdateCheck -Manual $false } catch { Write-TrayLog "ERROR update tick: $($_.Exception.Message)" }
            })
            $script:UpdateTimer.Start()
            Write-TrayLog "Update checker enabled: every $hours h"
        }
    }

    # Boot (v1.7.0): never block the UI on the network. The first health probe
    # is kicked in the background; the watchdog makes its start/no-start decision
    # from the completed result on a later timer tick (Invoke-HealthDecision).
    # The tray icon/menu are already interactive at this point.
    Set-TrayStatus -Text $script:L.StatusStarting -State Warning
    Start-HealthProbe

    # One background update check shortly after startup (non-blocking).
    if ($script:Config.updatecheck) {
        $bootTimer = New-Object System.Windows.Forms.Timer
        $bootTimer.Interval = 15000
        $bootTimer.add_Tick({
            try {
                $this.Stop()
                Invoke-DshUpdateCheck -Manual $false
            } catch { }
        })
        $bootTimer.Start()
    }

    [System.Windows.Forms.Application]::Run($script:Context)
}
catch {
    Write-TrayLog "FATAL $($_.Exception.ToString())"
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    throw
}
finally {
    if ($createdNew) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }
    $mutex.Dispose()
}
