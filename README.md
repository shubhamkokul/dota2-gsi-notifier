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

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      DOTA 2 (running)                        │
│             GSI HTTP POST to localhost:49152 every ~1s       │
└────────────────────────────┬─────────────────────────────────┘
                             │ raw JSON payload
                             ▼
┌──────────────────────────────────────────────────────────────┐
│               dota-gsi-listener.ps1                          │
│         HttpListener on port 49152                           │
│                                                              │
│  · Receives the JSON from Dota 2                             │
│  · Logs changes to console (KDA / gold band / HP band)       │
│  · Writes full state → dota_state.json                       │
│  · Responds 200 OK so Dota keeps sending                     │
└────────────────────────────┬─────────────────────────────────┘
                             │ writes
                             ▼
                      dota_state.json
                             │ reads every 8s
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                 dota-notifier.ps1                            │
│                                                              │
│  FAST LOOP — every 8s ─────────────────────────────────────  │
│    HP drop > 15%          → fight alert          [Claude]    │
│    HP drop > 35%          → critical damage      [Claude]    │
│    HP < 20%               → escape advice        [Claude]    │
│    Kill / death / assist  → context response     [Claude]    │
│    Respawn                → where to go          [Claude]    │
│    Level 6/11/16/20/25    → power spike          [Claude]    │
│    Ult off cooldown       → engage signal        [Claude]    │
│    Tower attacked/lost    → defend or trade      [Claude]    │
│                                                              │
│  KDA CHECK — every 120s (360s after 50 min) ───────────────  │
│    KDA changed?           → events already fired, skip       │
│    < 5min since last call → hardcoded reminder   [free]      │
│    ≥ 5min since last call → strategic call       [Claude]    │
│                                                              │
│  GAME START ───────────────────────────────────────────────  │
│    Draft known            → full game plan       [Claude]    │
└────────────────────────────┬─────────────────────────────────┘
                             │ HTTPS POST (Haiku, max 120 tokens)
                             ▼
┌──────────────────────────────────────────────────────────────┐
│              Claude API  (claude-haiku-4-5)                  │
│         api.anthropic.com/v1/messages                        │
│                                                              │
│  Input:  system prompt + compact game context + trigger      │
│          ~30 + ~60 + ~20 = ~110 tokens per call              │
│  Output: 3-line NOW / NEXT / WATCH, capped at 120 tokens     │
└────────────────────────────┬─────────────────────────────────┘
                             │
                             ▼
                     Terminal output
    [!!] red = urgent    [>>] cyan = info    [--] gray = free reminder
```

Every Claude call shows timing and token usage:
```
[08:42:11] [>>] KILL! DRAGON KNIGHT K:3
       1. NOW: Grab the rune at river and push mid — their carry is out of position.
       2. NEXT: Convert this lead into a tower; tier 1 mid should fall before they respawn.
       3. WATCH: Storm Spirit has blink — he can re-engage fast once he buys back.
       [claude 612ms | in:104 out:88 | session:312/264]
```

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

**Strategic (KDA check — every 120s, stretches to 360s after 50 min):**
- KDA changed since last check → events already fired advice, skip
- KDA unchanged, last Claude call < 5 min ago → free hardcoded reminder, no API call
- KDA unchanged, 5+ min silence → force strategic Claude call with time milestones and Roshan window
- Time milestones: 3min bounties, 7min rotation, 10min tier 1, 15min item check, 20min objectives, 25min group up, 30min commit, 40min late game
- Roshan windows: ~8, 20, 30, 40 minute marks

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
Dota Notifier v5 | Claude-powered | fast:8s | KDA-check:120s | force-call:5min | Ctrl+C to stop
API key loaded. Model: claude-haiku-4-5-20251001
```

### Step 7 — Launch Dota 2 and play

GSI connects automatically when a match starts. The listener logs each tick when something meaningful changes (KDA, gold band, HP band). The notifier fires advice on events.

On game start you immediately get a draft-based game plan. During the game each Claude call shows timing and token usage:
```
[08:42:11] [!!] DRAGON KNIGHT DIED D:1
       1. NOW: No buyback available — wait full respawn and use the time to plan purchases.
       2. NEXT: Rush Power Treads then start Blink Dagger; you need mobility before fighting again.
       3. WATCH: Enigma has Black Hole up — do not fight until your BKB is ready.
       [claude 591ms | in:102 out:91 | session:204/182]
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

Edit the top of `dota-notifier.ps1` to tune the behaviour:

```powershell
$fastPoll = 8   # seconds per event detection cycle (lower = more responsive, higher = fewer checks)
```

The KDA check interval and force-call threshold are set in the main loop and scale automatically with game time:

| Phase | Check interval | Force-call after |
|---|---|---|
| Normal (< 50 min) | 120s | 5 min silence |
| Late game (> 50 min) | 360s | 7 min silence |

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

## License

MIT
