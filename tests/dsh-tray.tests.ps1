# dsh-tray.tests.ps1 - Pester 3.4 tests for the pure logic in dsh-tray.ps1
#
# Run:
#   Invoke-Pester .\tests\dsh-tray.tests.ps1
# With coverage:
#   Invoke-Pester .\tests\dsh-tray.tests.ps1 -CodeCoverage .\dsh-tray.ps1 -PassThru
#
# The tray script is dot-sourced in test mode (DSH_TRAY_TEST_MODE=1): config,
# i18n and all functions are loaded, but the WinForms tray / mutex / message
# loop are skipped. GUI-only code (menu, icons, toasts, chrome app driving)
# is deliberately not covered - the toast *debounce* logic and the runspace
# plumbing are covered at the unit level via Mock.

$env:DSH_TRAY_TEST_MODE = "1"
. (Join-Path $PSScriptRoot "..\dsh-tray.ps1")
$ErrorActionPreference = "Continue"

# Shared fixture: reset the debounced health state machine so tests are isolated.
function Reset-HealthState {
    $script:StableHealth = $null
    $script:StableHealthSince = [DateTime]::MinValue
    $script:HealthFlipCandidate = $null
    $script:HealthFlipCandidateSince = [DateTime]::MinValue
    $script:HealthFlipStreak = 0
    $script:StableHealthFlippedTo = $null
    $script:SawUnhealthy = $false
    $script:HealthyEver = $false
    $script:CrashNotified = $false
    $script:LastErrorBalloonAt = [DateTime]::MinValue
    $script:RestartCapHit = $false
}

