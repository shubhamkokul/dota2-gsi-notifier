# Dota 2 GSI Notifier

Real-time in-game coaching assistant for Dota 2. Hooks into Dota 2's built-in Game State Integration (GSI) system and sends your live game state to Claude AI, which fires back specific, actionable advice directly in your terminal.

No installs. No Electron. No third-party overlays. Two PowerShell scripts, one config file, one API key.

---

## Why Claude API instead of hardcoded logic

Most Dota overlays hardcode their advice — fixed item builds per hero, static rotation timings, generic tips that don't know what's actually happening in your game. This tool sends your real game state to Claude on every trigger and gets advice that's specific to *this* game, *this* moment.

**What that means in practice:**

- **Works for every hero** — no list of supported heroes, no missing entries. Claude knows the full roster and current meta.
- **Adapts to the enemy team** — death advice when you're against Enigma + Faceless Void is different from death advice against a poke lineup. Claude sees their heroes and responds accordingly.
- **Knows what you own** — item suggestions account for what's already in your inventory. It won't tell you to buy Blink if you have it.
- **Buyback-aware** — death advice changes depending on whether you have buyback gold or not.
- **GPM and net worth context** — strategic advice accounts for whether you're ahead or behind economically, not just the game clock.
- **No stale data** — hardcoded builds go out of date every patch. Claude's knowledge doesn't need a code update when the meta shifts.
- **Compounds context** — a kill at 8 minutes with Phase Boots and 2000 gold gets different advice than the same kill at 30 minutes with a full inventory. Every call gets the full picture.

---

## How it works

```
Dota 2 (running)
  └─ GSI HTTP POST every ~1 second
        └─► dota-gsi-listener.ps1  (HTTP server, port 49152)
                └─ saves → dota_state.json
                      └─► dota-notifier.ps1  (reads every 8s)
                                └─ Claude API (claude-haiku) → advice
                                └─ terminal output (red = urgent, cyan = strategic)
```

Two polling loops:
| Loop | Interval | What it covers |
|---|---|---|
| Fast | 8 seconds | HP trend (fight detection), kills, deaths, assists, level spikes, ult cooldown, towers |
| Slow | Every 3 game-minutes | Strategic check-in: item timing, Roshan windows, game phase milestones |

Every trigger sends your current game state (hero, level, HP, mana, gold, GPM, items, KDA, enemies, allies, buyback) to Claude and gets back 3 specific recommendations.

---

## What triggers advice

**Combat (fast loop — 8s):**
- HP drops >15% in one tick → "you are in a fight"
- HP drops >35% in one tick → "heavy damage, decide now"
- HP falls below 20% → low HP escape advice
- Kill, assist, death → immediate context-aware response
- Respawn → where to go next
- Level 6 / 11 / 16 / 20 / 25 → power spike callout
- Ultimate comes off cooldown → engage signal with mana check
- Your tower under attack or destroyed
- Enemy tower low or destroyed

**Strategic (slow loop — every 3 game-minutes):**
- Time milestones: 3min bounties, 7min rotation, 10min tier 1, 15min item check, 20min objectives, 25min group up, 30min commit, 40min late game
- Roshan windows: ~8, 20, 30, 40 minute marks
- General strategic check-in with full game context

---

## Setup — step by step

### Step 1 — Clone the repo

```powershell
git clone https://github.com/shubhamkokul/dota2-gsi-notifier.git
cd dota2-gsi-notifier
```

### Step 2 — Get an Anthropic API key

1. Go to **console.anthropic.com**
2. Sign in or create a free account
3. Left sidebar → **API Keys** → **Create Key**
4. Copy the key (starts with `sk-ant-`)

> **Security:** Never paste your API key into a chat, commit it to git, or share it. The `.gitignore` in this repo already excludes `.env`.

### Step 3 — Create your .env file

Copy the example file:
```powershell
Copy-Item .env.example .env
```

Open `.env` in any text editor and replace the placeholder:
```
ANTHROPIC_API_KEY=sk-ant-your-actual-key-here
```

Or do it in one command (replace the key value):
```powershell
"ANTHROPIC_API_KEY=sk-ant-your-key-here" | Out-File -FilePath .env -Encoding utf8
```

### Step 4 — Copy the GSI config into Dota 2

Copy `gamestate_integration_claude.cfg` into Dota 2's GSI folder:

```powershell
Copy-Item gamestate_integration_claude.cfg "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\cfg\gamestate_integration\"
```

