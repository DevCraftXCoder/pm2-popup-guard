#!/usr/bin/env node
'use strict';

/**
 * popup-watchdog.js — PM2 popup process killer
 *
 * Usage:
 *   node popup-watchdog.js                    — daemon mode: poll every 2s
 *   node popup-watchdog.js --once             — single sweep, exit
 *   node popup-watchdog.js --interval 5000    — daemon with 5s interval
 *
 * Kills/hides:
 *   - explorer.exe windows holding ms-playwright file handles
 *   - chromium/chrome/msedge launched by Playwright scrapers
 *   - Orphan chromium processes (no live node.exe parent)
 *   - Windows Terminal windows at ms-playwright paths (Windows 11 default console host)
 *   - conhost.exe windows spawned by Claude Code MCP loaders (npx @playwright/mcp, paste-mcp)
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const LOG_FILE = path.join(__dirname, 'logs', 'popup-watchdog.log');

const args = process.argv.slice(2);
const once = args.includes('--once');
const intervalIdx = args.indexOf('--interval');
const interval = intervalIdx !== -1 ? parseInt(args[intervalIdx + 1], 10) || 2000 : 2000;

const HEARTBEAT_INTERVAL = 5 * 60 * 1000; // emit alive ping every 5 minutes
let totalSweeps = 0;
let totalKills  = 0;
const startedAt = Date.now();

// Ensure logs dir exists
fs.mkdirSync(path.join(__dirname, 'logs'), { recursive: true });

function log(entry) {
  const line = JSON.stringify({ ts: new Date().toISOString(), ...entry });
  try {
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch (_) {
    // Non-fatal — keep sweeping even if log write fails
  }
  if (entry.count > 0) {
    console.log(`[popup-watchdog] sweep: ${entry.count} killed`);
  }
}

// PowerShell script embedded inline. Uses Win32 P/Invoke to hide windows
// before killing so the user never sees a flash. Walks process trees for
// orphan chromium processes spawned by PM2 Playwright jobs.
const PS_SCRIPT = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Helper {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

$killed = @()

# 1. Kill explorer windows browsing ms-playwright folders (use Shell.Application for real folder path)
try {
    $shell = New-Object -ComObject Shell.Application
    $shell.Windows() | Where-Object {
        $_.Name -eq 'File Explorer' -and (
            ($_.LocationURL -like '*ms-playwright*') -or
            ($_.LocationURL -like '*AppData*Local*ms*')
        )
    } | ForEach-Object {
        $hwnd = $_.HWND
        if ($hwnd) {
            [Win32Helper]::ShowWindowAsync([IntPtr]$hwnd, 0) | Out-Null
            # Get explorer PID from HWND
            $procId = 0
            [void][Win32Helper]::GetWindowThreadProcessId([IntPtr]$hwnd, [ref]$procId)
            if ($procId -gt 0) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                $killed += "explorer:$procId"
            }
        }
    }
} catch {}

# 1b. Kill Playwright-owned chromium/msedge processes with no live node.exe parent
# (Path check works here — it IS the exe path)
# Guard: skip if a live node.exe parent exists — the scraper is actively using the browser.
$nodeIds1b = (Get-Process node -ErrorAction SilentlyContinue).Id
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne [IntPtr]::Zero -and
    $_.Name -match '^(chromium|chrome|msedge|chrome-headless-shell)$' -and
    $_.Path -like '*ms-playwright*'
} | ForEach-Object {
    $procId1b = $_.Id
    $ppid1b = $null
    try {
        $cim1b = Get-CimInstance Win32_Process -Filter "ProcessId=$procId1b" -ErrorAction SilentlyContinue
        if ($cim1b) { $ppid1b = $cim1b.ParentProcessId }
    } catch {}
    if ($null -eq $ppid1b -or $ppid1b -notin $nodeIds1b) {
        [Win32Helper]::ShowWindowAsync($_.MainWindowHandle, 0) | Out-Null
        Stop-Process -Id $procId1b -Force -ErrorAction SilentlyContinue
        $killed += "$($_.Name):$procId1b"
    }
}

# 2. Kill orphan chromium processes with no live node.exe parent
$nodeIds = (Get-Process node -ErrorAction SilentlyContinue).Id
Get-Process -Name 'chromium','chrome-headless-shell' -ErrorAction SilentlyContinue | ForEach-Object {
    $chromePid = $_.Id
    $ppid = $null
    try {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$chromePid" -ErrorAction SilentlyContinue
        if ($cimProc) { $ppid = $cimProc.ParentProcessId }
    } catch {}
    if ($null -eq $ppid -or $ppid -notin $nodeIds) {
        Stop-Process -Id $chromePid -Force -ErrorAction SilentlyContinue
        $killed += "orphan-chromium:$chromePid"
    }
}

# 3. Kill orphaned pythonw.exe processes holding known PM2 service ports whose
#    parent process is dead. These are left behind when the PM2 daemon itself
#    crashes — PM2 can't SIGTERM them, so they hold the port and block restart.
$pm2Ports = @(9009, 9010)
try {
    $netConns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in $pm2Ports }
    foreach ($conn in $netConns) {
        $ownerPid = $conn.OwningProcess
        if (-not $ownerPid -or $ownerPid -le 0) { continue }
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.Name -notmatch '^pythonw?$') { continue }
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
        if (-not $cimProc) { continue }
        $ppid = $cimProc.ParentProcessId
        $parent = Get-Process -Id $ppid -ErrorAction SilentlyContinue
        if (-not $parent) {
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
            $killed += "orphan-pythonw:$ownerPid:$($conn.LocalPort)"
        }
    }
} catch {}

# 4. Kill rogue Windows Terminal windows opened at ms-playwright paths.
#    Root cause: Windows 11 uses WT as the default console host, so any PM2
#    child spawn that lacks windowsHide:true opens a new WT window instead of
#    a hidden console. The watchdog's explorer.exe check never caught these.
#    Safety guard: skip WT processes older than 30 minutes (user's real session).
try {
    $wtCutoff = (Get-Date).AddMinutes(-30)
    Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue | ForEach-Object {
        $wtProc = $_
        $wtAge = $null
        try { $wtAge = $wtProc.StartTime } catch {}
        # Skip old terminals — those are the user's real session
        if ($null -ne $wtAge -and $wtAge -lt $wtCutoff) { return }
        $wtTitle = ''
        try { $wtTitle = $wtProc.MainWindowTitle } catch {}
        if ($wtTitle -like '*ms-playwright*' -or
            ($wtTitle -like '*AppData*' -and ($wtTitle -like '*\ms-playwright*' -or $wtTitle -like '*\ms\*'))) {
            if ($wtProc.MainWindowHandle -ne [IntPtr]::Zero) {
                [Win32Helper]::ShowWindowAsync($wtProc.MainWindowHandle, 0) | Out-Null
            }
            Stop-Process -Id $wtProc.Id -Force -ErrorAction SilentlyContinue
            $killed += "wt-popup:$($wtProc.Id):$wtTitle"
        }
    }
} catch {}


# 5. Hide console windows (conhost.exe) created by Claude Code's MCP loader.
#    Root cause: Claude Code spawns MCP servers via cmd.exe /d /s /c "npx @playwright/mcp..."
#    without CREATE_NO_WINDOW. Windows assigns a conhost.exe console host, which appears as a
#    popup tab in Windows Terminal. We HIDE (not kill) so the MCP server keeps running.
#    IsWindowVisible guard prevents log spam on repeat sweeps after the first hide.
$mcpPatterns = @(
    'npx.*@playwright[/\\]mcp',
    'npx.*playwright.*mcp',
    'paste-mcp[/\\]server'
)
try {
    Get-CimInstance Win32_Process -Filter "Name='conhost.exe'" | ForEach-Object {
        $ch5 = $_
        $parent5 = Get-CimInstance Win32_Process -Filter "ProcessId=$($ch5.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $parent5) { return }
        $cmd5 = $parent5.CommandLine
        if (-not $cmd5) { return }
        $isMcp5 = $false
        foreach ($pat5 in $mcpPatterns) {
            if ($cmd5 -match $pat5) { $isMcp5 = $true; break }
        }
        if (-not $isMcp5) { return }
        $proc5 = Get-Process -Id $ch5.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc5) { return }
        $hwnd5 = $proc5.MainWindowHandle
        if ($hwnd5 -eq [IntPtr]::Zero) { return }
        # Only act when window is currently visible — avoids log spam on repeat sweeps
        if (-not [Win32Helper]::IsWindowVisible($hwnd5)) { return }
        [Win32Helper]::ShowWindowAsync($hwnd5, 0) | Out-Null
        $shortCmd5 = $cmd5.Substring(0, [Math]::Min(80, $cmd5.Length))
        $killed += "mcp-conhost:$($ch5.ProcessId):$shortCmd5"
    }
} catch {}

$killed -join ','
`;

function sweep() {
  const result = spawnSync(
    'powershell',
    ['-NoProfile', '-NonInteractive', '-Command', PS_SCRIPT],
    {
      encoding: 'utf8',
      timeout: 10000,
      windowsHide: true,
    }
  );

  if (result.error) {
    log({ action: 'sweep_error', error: result.error.message, count: 0, killed: [] });
    return 0;
  }

  const stdout = (result.stdout || '').trim();
  const killed = stdout ? stdout.split(',').filter(Boolean) : [];
  log({ action: 'sweep', count: killed.length, killed });
  totalSweeps++;
  totalKills += killed.length;
  return killed.length;
}

if (once) {
  const n = sweep();
  process.exit(n > 0 ? 0 : 0);
}

// Daemon mode
console.log(`[popup-watchdog] daemon started, interval=${interval}ms, pid=${process.pid}`);

setInterval(() => {
  const uptimeMin = Math.round((Date.now() - startedAt) / 60000);
  console.log(`[popup-watchdog] alive sweeps=${totalSweeps} kills=${totalKills} uptime=${uptimeMin}m`);
}, HEARTBEAT_INTERVAL);

process.on('SIGTERM', () => {
  console.log('[popup-watchdog] SIGTERM — exiting');
  process.exit(0);
});
process.on('SIGINT', () => {
  console.log('[popup-watchdog] SIGINT — exiting');
  process.exit(0);
});

(function loop() {
  try {
    sweep();
  } catch (err) {
    log({ action: 'loop_error', error: err.message, count: 0, killed: [] });
  }
  setTimeout(loop, interval);
})();