Describe "Read-Config" {
    It "applies defaults when no config file exists" {
        $cfg = Read-Config -ConfigPath (Join-Path $TestDrive "nonexistent.json")
        $cfg.port | Should Be 3080
        $cfg.restartdelayseconds | Should Be 5
        $cfg.healthurl | Should Be "http://127.0.0.1:3080/"
        $cfg.dashboardurl | Should Be "http://127.0.0.1:3080/"
    }

    It "defaults the v1.7.0 health-debounce keys" {
        $cfg = Read-Config -ConfigPath (Join-Path $TestDrive "nonexistent.json")
        $cfg.healthconfirmations | Should Be 2
        $cfg.healthdebounceseconds | Should Be 20
    }

    It "loads the real dsh-tray.json next to the script" {
        $cfg = Read-Config
        $cfg.port | Should Be 3080
        $cfg.healthintervalseconds | Should Be 10
        $cfg.startupgraceseconds | Should Be 120
    }

    It "merges user overrides on top of defaults" {
        $tmp = Join-Path $TestDrive "override.json"
        @{ port = 3090; restartdelayseconds = 7 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.port | Should Be 3090
        $cfg.restartdelayseconds | Should Be 7
        $cfg.healthintervalseconds | Should Be 10
        $cfg.healthurl | Should Be "http://127.0.0.1:3090/"
    }

    It "merges the health-debounce overrides" {
        $tmp = Join-Path $TestDrive "db.json"
        @{ healthconfirmations = 3; healthdebounceseconds = 35 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.healthconfirmations | Should Be 3
        $cfg.healthdebounceseconds | Should Be 35
        $cfg.healthintervalseconds | Should Be 10
    }

    It "ignores unknown config keys" {
        $tmp = Join-Path $TestDrive "unknown.json"
        @{ boguskey = "x"; port = 3080 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.ContainsKey("boguskey") | Should Be $false
    }
}

Describe "Resolve-Language" {
    It "maps explicit language codes" {
        Resolve-Language "zh" | Should Be "zh"
        Resolve-Language "ru" | Should Be "ru"
        Resolve-Language "en" | Should Be "en"
    }

    It "auto resolves to one of the supported languages" {
        $r = Resolve-Language "auto"
        ($r -in @("zh", "ru", "en")) | Should Be $true
    }
}

Describe "Test-DshUpdateAvailable" {
    It "returns false when either version is unknown" {
        Test-DshUpdateAvailable -Installed $null -Latest "1.0.0" | Should Be $false
        Test-DshUpdateAvailable -Installed "1.0.0" -Latest $null | Should Be $false
        Test-DshUpdateAvailable -Installed "" -Latest "1.0.0" | Should Be $false
    }

    It "returns false for equal versions" {
        Test-DshUpdateAvailable -Installed "1.0.0" -Latest "1.0.0" | Should Be $false
    }

    It "detects a newer release" {
        Test-DshUpdateAvailable -Installed "1.0.0" -Latest "1.1.0" | Should Be $true
        Test-DshUpdateAvailable -Installed "0.9.0" -Latest "1.0.0" | Should Be $true
    }

    It "returns false when installed is newer" {
        Test-DshUpdateAvailable -Installed "2.0.0" -Latest "1.9.9" | Should Be $false
    }

    It "prefers a release over a prerelease of the same core" {
        Test-DshUpdateAvailable -Installed "0.1.0-rc.7" -Latest "0.1.0" | Should Be $true
        Test-DshUpdateAvailable -Installed "0.1.0" -Latest "0.1.0-rc.7" | Should Be $false
    }

    It "compares prereleases of the same core lexically" {
        Test-DshUpdateAvailable -Installed "1.0.0-rc.1" -Latest "1.0.0-rc.2" | Should Be $true
        Test-DshUpdateAvailable -Installed "1.0.0-rc.2" -Latest "1.0.0-rc.1" | Should Be $false
    }
}

Describe "Get-LatestDshVersion" {
    # Regression: dsh publishes under prerelease dist-tags (latest = 0.1.0-rc.7).
    # The parser must keep the "-rc.x" suffix, or it collapses 0.1.0-rc.7 -> 0.1.0
    # and the tray falsely reports a stable release that was never published.
    Mock Invoke-NpmCommand { return "0.1.0-rc.7`n" }

    It "keeps the prerelease suffix of the npm latest tag" {
        Get-LatestDshVersion | Should Be "0.1.0-rc.7"
    }

    It "does not report an update when installed equals the npm latest tag" {
        (Test-DshUpdateAvailable -Installed "0.1.0-rc.7" -Latest (Get-LatestDshVersion)) | Should Be $false
    }

    It "handles a scoped <pkg>@<version> form" {
        Mock Invoke-NpmCommand { return "@deepseek-ai/dsh@0.1.0-rc.8`n" }
        Get-LatestDshVersion | Should Be "0.1.0-rc.8"
    }

    It "returns null for unparseable output" {
        Mock Invoke-NpmCommand { return "arbitrary garbage" }
        Get-LatestDshVersion | Should Be $null
    }
}

Describe "Get-AgentDisplayName" {
    It "uses the subagent label" {
        $s = [pscustomobject]@{ subagent = [pscustomobject]@{ label = "MyAgent" }; sessionId = "abc" }
        Get-AgentDisplayName $s | Should Be "MyAgent"
    }

    It "falls back to a 12-char session id" {
        $s = [pscustomobject]@{ subagent = $null; sessionId = "12345678901234567890" }
        Get-AgentDisplayName $s | Should Be "123456789012"
    }

    It "falls back when the label is blank" {
        $s = [pscustomobject]@{ subagent = [pscustomobject]@{ label = "   " }; sessionId = "abc" }
        Get-AgentDisplayName $s | Should Be "abc"
    }
}

Describe "Convert-AgentReport" {
    It "parses running/waiting/inactive subagent states" {
        $value = [pscustomobject]@{
            items = @(
                [pscustomobject]@{ origin = "subagent"; running = $true; mode = "one-shot"; sessionId = "a1"; parentSessionId = "p1"; subagent = [pscustomobject]@{ label = "Agent A"; mode = "one-shot" } },
                [pscustomobject]@{ origin = "subagent"; running = $false; mode = "continuable"; sessionId = "a2"; parentSessionId = "p1"; subagent = [pscustomobject]@{ label = "Agent B"; mode = "continuable" } },
                [pscustomobject]@{ origin = "user"; running = $true; sessionId = "a3"; subagent = $null },
                [pscustomobject]@{ origin = "subagent"; running = $false; mode = "one-shot"; sessionId = "a4"; parentSessionId = "p1"; subagent = [pscustomobject]@{ label = "Agent D"; mode = "one-shot" } }
            )
        }
        $report = @(Convert-AgentReport -Value $value)
        $report.Count | Should Be 3
        ($report | Where-Object { $_.sessionId -eq "a1" }).state | Should Be "running"
        ($report | Where-Object { $_.sessionId -eq "a2" }).state | Should Be "waiting"
        ($report | Where-Object { $_.sessionId -eq "a4" }).state | Should Be "inactive"
    }

    It "returns an empty list for a null value" {
        @(Convert-AgentReport -Value $null).Count | Should Be 0
    }
}

Describe "Test-DshProcessIdentity" {
    It "accepts node with dsh in the command line" {
        Mock Get-CimInstance { [pscustomobject]@{ Name = "node.exe"; CommandLine = "node C:\dsh\bin\cli.js web --port 3080" } }
        Test-DshProcessIdentity -ProcessId 42 | Should Be $true
    }

    It "rejects a non-dsh runtime" {
        Mock Get-CimInstance { [pscustomobject]@{ Name = "notepad.exe"; CommandLine = "notepad C:\dsh.txt" } }
        Test-DshProcessIdentity -ProcessId 43 | Should Be $false
    }

    It "rejects node that does not reference dsh" {
        Mock Get-CimInstance { [pscustomobject]@{ Name = "node.exe"; CommandLine = "node server.js --port 8080" } }
        Test-DshProcessIdentity -ProcessId 44 | Should Be $false
    }

    It "rejects when no process is found" {
        Mock Get-CimInstance { $null }
        Test-DshProcessIdentity -ProcessId 45 | Should Be $false
    }
}

Describe "Find-DshProcessId" {
    It "returns the owning PID when a listener exists" {
        Mock Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 777 } }
        Find-DshProcessId | Should Be 777
    }

    It "returns null when nothing listens on the port" {
        Mock Get-NetTCPConnection { $null }
        Find-DshProcessId | Should Be $null
    }
}

Describe "Resolve-TrayPath" {
    It "keeps absolute paths unchanged" {
        Resolve-TrayPath "C:\abs\path" | Should Be "C:\abs\path"
    }

    It "resolves relative paths against the tray root" {
        Resolve-TrayPath "start-dsh.cmd" | Should Be (Join-Path $script:TrayRoot "start-dsh.cmd")
    }

    It "returns empty for blank input" {
        Resolve-TrayPath "" | Should Be ""
    }
}

Describe "Update-StableHealth (debounce / hysteresis)" {
    BeforeEach {
        Reset-HealthState
    }

    It "establishes the baseline from the first probe without a flip" {
        Update-StableHealth -Healthy $false -Now (Get-Date)
        $script:StableHealth | Should Be "Unhealthy"
        $script:StableHealthFlippedTo | Should Be $null
    }

    It "keeps a confirmed stable state unchanged" {
        $t0 = Get-Date
        Update-StableHealth -Healthy $false -Now $t0
        Update-StableHealth -Healthy $false -Now ($t0.AddSeconds(10))
        $script:StableHealth | Should Be "Unhealthy"
        $script:StableHealthFlippedTo | Should Be $null
    }

    It "does not flip on a single opposite probe" {
        $t0 = Get-Date
        Update-StableHealth -Healthy $false -Now $t0
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(10))
        $script:StableHealth | Should Be "Unhealthy"
        $script:StableHealthFlippedTo | Should Be $null
    }

    It "flips only after healthconfirmations consecutive probes" {
        $t0 = Get-Date
        Update-StableHealth -Healthy $false -Now $t0
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(10))
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(20))
        $script:StableHealth | Should Be "Healthy"
        $script:StableHealthFlippedTo | Should Be "Healthy"
    }

    It "resets the confirmation when the probe flaps back" {
        # The classic startup flap: false true false true true.
        # Only the final pair of consecutive healthy probes may flip.
        $t0 = Get-Date
        Update-StableHealth -Healthy $false -Now $t0
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(10))
        Update-StableHealth -Healthy $false -Now ($t0.AddSeconds(20))   # flap back -> reset
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(30))
        $script:StableHealth | Should Be "Unhealthy"
        $script:StableHealthFlippedTo | Should Be $null
        Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(40))
        $script:StableHealth | Should Be "Healthy"
        $script:StableHealthFlippedTo | Should Be "Healthy"
    }

    It "does not start an Unhealthy confirmation during startup grace" {
        $t0 = Get-Date
        Update-StableHealth -Healthy $true -Now $t0                 # baseline Healthy
        Update-StableHealth -Healthy $false -GraceActive $true -Now ($t0.AddSeconds(10))
        $script:StableHealth | Should Be "Healthy"
        $script:StableHealthFlippedTo | Should Be $null
        # After grace ends an unhealthy probe starts (and completes) a confirmation.
        Update-StableHealth -Healthy $false -Now ($t0.AddSeconds(20))
        Update-StableHealth -Healthy $false -Now ($t0.AddSeconds(30))
        $script:StableHealth | Should Be "Unhealthy"
        $script:StableHealthFlippedTo | Should Be "Unhealthy"
    }

    It "falls back to the time threshold when confirmations are high" {
        $saved = $script:Config.healthconfirmations
        try {
            $script:Config.healthconfirmations = 5
            $t0 = Get-Date
            Update-StableHealth -Healthy $false -Now $t0
            Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(10))    # streak 1
            # elapsed (20s) reaches healthdebounceseconds -> flip despite streak < 5
            Update-StableHealth -Healthy $true -Now ($t0.AddSeconds(30))
            $script:StableHealth | Should Be "Healthy"
            $script:StableHealthFlippedTo | Should Be "Healthy"
        } finally {
            $script:Config.healthconfirmations = $saved
        }
    }
}