If your Steam library is on a different drive, find the path in:
Steam → Library → Dota 2 → right-click → Manage → Browse local files

The `gamestate_integration\` folder may not exist yet — create it if needed:
```powershell
New-Item -ItemType Directory -Path "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\cfg\gamestate_integration"
```

### Step 5 — Add the Steam launch option

Steam → Library → Dota 2 → right-click → Properties → General → Launch Options:
```
-gamestateintegration
```

This tells Dota 2 to start sending GSI data. Only needs to be done once.

### Step 6 — Run the scripts

Open **two terminal windows** in the project folder.

**Terminal 1 — start the listener first:**
```powershell
powershell -ExecutionPolicy Bypass -File dota-gsi-listener.ps1
```

You should see:
```
Dota 2 GSI listener started on port 49152
```

**Terminal 2 — start the notifier:**
```powershell
powershell -ExecutionPolicy Bypass -File dota-notifier.ps1
```

You should see:
```
Dota Notifier v4 | Claude-powered | fast:8s | strategic:every 3 game-min
API key loaded. Model: claude-haiku-4-5-20251001
```

### Step 7 — Launch Dota 2 and play

GSI connects automatically when a match starts. The listener logs each tick when something meaningful changes (KDA, gold band, HP band). The notifier fires advice on events.

Each Claude call shows timing and token usage:
```
[>>] YOU ARE IN A FIGHT
       1. Use Blink to close and land Fissure across their escape path.
       2. Your BKB is ready — activate before Lina can stun you.
       3. Ping Lion to follow up — he has Hex available.
       [claude 743ms | in:98 out:87 | session in:450 out:320]
```

---

## Token cost

Uses `claude-haiku-4-5-20251001` — the fastest and cheapest Claude model.

| What | Tokens |
|---|---|
| System prompt | ~30 |
| Game context per call | ~60 |
| Trigger description | ~20 |
| Response (3 sentences) | ~80 |
| **Total per call** | **~190** |

A 40-minute game triggers roughly 40 Claude calls.
**Estimated cost: ~$0.006 per game** (less than a cent).

The notifier prints running token totals so you can track it live.

---

## Configuration

Edit the top of `dota-notifier.ps1` to tune the loops:

```powershell
$fastPoll          = 8    # seconds per combat detection cycle
$strategicInterval = 180  # game-seconds between strategic advice passes
```

---

## Files

| File | Purpose |
|---|---|
| `dota-gsi-listener.ps1` | HTTP server on port 49152. Receives GSI data from Dota 2, writes to `dota_state.json`. |
| `dota-notifier.ps1` | Two-tier polling loop. Detects events, calls Claude API, fires advice. |
| `gamestate_integration_claude.cfg` | Tells Dota 2 what data to send and where. Drop into Dota's GSI config folder. |
| `.env` | Your API key. Never commit this. Already in `.gitignore`. |
| `.env.example` | Template showing the format. Safe to commit. |

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (ships with Windows — no install needed)
- Dota 2 via Steam
- Anthropic API key (console.anthropic.com)
- No other dependencies

---

## Troubleshooting

**Listener shows nothing after game starts**
- Check that `-gamestateintegration` is in your Steam launch options
- Restart Dota 2 after adding the launch option
- Confirm `gamestate_integration_claude.cfg` is in the right folder

**Notifier says "No API key"**
- Make sure `.env` exists in the same folder as the scripts
- Check that the key starts with `sk-ant-` and has no extra spaces
- Restart the notifier after editing `.env`

**Port 49152 already in use**
- Change the port in both `dota-gsi-listener.ps1` and `gamestate_integration_claude.cfg` to another high port (e.g. 49153)

**Claude error in output**
- Check your API key is valid at console.anthropic.com
- Check you have credits — new accounts get free credits but they expire

---

## What's next — Electron overlay

The terminal approach works but a transparent always-on-top overlay is the natural upgrade:

- HUD layer — HP, mana, gold, KDA rendered over the game
- Visual fight pulse — indicator when fight detection fires
- Item build timeline — visual tracker showing what to buy next
- Voice alerts — text-to-speech for critical events so you never look away
- Ally tracker — minimap overlay using GSI minimap data (already enabled in config)
- Post-game analytics — GPM trend, death heatmap, session replay

`dota_state.json` is already the live data source. Electron just reads and renders it.

---

## License

MIT
