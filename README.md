# PM2 Popup Guard

**Kills stale Explorer, Playwright, and Windows Terminal popups that PM2 can't clean up on Windows 11.**

> Two scripts — one daemon, one daily sweep — that prevent the recurring pile-up of orphaned processes on Windows machines running PM2 with Playwright automation.

---

## The Problem

PM2 on Windows 11 has a cluster of process-leak failure modes that all manifest the same way: unexpected File Explorer windows, Windows Terminal tabs, or `EADDRINUSE` crashes that knock services offline:

| Root Cause | Symptom |
|---|---|
| Playwright automation holds `ms-playwright/` file handles | File Explorer windows pop open mid-scrape |
| Node.js spawns browser without `windowsHide: true` | Windows Terminal tabs appear at `AppData\Local\ms` |
| PM2 daemon crashes while Python service holds a port | `EADDRINUSE` blocks restart |
| Historical crash loops inflate restart counters | PM2 dashboard shows `>50` restarts; misleading health signals |
| `cloudflared.exe` survives PM2 daemon restart | Orphaned tunnel process, tunnel reconnects fail |

---

## What's Included

### `popup-watchdog.js` — Continuous Daemon

Polls every 2 seconds. Runs embedded PowerShell via `spawnSync` with `windowsHide: true`. Five kill rules:

1. **Explorer windows** browsing `ms-playwright` paths (via `Shell.Application` — gets real folder path, not display name)
2. **Playwright-owned chromium/msedge** with no live `node.exe` parent
3. **Orphaned chromium** processes (path-agnostic — catches headless-shell variants)
4. **Windows Terminal popup tabs** opened at `ms-playwright` paths (< 30 min old)
5. **MCP conhost.exe** windows from AI tooling spawning `npx @playwright/mcp` — **hidden, not killed** (MCP server keeps running)

### `cleanup-pm2-popups.ps1` — Daily Maintenance Sweep

Runs at 05:00 AM ET (before cron jobs start). Six phases:

| Phase | Action |
|---|---|
| 0 | PM2 daemon health check — `pm2 resurrect` if unresponsive |
| 1 | Kill `explorer.exe` processes older than 24h (skips primary shell PID) |
| 2 | Check critical port bindings — auto-restart PM2 services if down |
| 3 | Reset PM2 restart counters over 50 (`pm2 reset <app>`) |
| 4 | Kill orphaned Playwright chromium (no live `node.exe` parent) |
| 6 | Kill orphaned `cloudflared.exe` and `pythonw.exe` holding PM2 ports |

---

## Architecture

```
                                  ┌─────────────────────────────┐
                                  │  PM2 Process Manager         │
                                  │  ├── Node.js services        │
                                  │  ├── Python services          │
                                  │  └── Playwright scrapers     │
                                  └──────────┬──────────────────┘
                                             │ spawns processes
                                             ▼
                                  ┌─────────────────────────────┐
                                  │  Leaked Processes (Windows) │
                                  │  ├── explorer.exe (file hdl)│
                                  │  ├── chromium (no parent)   │
                                  │  ├── WindowsTerminal (popup)│
                                  │  ├── pythonw (port-hold)    │
                                  │  └── cloudflared (orphan)   │
                                  └──────────┬──────────────────┘
                                             │ killed/hidden by
                          ┌──────────────────┴──────────────────┐
                          │                                      │
              ┌───────────▼──────────┐          ┌───────────────▼──────┐
              │ popup-watchdog.js   │          │ cleanup-pm2-popups   │
              │ (daemon, 2s poll)   │          │ (daily, 05:00 AM ET) │
              │ PowerShell P/Invoke  │          │ 6-phase sweep +      │
              │ Win32 ShowWindowAsync│          │ port healing +       │
              └─────────────────────┘          │ counter reset        │
                                               └──────────────────────┘
```

---

## Log Output

Both scripts write structured logs to `./logs/`:

```
[05:00:01] [INFO] PM2 Popups Cleanup - 2026-05-13 05:00:01
[05:00:01] [INFO] PHASE 0: Checking PM2 daemon health...
[05:00:02] [INFO]   PM2 daemon responsive
[05:00:02] [INFO] PHASE 1: Scanning stale explorer.exe windows...
[05:00:02] [WARN]   PID 18432: age 26.3 hours - KILLING
[05:00:03] [INFO] PHASE 2: Checking critical port bindings...
[05:00:03] [WARN]   :9009 NOT BOUND - tiktok-api down
[05:00:04] [INFO]     Restarted tiktok-api via PM2
```

`popup-watchdog.js` uses JSON logs:

```json
{"ts":"2026-05-13T05:00:01.234Z","action":"sweep","count":2,"killed":["explorer:18432","orphan-chromium:22110"]}
```

---

## Key Engineering Details

- **`Shell.Application` for Explorer:** `$shell.Windows()` gives the actual folder path from COM automation — more reliable than window title matching
- **CimInstance batch fetch:** `Win32_Process` queried once per sweep phase, not per-process — reduces `~1430ms` total to `~66ms`
- **`netstat` single capture:** Port binding checks capture `netstat -ano` once and filter from variable — saves `~54ms` vs 4 separate `netstat` calls
- **`StreamWriter` for logging:** PowerShell's `Add-Content` costs `~4.5ms/call`; one open `StreamWriter` amortizes that across the whole run
- **Conhost hide-not-kill:** MCP conhost windows are `SW_HIDE`'d (nCmdShow=0) via `ShowWindowAsync`, not killed — keeps the underlying MCP server process alive

---

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Node.js 18+
- PM2 (`npx pm2` or `pnpm add -g pm2`)
- Admin rights not required (process parent checks use `Get-CimInstance`, visible to current user)

---

*Built by Frxncois — not open source.*