Describe "Invoke-HealthDecision (watchdog)" {
    BeforeEach {
        Reset-HealthState
        $script:ManagedByTray = $true
        $script:StartedAt = (Get-Date).AddSeconds(-130)
        $script:AutoRestartEnabled = $true
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        $script:RestartCount = 0
        $script:RestartCapHit = $false
        $script:LastHealthCheck = (Get-Date).AddSeconds(-11)
        Mock Show-Balloon { }
    }

    It "stays healthy when the health probe succeeds" {
        Invoke-HealthDecision -Healthy $true
        $script:HealthFailures | Should Be 0
        ($script:RestartAfter -eq [DateTime]::MinValue) | Should Be $true
    }

    It "counts failures while the process is alive but unhealthy" {
        Mock Find-DshProcessId { 1234 }
        Invoke-HealthDecision -Healthy $false
        $script:HealthFailures | Should Be 1
        ($script:RestartAfter -eq [DateTime]::MinValue) | Should Be $true
    }

    It "schedules a backoff restart when the process is gone after grace" {
        Mock Find-DshProcessId { $null }
        Invoke-HealthDecision -Healthy $false
        $script:RestartCount | Should Be 1
        ($script:RestartAfter -ne [DateTime]::MinValue) | Should Be $true
    }

    It "schedules a restart during grace when the process vanished" {
        $script:StartedAt = Get-Date
        Mock Find-DshProcessId { $null }
        Invoke-HealthDecision -Healthy $false
        $script:RestartCount | Should Be 1
    }

    It "resets failures once the probe recovers" {
        Mock Find-DshProcessId { 1234 }
        Invoke-HealthDecision -Healthy $false
        Invoke-HealthDecision -Healthy $false
        $script:HealthFailures | Should Be 2
        Invoke-HealthDecision -Healthy $true
        $script:HealthFailures | Should Be 0
    }

    It "resets the restart counter only once the service actually becomes Healthy" {
        # v1.7.1: RestartCount is the crash-restart backoff driver and must NOT
        # be zeroed on a mere start attempt - only a confirmed Healthy probe
        # resets it (here, Invoke-HealthDecision -Healthy $true).
        $script:RestartCount = 5
        Invoke-HealthDecision -Healthy $true
        $script:RestartCount | Should Be 0
    }

    It "grows the restart backoff with the crash count up to the 6x ceiling" {
        # v1.7.1 regression: RestartCount is no longer reset in Start-DshProxy,
        # so the watchdog backoff really escalates as RestartDelaySeconds *
        # min(RestartCount, 6): 5s, 10s, ... , 30s ceiling.
        $script:RestartDelaySeconds = 5
        Mock Find-DshProcessId { $null }
        $expected = @(5, 10, 15, 20, 25, 30, 30, 30)
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $t0 = Get-Date
            Invoke-HealthDecision -Healthy $false
            $actual = ($script:RestartAfter - $t0).TotalSeconds
            ([Math]::Abs($actual - $expected[$i]) -le 1) | Should Be $true
        }
        $script:RestartCount | Should Be 8
    }
}

