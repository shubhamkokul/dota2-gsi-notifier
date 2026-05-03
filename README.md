# Dota 2 GSI Notifier

A real-time in-game coaching assistant for Dota 2 built entirely in PowerShell. No installs. No Electron. No cloud. Two scripts and a config file.

Hooks into Dota 2's built-in Game State Integration (GSI) system and turns raw game state into actionable advice — fired to your terminal and Windows toast notifications in real time.

---

## Features

### Combat Detection (fires every 8 seconds)
- **Fight detection** — HP drops >15% in 8s triggers "YOU ARE IN A FIGHT" before you die, not after
- **Heavy damage alert** — HP drops >35% triggers "DECIDE NOW — fight or flight"
- **Low HP warning** — fires at <20% HP with escape advice, resets when HP recovers above 50%
- **Ult ready** — fires when ult comes off cooldown, combined with mana check for "engage now" signal

### Event-Driven Advice (fires immediately on event)
- **Kill** — push/rotate/Roshan advice + item build reminder
- **Assist** — roaming tip, objective follow-up
- **Death** — buyback status, why-you-died callout, item priority on respawn
- **Respawn** — regroup tip, enemy awareness
- **Level milestones** — 6, 11, 16, 20, 25 each get a specific action call

### Strategic Advice (fires every 3 in-game minutes)
- **Farm efficiency** — compares your GPM to role-based expected GPM (carry/mid/offlane/support benchmarks). Tells you if you're 80+ GPM behind.
- **Team presence signal** — after you buy a power item (BKB, Blink, Aghs) or pass 25 min, prompts "stop farming, group up"
- **Roshan windows** — alerts at ~8, 20, 30, 40 minute marks
- **Time triggers** — 3min bounties, 7min rotation, 10min tower pressure, 20min act-now, 25min group-up, 30min commit

### Item Intelligence
- **Hero-specific build order** — 26 heroes mapped, shows next 3 unbuilt core items with gold gap
- **Situational items** — enemy-based recommendations (BKB vs Enigma, MKB vs PA, Linken vs AM)
- **Gold milestone alerts** — fires when you can afford a key item
- **No re-suggestions** — correctly reads GSI item names and won't suggest items you already own

### Map & Draft Awareness
- **Tower tracking** — fires when your tower is under attack (>25% HP drop in one cycle) or destroyed, and when enemy tower is being pushed
- **Enemy draft** — lists enemy heroes at game start with situational item advice per matchup
- **Hero synergy** — identifies your best roaming partners from your allies, fires at game start and on respawn/level milestones

---

## Architecture

```
Dota 2 (running)
  └─ GSI HTTP POST every ~1 second
        └─► dota-gsi-listener.ps1  (port 49152)
                └─ saves → dota_state.json
                      └─► dota-notifier.ps1  (reads every 8s)
                                └─ Windows toast + terminal output
```

### Two-tier polling
| Loop | Interval | Purpose |
|---|---|---|
| Fast | 8 seconds | Combat: HP trend, KDA delta, alive status, ult cooldown |
| Slow | Every 3 game-minutes | Strategy: item advice, farm efficiency, tower tracking, time triggers |

---

## Setup

### 1. Copy the GSI config

Copy `gamestate_integration_claude.cfg` to:
```
[Dota 2 install path]\game\dota\cfg\gamestate_integration\
```

Default Steam path:
```
C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\cfg\gamestate_integration\
```

### 2. Add Steam launch option

Steam > Library > Dota 2 > Properties > General > Launch Options:
```
-gamestateintegration
```

### 3. Run the scripts

**Terminal 1 — Listener:**
```powershell
powershell -ExecutionPolicy Bypass -File dota-gsi-listener.ps1
```

**Terminal 2 — Notifier:**
```powershell
powershell -ExecutionPolicy Bypass -File dota-notifier.ps1
```

### 4. Launch Dota 2

GSI connects automatically. You'll see a connection confirmation in Terminal 1 once a match starts.

---

## Configuration

Edit the top of `dota-notifier.ps1`:

```powershell
$mode              = "aggressive"  # "aggressive" = proactive | "reactive" = events only
$fastPoll          = 8             # seconds per combat detection cycle
$strategicInterval = 180           # game-seconds between strategic advice passes
```

---

## Hero Coverage

**Build orders defined for:**
Weaver, Anti-Mage, Juggernaut, Invoker, Pudge, Phantom Assassin, Faceless Void, Drow Ranger, Luna, Sniper, Axe, Dragon Knight, Crystal Maiden, Lion, Rubick, Bristleback, Ursa, Lina, Shadow Fiend, Terrorblade, Medusa, Spectre, Earthshaker, Tidehunter, Enigma, Witch Doctor

**Synergy tables defined for:**
Weaver, Anti-Mage, Juggernaut, Invoker, Pudge, Phantom Assassin, Faceless Void, Drow Ranger, Luna, Sniper, Axe, Ursa, Terrorblade, Spectre

---

## Files

| File | Purpose |
|---|---|
| `dota-gsi-listener.ps1` | HTTP server on port 49152. Receives GSI data, writes to `dota_state.json`. Change-detection logging — only prints on KDA/gold band/HP band change. |
| `dota-notifier.ps1` | Two-tier polling loop. All advice logic lives here. |
| `gamestate_integration_claude.cfg` | GSI config — drop into Dota's config folder. |

---

## Requirements

- Windows (PowerShell 5.1 — ships with Windows 10/11, no install needed)
- Dota 2 (Steam)
- No other dependencies

---

## Known Limitations

- Windows only (uses `[Windows.UI.Notifications.ToastNotificationManager]` for toasts and `[System.Net.HttpListener]`)
- Terminal window must stay open during the session
- Works best with a second monitor; terminal advice is less useful on a single-monitor setup
- Hero builds and synergy tables require manual updates as the meta changes

---

## What's Next — Electron Overlay

The terminal approach works but the natural upgrade is a transparent always-on-top overlay:

- **HUD layer** — HP, mana, gold, KDA rendered over the game
- **Item build timeline** — visual tracker showing what to buy and when
- **Fight pulse** — visual indicator when fight detection fires
- **Voice alerts** — text-to-speech for critical events (death, low HP, ult ready)
- **Ally tracker** — minimap overlay showing teammate positions (minimap data already enabled in config)
- **Post-game analytics** — GPM trend, death heatmap, session replay

`dota_state.json` is already the data source. Electron just needs to watch and render it.

---

## License

MIT
