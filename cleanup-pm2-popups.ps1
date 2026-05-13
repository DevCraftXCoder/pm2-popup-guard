# PM2 Popups Cleanup - Daily maintenance to prevent EADDRINUSE + stale explorers
# Runs daily at 5:00 AM ET (before EV Betta cron jobs at 06:00, 10:00, 14:00, 18:00)
# Targets:
#   1. Stale explorer.exe windows (file handles from Playwright crashes)
#   2. Port binding conflicts (EADDRINUSE on :9009, :3000, etc)
#   3. Restart counter artifacts (high counts from historical crashes)
#   4. Orphaned processes from Playwright browser automation

param(
    [switch]$DryRun = $false,
    [int]$StaleHours = 24
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logDir = "C:\Za\livestat\logs"
$logFile = Join-Path $logDir "pm2-cleanup-$(Get-Date -Format 'yyyy-MM-dd').log"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# OPT 1: Open StreamWriter once (append mode) â€” replaces per-call Add-Content (~4.5ms/call).
# Closed in finally block so it always flushes even on error.
$script:logWriter = [System.IO.StreamWriter]::new($logFile, $true)

function Log {
    param([string]$message, [string]$level = "INFO")
    $prefix = "$(Get-Date -Format 'HH:mm:ss')"
    $msg = "[$prefix] [$level] $message"
    Write-Host $msg -ForegroundColor $(if ($level -eq "ERROR") { "Red" } elseif ($level -eq "WARN") { "Yellow" } else { "White" })
    $script:logWriter.WriteLine($msg)
}

try {

Log "=========================================================" "INFO"
Log "PM2 Popups Cleanup - $timestamp" "INFO"
Log "=========================================================" "INFO"

if ($DryRun) { Log "[DRY RUN] No changes will be made" "WARN" }

$cleanupCount = 0
$issuesFound = 0

# PHASE 0: PM2 Daemon Health Check
Log "" "INFO"
Log "PHASE 0: Checking PM2 daemon health..." "INFO"

try {
    $pm2PingOut = pm2 ping 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log "  PM2 daemon responsive" "INFO"
    } else {
        Log "  PM2 daemon unresponsive (exit $LASTEXITCODE) - attempting resurrect" "WARN"
        $issuesFound++
        if (-not $DryRun) {
            pm2 resurrect 2>&1 | Out-Null
            Start-Sleep -Seconds 10
            Log "  pm2 resurrect completed - waiting 10s for services" "INFO"
            $cleanupCount++
        } else {
            Log "  [DRY RUN] Would run pm2 resurrect" "INFO"
        }
    }
} catch {
    Log "  PM2 daemon check error: $_" "WARN"
}

# PHASE 1: Close stale explorer.exe windows
Log "" "INFO"
Log "PHASE 1: Scanning stale explorer.exe windows..." "INFO"

$explorers = Get-Process explorer -ErrorAction SilentlyContinue
if ($null -ne $explorers) {
    $now = Get-Date
    $staleThreshold = $now.AddHours(-$StaleHours)

    # OPT 3 (partial): Hoist primaryShellPid outside the loop â€” computed once, not per iteration.
    $primaryShellPid = ($explorers | Sort-Object StartTime | Select-Object -First 1).Id

    foreach ($e in $explorers) {
        $age = [math]::Round(($now - $e.StartTime).TotalHours, 1)
        if ($e.StartTime -lt $staleThreshold) {
            if ($e.Id -eq $primaryShellPid) {
                Log "  PID $($e.Id): age $age hours (primary shell - SKIP)" "INFO"
            } else {
                Log "  PID $($e.Id): age $age hours - KILLING" "WARN"
                if (-not $DryRun) {
                    try {
                        Stop-Process -Id $e.Id -Force -ErrorAction SilentlyContinue
                        $cleanupCount++
                    } catch {
                        Log "    Error killing PID $($e.Id): $_" "ERROR"
                    }
                } else {
                    Log "    [DRY RUN] Would kill" "INFO"
                }
            }
        }
    }
} else {
    Log "  No explorer processes found" "INFO"
}

# PHASE 2: Check port bindings
Log "" "INFO"
Log "PHASE 2: Checking critical port bindings..." "INFO"

# OPT 2: Capture netstat once, filter per-port from variable â€” saves ~3 extra netstat invocations (~54ms).
$netstatOutput = netstat -ano 2>$null | Select-String "LISTENING"

$ports = @{9009 = "tiktok-api"; 9002 = "email-saver"; 9003 = "stats-server"; 8100 = "sso-api"}
foreach ($port in $ports.Keys) {
    try {
        $netstat = $netstatOutput | Select-String ":$port\s+"
        if ($netstat) {
            $parts = $netstat -split '\s+' | Where-Object { $_ -match '^\d+$' }
            if ($parts.Count -gt 0) {
                $procId = $parts[-1]
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                $procName = if ($proc) { $proc.ProcessName } else { "Unknown" }
                Log "  :$port bound by PID $procId ($procName) - $($ports[$port])" "INFO"
            }
        } else {
            $svc2 = $ports[$port]
            Log "  :$port NOT BOUND - $svc2 down" "WARN"
            $issuesFound++
            # Skip Docker-managed services (:8100 = sso-api) — PM2 restart won't help
            $dockerPorts = @(8100)
            if ($port -notin $dockerPorts) {
                if (-not $DryRun) {
                    try {
                        pm2 restart $svc2 2>&1 | Out-Null
                        Log "    Restarted $svc2 via PM2" "INFO"
                        $cleanupCount++
                    } catch {
                        Log "    Could not restart ${svc2}: $_" "ERROR"
                    }
                } else {
                    Log "    [DRY RUN] Would run: pm2 restart $svc2" "INFO"
                }
            }
        }
    } catch {
        Log "  Error checking port :$port - $_" "ERROR"
    }
}

# PHASE 3: Reset high restart counters
Log "" "INFO"
Log "PHASE 3: Checking PM2 restart counters..." "INFO"

try {
    $pm2Raw = pm2 jlist 2>&1
    # pm2 jlist has duplicate env keys â€” ConvertFrom-Json fails. Use regex instead.
    $restartMatches = [regex]::Matches($pm2Raw, '"name"\s*:\s*"([^"]+)"[^}]+?"restart_time"\s*:\s*(\d+)')
    if ($restartMatches.Count -eq 0) {
        Log "  Could not parse PM2 output or no apps found" "WARN"
    } else {
        foreach ($m in $restartMatches) {
            $appName = $m.Groups[1].Value
            $restarts = [int]$m.Groups[2].Value
            if ($restarts -gt 50) {
                Log "  ${appName}: $restarts restarts" "WARN"
                $issuesFound++

                if (-not $DryRun) {
                    try {
                        pm2 reset $appName 2>&1 | Out-Null
                        Log "    Reset restart counter for $appName" "INFO"
                        $cleanupCount++
                    } catch {
                        Log "    Error resetting $appName - $_" "ERROR"
                    }
                } else {
                    Log "    [DRY RUN] Would reset" "INFO"
                }
            }
        }
    }
} catch {
    Log "  PM2 check error: $_" "ERROR"
}

# PHASE 4: Kill orphaned Playwright chromium processes
Log "" "INFO"
Log "PHASE 4: Checking for orphaned Playwright chromium..." "INFO"

try {
    $chromiumProcs = Get-Process -Name "chromium","chrome-headless-shell","msedge" -ErrorAction SilentlyContinue
    if ($chromiumProcs) {
        $nodeIds = (Get-Process node -ErrorAction SilentlyContinue).Id
        # OPT 3: Fetch all Win32_Process once and build a PIDâ†’ParentProcessId hashtable.
        # Replaces one Get-CimInstance call per chromium process (~1430ms total â†’ ~66ms once).
        $allProcs = Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId -ErrorAction SilentlyContinue
        $procTable = @{}
        if ($allProcs) {
            foreach ($p in $allProcs) {
                $procTable[$p.ProcessId] = $p.ParentProcessId
            }
        }

        foreach ($proc in $chromiumProcs) {
            $chromePid = $proc.Id
            $ppid = $procTable[$chromePid]
            if ($null -eq $ppid -or $ppid -notin $nodeIds) {
                Log "  PID $chromePid (chromium): no live node.exe parent - KILLING" "WARN"
                $issuesFound++
                if (-not $DryRun) {
                    try {
                        Stop-Process -Id $chromePid -Force -ErrorAction SilentlyContinue
                        $cleanupCount++
                    } catch {}
                } else {
                    Log "    [DRY RUN] Would kill" "INFO"
                }
            } else {
                Log "  PID $chromePid (chromium): live parent $ppid (node.exe) - OK" "INFO"
            }
        }
    } else {
        Log "  No chromium processes (good)" "INFO"
    }
} catch {
    Log "  Error checking chromium: $_" "ERROR"
}

# PHASE 6: Stale Service Daemons
Log "" "INFO"
Log "PHASE 6: Checking stale service daemons..." "INFO"

# 6a: Orphaned cloudflared.exe (cobalt-tunnel) — not parented by a PM2 node process
try {
    $cloudflaredProcs = Get-Process -Name 'cloudflared' -ErrorAction SilentlyContinue
    if ($cloudflaredProcs) {
        $nodeIds6a = (Get-Process node -ErrorAction SilentlyContinue).Id
        $allProcs6a = Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name -ErrorAction SilentlyContinue
        $procTable6a = @{}
        if ($allProcs6a) { foreach ($p in $allProcs6a) { $procTable6a[$p.ProcessId] = $p } }
        foreach ($cf in $cloudflaredProcs) {
            $cfPid = $cf.Id
            $ppid6a = $procTable6a[$cfPid]?.ParentProcessId
            $parentProc6a = if ($ppid6a) { Get-Process -Id $ppid6a -ErrorAction SilentlyContinue } else { $null }
            if ($null -eq $parentProc6a -or $parentProc6a.Name -ne 'node') {
                $parentDesc = if ($parentProc6a) { "$($parentProc6a.Name):$ppid6a" } else { "dead:$ppid6a" }
                Log "  cloudflared PID ${cfPid}: parent $parentDesc (not PM2 node) - KILLING" "WARN"
                $issuesFound++
                if (-not $DryRun) {
                    Stop-Process -Id $cfPid -Force -ErrorAction SilentlyContinue
                    $cleanupCount++
                } else {
                    Log "    [DRY RUN] Would kill" "INFO"
                }
            } else {
                Log "  cloudflared PID ${cfPid}: live PM2 parent $ppid6a (node) - OK" "INFO"
            }
        }
    } else {
        Log "  No cloudflared processes" "INFO"
    }
} catch {
    Log "  Error checking cloudflared: $_" "ERROR"
}

# 6b: Orphaned pythonw.exe on all PM2-managed ports (not just :9009)
$pm2PythonPorts = @(9009, 9010)
try {
    foreach ($port6b in $pm2PythonPorts) {
        $conn6b = Get-NetTCPConnection -State Listen -LocalPort $port6b -ErrorAction SilentlyContinue
        if (-not $conn6b) { continue }
        $ownerPid6b = $conn6b.OwningProcess
        if (-not $ownerPid6b -or $ownerPid6b -le 0) { continue }
        $proc6b = Get-Process -Id $ownerPid6b -ErrorAction SilentlyContinue
        if (-not $proc6b -or $proc6b.Name -notmatch '^pythonw?$') { continue }
        $cimProc6b = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid6b" -ErrorAction SilentlyContinue
        if (-not $cimProc6b) { continue }
        $ppid6b = $cimProc6b.ParentProcessId
        $parent6b = Get-Process -Id $ppid6b -ErrorAction SilentlyContinue
        if ($null -eq $parent6b) {
            Log "  pythonw PID ${ownerPid6b} on :${port6b}: parent $ppid6b dead - KILLING" "WARN"
            $issuesFound++
            if (-not $DryRun) {
                Stop-Process -Id $ownerPid6b -Force -ErrorAction SilentlyContinue
                $cleanupCount++
            } else {
                Log "    [DRY RUN] Would kill" "INFO"
            }
        } else {
            Log "  pythonw PID ${ownerPid6b} on :${port6b}: live parent $ppid6b ($($parent6b.Name)) - OK" "INFO"
        }
    }
} catch {
    Log "  Error checking pythonw daemons: $_" "ERROR"
}

# PHASE 5: Summary, Discord alert, and save state
Log "" "INFO"
Log "PHASE 5: Finalizing..." "INFO"

if (-not $DryRun -and $cleanupCount -gt 0) {
    try {
        pm2 save 2>&1 | Out-Null
        Log "  PM2 state saved to dump.pm2" "INFO"
    } catch {
        Log "  Warning: Could not save PM2 state: $_" "WARN"
    }
}

# Discord alert when issues require attention
$webhookUrl = $env:DISCORD_WEBHOOK_URL
if ($issuesFound -gt 0 -and $webhookUrl) {
    try {
        $msg = "**[cleanup-pm2-popups]** Daily sweep: $issuesFound issue(s) found, $cleanupCount cleaned. Host: $env:COMPUTERNAME | $(Get-Date -Format 'yyyy-MM-dd HH:mm') ET"
        $body = @{ content = $msg } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        Log "  Discord alert sent ($issuesFound issues)" "INFO"
    } catch {
        Log "  Warning: Discord webhook failed: $_" "WARN"
    }
} elseif ($issuesFound -eq 0) {
    Log "  No issues - Discord not notified" "INFO"
}

Log "" "INFO"
Log "=========================================================" "INFO"
Log "Summary: $cleanupCount items cleaned, $issuesFound issues detected" "INFO"
Log "=========================================================" "INFO"
Log "Log written to: $logFile" "INFO"

} finally {
    # OPT 1: Always flush and close the StreamWriter, even if an unhandled error occurs mid-script.
    if ($null -ne $script:logWriter) {
        $script:logWriter.Flush()
        $script:logWriter.Close()
        $script:logWriter.Dispose()
    }
}

exit 0