Describe "Invoke-HealthDecision (notification gating)" {
    BeforeEach {
        Reset-HealthState
        $script:ManagedByTray = $true
        $script:StartedAt = (Get-Date).AddSeconds(-130)
        $script:AutoRestartEnabled = $true
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        $script:RestartCount = 0
        $script:RestartCapHit = $false
        $script:LastHealthCheck = (Get-Date).AddSeconds(-11)
        Mock Find-DshProcessId { 1234 }
        $script:BalloonCalls = 0
        Mock Show-Balloon { $script:BalloonCalls++ }
    }

    It "does not toast on a single flapping unhealthy probe" {
        Invoke-HealthDecision -Healthy $true     # baseline Healthy (no toast)
        Invoke-HealthDecision -Healthy $false    # one flap - no stable flip yet
        $script:BalloonCalls | Should Be 0
    }

    It "toasts once when the unhealthy state stabilises" {
        Invoke-HealthDecision -Healthy $true
        Invoke-HealthDecision -Healthy $false
        Invoke-HealthDecision -Healthy $false    # second consecutive -> stable flip
        $script:BalloonCalls | Should Be 1
    }

    It "toasts recovered only after the healthy state stabilises again" {
        Invoke-HealthDecision -Healthy $true
        Invoke-HealthDecision -Healthy $false
        Invoke-HealthDecision -Healthy $false    # flip to Unhealthy (1 toast)
        $script:BalloonCalls | Should Be 1
        Invoke-HealthDecision -Healthy $true     # single healthy - no flip yet
        $script:BalloonCalls | Should Be 1
        Invoke-HealthDecision -Healthy $true     # second consecutive -> recovered toast
        $script:BalloonCalls | Should Be 2
    }

    It "does not toast started/recovered on the very first healthy baseline" {
        Invoke-HealthDecision -Healthy $true
        $script:BalloonCalls | Should Be 0
    }
}

Describe "Invoke-MonitorTick (async probe scheduling)" {
    BeforeEach {
        Reset-HealthState
        $script:ManagedByTray = $true
        $script:StartedAt = (Get-Date).AddSeconds(-130)
        $script:AutoRestartEnabled = $true
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        $script:RestartCount = 0
        $script:HealthProbeInFlight = $false
        $script:HealthResult = $null
        $script:HealthApplyPending = $false
        $script:AsyncJobs = @{}
    }

    Context "probe kick (slow path)" {
        It "kicks a background probe without calling the network synchronously" {
            Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
            Mock Start-AsyncJob { "healthprobe" }
            $script:LastHealthCheck = (Get-Date).AddSeconds(-11)
            Invoke-MonitorTick
            Assert-MockCalled Start-AsyncJob -Times 1 -Exactly
            Assert-MockCalled Test-DshHealth -Times 0 -Exactly
        }
    }

    Context "start proxy firing (fast path)" {
        It "fires a pending restart once it is due" {
            $script:LastHealthCheck = Get-Date
            $script:RestartAfter = (Get-Date).AddSeconds(-1)
            Mock Start-DshProxy { $true }
            Invoke-MonitorTick
            Assert-MockCalled Start-DshProxy -Times 1 -Exactly
        }
    }

    Context "start proxy not firing (fast path)" {
        It "does not fire a pending restart that is not due yet" {
            $script:LastHealthCheck = Get-Date
            $script:RestartAfter = (Get-Date).AddSeconds(60)
            Mock Start-DshProxy { $true }
            Invoke-MonitorTick
            Assert-MockCalled Start-DshProxy -Times 0 -Exactly
        }
    }

    Context "applying a completed probe" {
        It "applies the completed health result to the watchdog decision" {
            Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
            Mock Find-DshProcessId { 1234 }
            Mock Invoke-HealthDecision { $script:Decided = $Healthy }
            $script:HealthApplyPending = $true
            $script:HealthResult = @{ Healthy = $false; At = Get-Date }
            $script:LastHealthCheck = Get-Date
            Invoke-MonitorTick
            $script:Decided | Should Be $false
            Assert-MockCalled Invoke-HealthDecision -Times 1 -Exactly
        }
    }
}

Describe "Start-DshProxy (cached health, no UI-thread network)" {
    BeforeEach {
        Reset-HealthState
        $script:AutoRestartEnabled = $true
        $script:Exiting = $false
        $script:ManagedByTray = $false
        $script:RestartAfter = [DateTime]::MinValue
        $script:StartProcCalls = 0
    }

    It "uses the cached probe result instead of a blocking Test-DshHealth" {
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Get-CachedHealth { $false }
        Mock Find-DshProcessId { $null }
        Mock Start-Process { $script:StartProcCalls++; $null }
        Start-DshProxy
        Assert-MockCalled Test-DshHealth -Times 0 -Exactly
        $script:StartProcCalls | Should Be 1
    }

    It "does not spawn a duplicate when health is unknown but a listener exists" {
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Get-CachedHealth { $null }
        Mock Find-DshProcessId { 555 }
        Mock Start-Process { $script:StartProcCalls++; $null }
        Start-DshProxy
        Assert-MockCalled Test-DshHealth -Times 0 -Exactly
        $script:StartProcCalls | Should Be 0
    }

    It "marks healthy and clears the pending restart when the cache says healthy" {
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Get-CachedHealth { $true }
        Mock Start-Process { $script:StartProcCalls++; $null }
        $script:RestartAfter = (Get-Date).AddSeconds(5)
        Start-DshProxy
        ($script:RestartAfter -eq [DateTime]::MinValue) | Should Be $true
        $script:StartProcCalls | Should Be 0
    }

    It "does not reset the restart counter on a start attempt before the service is healthy" {
        # v1.7.1: Start-DshProxy must not zero RestartCount - the backoff needs
        # it to survive each failed launch and keep escalating.
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Get-CachedHealth { $false }
        Mock Find-DshProcessId { $null }
        Mock Start-Process { $script:StartProcCalls++; $null }
        $script:RestartCount = 3
        Start-DshProxy
        $script:RestartCount | Should Be 3
    }
}

Describe "Invoke-AgentPoll (async, non-blocking)" {
    BeforeEach {
        Reset-HealthState
        $script:AgentPollInFlight = $false
        $script:AgentPollForceRefresh = $false
        $script:AgentPollFailureCount = 0
        $script:NotifyIcon = [pscustomobject]@{ }   # only a truthiness probe
    }

    AfterEach {
        $script:NotifyIcon = $null
    }

    It "defers without touching the network when health is unknown" {
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Start-AsyncJob { throw "must not kick a job" }
        $script:HealthResult = $null
        Invoke-AgentPoll
        Assert-MockCalled Start-AsyncJob -Times 0 -Exactly
        Assert-MockCalled Test-DshHealth -Times 0 -Exactly
    }

    It "kicks a background session.list when health is cached healthy" {
        Mock Test-DshHealth { throw "Test-DshHealth must not run on the UI thread" }
        Mock Start-AsyncJob { param($Id, $Script, $Arguments) $script:JobId = $Id; "agentpoll" }
        $script:HealthResult = @{ Healthy = $true; At = Get-Date }
        Invoke-AgentPoll
        Assert-MockCalled Start-AsyncJob -Times 1 -Exactly
        $script:JobId | Should Be "agentpoll"
        Assert-MockCalled Test-DshHealth -Times 0 -Exactly
    }
}

Describe "Start-DshApp (Chrome App vs fallback tab)" {
    BeforeEach {
        $script:ChromeAppLnkWarned = $false
        $script:SavedChromeAppLnk = $script:Config.chromeapplnk
    }

    AfterEach {
        $script:Config.chromeapplnk = $script:SavedChromeAppLnk
        $script:ChromeAppLnkWarned = $false
    }

    It "opens the Chrome App when the shortcut exists and its target resolves" {
        $script:Config.chromeapplnk = "C:\fake\Chrome Apps\DeepSeek Harness.lnk"
        Mock Test-Path { param($LiteralPath) $true }
        Mock Get-ChromeAppTarget { @{ Target = "C:\fake\chrome_proxy.exe"; Exists = $true } }
        Mock Start-Process { param($FilePath) $script:Launched = $FilePath; return $null }
        Start-DshApp
        $script:Launched | Should Be "C:\fake\Chrome Apps\DeepSeek Harness.lnk"
        Assert-MockCalled Start-Process -Times 1 -Exactly
    }

    It "falls back to a browser tab when the shortcut file is missing" {
        $script:Config.chromeapplnk = "C:\fake\Missing.lnk"
        Mock Test-Path { param($LiteralPath) $false }
        Mock Start-Process { param($FilePath) $script:Launched = $FilePath; return $null }
        Start-DshApp
        $script:Launched | Should Be "http://127.0.0.1:3080/"
    }

    It "falls back to a browser tab when the shortcut target is gone" {
        $script:Config.chromeapplnk = "C:\fake\Stale.lnk"
        Mock Test-Path { param($LiteralPath) $true }
        Mock Get-ChromeAppTarget { @{ Target = "C:\fake\chrome_proxy.exe"; Exists = $false } }
        Mock Start-Process { param($FilePath) $script:Launched = $FilePath; return $null }
        Start-DshApp
        $script:Launched | Should Be "http://127.0.0.1:3080/"
    }

    It "falls back to a browser tab when chromeapplnk is not configured" {
        $script:Config.chromeapplnk = $null
        Mock Start-Process { param($FilePath) $script:Launched = $FilePath; return $null }
        Start-DshApp
        $script:Launched | Should Be "http://127.0.0.1:3080/"
    }

    It "falls back to a browser tab when Start-Process on the lnk throws" {
        $script:Config.chromeapplnk = "C:\fake\Broken.lnk"
        Mock Test-Path { param($LiteralPath) $true }
        Mock Get-ChromeAppTarget { @{ Target = "C:\fake\chrome_proxy.exe"; Exists = $true } }
        Mock Start-Process { param($FilePath) if ($FilePath -like "*.lnk") { throw "boom" }; $script:Launched = $FilePath }
        Start-DshApp
        $script:Launched | Should Be "http://127.0.0.1:3080/"
    }

    It "honours the Path fragment on the fallback tab" {
        $script:Config.chromeapplnk = $null
        Mock Start-Process { param($FilePath) $script:Launched = $FilePath; return $null }
        Start-DshApp -Path "#tray-new-abc123"
        $script:Launched | Should Be "http://127.0.0.1:3080#tray-new-abc123"
    }
}

Describe "Invoke-HealthDecision (restart cap, v1.7.1)" {
    BeforeEach {
        Reset-HealthState
        $script:ManagedByTray = $true
        $script:StartedAt = (Get-Date).AddSeconds(-130)
        $script:AutoRestartEnabled = $true
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        $script:RestartCount = 0
        $script:RestartCapHit = $false
        $script:RestartDelaySeconds = 5
        $script:LastHealthCheck = (Get-Date).AddSeconds(-11)
        Mock Show-Balloon { }
    }

    It "stops auto-restarting once maxconsecutiverestarts is exceeded" {
        $cap = [int]$script:Config.maxconsecutiverestarts
        $script:RestartCount = $cap
        Mock Find-DshProcessId { $null }
        Invoke-HealthDecision -Healthy $false
        $script:RestartCount | Should Be $cap          # not incremented past the cap
        $script:AutoRestartEnabled | Should Be $false  # auto-restart stopped
        $script:RestartCapHit | Should Be $true
        ($script:RestartAfter -eq [DateTime]::MinValue) | Should Be $true  # nothing armed
    }

    It "does not hammer the process after the cap is hit" {
        # Once the cap stopped auto-restart, Start-DshProxy must never spawn the
        # process again (guard is AutoRestartEnabled=false set by the cap).
        $script:AutoRestartEnabled = $false
        $script:RestartCapHit = $true
        $script:StartProcCalls = 0
        Mock Get-CachedHealth { $false }
        Mock Find-DshProcessId { $null }
        Mock Start-Process { $script:StartProcCalls++; $null }
        Start-DshProxy
        $script:StartProcCalls | Should Be 0
    }

    It "manual Restart re-enables auto-restart and resets the counter" {
        $script:AutoRestartEnabled = $false
        $script:RestartCapHit = $true
        $script:RestartCount = 10
        $script:ManagedByTray = $false
        Mock Find-DshProcessId { $null }
        Restart-DshProxy
        $script:AutoRestartEnabled | Should Be $true
        $script:RestartCapHit | Should Be $false
        $script:RestartCount | Should Be 0
    }
}

Describe "Start-NewConversation (async, non-blocking, v1.7.1)" {
    BeforeEach {
        $script:AsyncJobs = @{}
        $script:NewChatMenuItem = $null
    }

    It "returns immediately without running GUI automation or RPC on the UI thread" {
        Mock Invoke-GuiNewConversation { throw "GUI automation must not run on the UI thread" }
        Mock Invoke-RestMethod { throw "RPC must not run on the UI thread" }
        Mock Start-AsyncJob { param($Id, $Script, $Arguments) $script:KickedId = $Id; "newconv" }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Start-NewConversation
        $sw.Stop()
        Assert-MockCalled Start-AsyncJob -Times 1 -Exactly
        Assert-MockCalled Invoke-GuiNewConversation -Times 0 -Exactly
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly
        $script:KickedId | Should Be "newconv"
        ($sw.Elapsed.TotalMilliseconds -lt 500) | Should Be $true
    }

    It "does not kick a second job while one is in flight" {
        $script:AsyncJobs["newconv"] = @{ PS = $null; Handle = $null; Rs = $null; Started = Get-Date }
        $script:KickCount = 0
        Mock Start-AsyncJob { $script:KickCount++; "newconv" }
        Start-NewConversation
        $script:KickCount | Should Be 0
    }

    It "shows the new-chat balloon when the GUI path succeeded" {
        Mock Show-Balloon { param($Title, $Text, $Icon) $script:LastBalloon = $Title }
        Complete-NewConversation -Output @(@{ Ok = $true; Mode = "gui" })
        $script:LastBalloon | Should Be $script:L.BalloonNewChat
    }

    It "opens the app with the fragment and toasts when the RPC path succeeded" {
        Mock Show-Balloon { param($Title, $Text, $Icon) $script:LastBalloon = $Title }
        Mock Start-DshApp { param($Path) $script:OpenedPath = $Path }
        Complete-NewConversation -Output @(@{ Ok = $true; Mode = "rpc"; Fragment = "#tray-new-x"; SessionId = "s1" })
        $script:OpenedPath | Should Be "#tray-new-x"
        $script:LastBalloon | Should Be $script:L.BalloonNewChat
    }

    It "opens the dashboard when the GUI failed and dsh was not healthy" {
        Mock Start-DshApp { param($Path) $script:OpenedPath = $Path }
        Complete-NewConversation -Output @(@{ Ok = $false; Mode = "dashboard"; Error = "not healthy" })
        $null -eq $script:OpenedPath | Should Be $true
    }

    It "shows an error toast and opens the dashboard when the RPC fallback failed" {
        Mock Show-Balloon { param($Title, $Text, $Icon) $script:LastBalloon = $Title }
        Mock Start-DshApp { }
        Complete-NewConversation -Output @(@{ Ok = $false; Mode = "error"; Error = "session.create rejected" })
        $script:LastBalloon | Should Be $script:L.BalloonError
    }
}

Describe "Stop-RunningAgent (async, non-blocking, v1.7.1)" {
    BeforeEach {
        $script:AsyncJobs = @{}
    }

    It "returns immediately without a synchronous RPC" {
        Mock Invoke-DshRpc { throw "RPC must not run on the UI thread" }
        Mock Invoke-RestMethod { throw "RPC must not run on the UI thread" }
        Mock Start-AsyncJob { param($Id, $Script, $Arguments) $script:KickedId = $Id; $Id }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-RunningAgent -ChildSessionId "s1" -ParentSessionId "p1" -Mode "continuable" -Label "Agent A"
        $sw.Stop()
        Assert-MockCalled Start-AsyncJob -Times 1 -Exactly
        Assert-MockCalled Invoke-DshRpc -Times 0 -Exactly
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly
        $script:KickedId | Should Be "agentstop-s1"
        ($sw.Elapsed.TotalMilliseconds -lt 500) | Should Be $true
    }

    It "routes a one-shot agent to session.cancel" {
        Mock Start-AsyncJob { param($Id, $Script, $Arguments) $script:JobArgs = $Arguments; $Id }
        Stop-RunningAgent -ChildSessionId "s1" -ParentSessionId "" -Mode "one-shot" -Label "A"
        $script:JobArgs[1] | Should Be "session.cancel"
    }

    It "toasts and force-refreshes the poll on a successful agent stop" {
        Mock Show-Balloon { param($Title, $Text, $Icon) $script:LastBalloon = $Title }
        Mock Invoke-AgentPoll { param($ForceRefresh) $script:Polled = $ForceRefresh }
        Complete-AgentStop -Id "agentstop-s1" -Output @(@{ Ok = $true; SessionId = "s1"; Label = "Agent A" })
        $script:LastBalloon | Should Be $script:L.BalloonAgentStopped
        $script:Polled | Should Be $true
        $script:AgentKnown["s1"] | Should Be "stopping"
    }

    It "toasts an error when the agent stop RPC failed" {
        Mock Show-Balloon { param($Title, $Text, $Icon) $script:LastBalloon = $Title }
        Complete-AgentStop -Id "agentstop-s1" -Output @(@{ Ok = $false; SessionId = "s1"; Label = "Agent A" })
        $script:LastBalloon | Should Be $script:L.BalloonError
    }
}

Describe "Read-Config (numeric validation, v1.7.1)" {
    It "falls back to the default for a non-numeric healthintervalseconds" {
        $tmp = Join-Path $TestDrive "bad-int.json"
        @{ healthintervalseconds = "abc" } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.healthintervalseconds | Should Be 10
    }

    It "falls back to the default for a negative restartdelayseconds" {
        $tmp = Join-Path $TestDrive "neg-delay.json"
        @{ restartdelayseconds = -5 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.restartdelayseconds | Should Be 5
    }

    It "rejects port 0 and port 70000" {
        $tmp0 = Join-Path $TestDrive "port0.json"
        @{ port = 0 } | ConvertTo-Json | Set-Content -LiteralPath $tmp0 -Encoding UTF8
        (Read-Config -ConfigPath $tmp0).port | Should Be 3080
        $tmpHi = Join-Path $TestDrive "portHi.json"
        @{ port = 70000 } | ConvertTo-Json | Set-Content -LiteralPath $tmpHi -Encoding UTF8
        (Read-Config -ConfigPath $tmpHi).port | Should Be 3080
    }

    It "falls back to the default for an out-of-range uifontsize" {
        $tmp = Join-Path $TestDrive "font.json"
        @{ uifontsize = 500 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.uifontsize | Should Be 9
    }

    It "falls back to the default for a garbage agentpollseconds string" {
        $tmp = Join-Path $TestDrive "poll.json"
        @{ agentpollseconds = "nope" } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.agentpollseconds | Should Be 5
    }

    It "falls back to the default for negative healthconfirmations" {
        $tmp = Join-Path $TestDrive "conf.json"
        @{ healthconfirmations = -2 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.healthconfirmations | Should Be 2
    }

    It "keeps valid numeric values unchanged" {
        $tmp = Join-Path $TestDrive "valid.json"
        @{ port = 3090; healthintervalseconds = 15; healthdebounceseconds = 35 } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.port | Should Be 3090
        $cfg.healthintervalseconds | Should Be 15
        $cfg.healthdebounceseconds | Should Be 35
    }

    It "coerces numeric strings for back-compat" {
        $tmp = Join-Path $TestDrive "strnum.json"
        @{ port = "3090" } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        $cfg = Read-Config -ConfigPath $tmp
        $cfg.port | Should Be 3090
        $cfg.healthurl | Should Be "http://127.0.0.1:3090/"
    }

    It "defaults maxconsecutiverestarts and validates it" {
        $cfg = Read-Config -ConfigPath (Join-Path $TestDrive "nonexistent.json")
        $cfg.maxconsecutiverestarts | Should Be 10
        $tmp = Join-Path $TestDrive "cap.json"
        @{ maxconsecutiverestarts = "lots" } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        (Read-Config -ConfigPath $tmp).maxconsecutiverestarts | Should Be 10
    }
}