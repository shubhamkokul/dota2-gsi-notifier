# Dota 2 GSI Notifier — Integration Test Suite
# Simulates real game events by POSTing GSI payloads to the listener.
# Run this AFTER both dota-gsi-listener.ps1 and dota-notifier.ps1 are running.
#
# Each scenario pauses 12s between sends so the notifier's 8s poll loop
# has time to pick up the change and call Claude before the next state fires.

$port = 49152
$uri  = "http://localhost:$port/"

# ── helpers ────────────────────────────────────────────────────────────────────

function Send-State($payload, [string]$label) {
    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    try {
        Invoke-WebRequest -Uri $uri -Method POST -Body $json -ContentType "application/json" `
            -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host ("[TEST] $([datetime]::Now.ToString('HH:mm:ss')) => SENT: $label") -ForegroundColor Yellow
    } catch {
        Write-Host ("[TEST] FAILED to send '$label': $_") -ForegroundColor Red
    }
}

function Wait-ForNotifier([int]$seconds = 12) {
    Write-Host ("[TEST] Waiting ${seconds}s for notifier to process...") -ForegroundColor DarkGray
    Start-Sleep -Seconds $seconds
}

function Make-State {
    param(
        [string] $gameState,
        [int]    $clock,
        [string] $heroName  = "npc_dota_hero_antimage",
        [int]    $level     = 1,
        [int]    $hp        = 1000,
        [int]    $maxHp     = 1000,
        [int]    $mana      = 400,
        [int]    $maxMana   = 400,
        [bool]   $alive     = $true,
        [int]    $kills     = 0,
        [int]    $deaths    = 0,
        [int]    $assists   = 0,
        [int]    $gold      = 1500,
        [int]    $gpm       = 350,
        [int]    $ultCd     = 0,
        [bool]   $ultCanUse = $true
    )

    return @{
        map = @{
            game_state = $gameState
            clock_time = $clock
            game_time  = $clock
        }
        hero = @{
            name       = $heroName
            level      = $level
            health     = $hp
            max_health = $maxHp
            mana       = $mana
            max_mana   = $maxMana
            alive      = $alive
        }
        player = @{
            kills         = $kills
            deaths        = $deaths
            assists       = $assists
            gold          = $gold
            gold_per_min  = $gpm
            buyback_cost  = 200
            net_worth     = ($gold + 2000)
            xp_per_min    = 450
            team_name     = "radiant"
        }
        abilities = @{
            ability0 = @{ name = "antimage_mana_break";  level = 4; can_use = $true;    cooldown = 0;      ultimate = $false }
            ability1 = @{ name = "antimage_blink";       level = 4; can_use = $true;    cooldown = 0;      ultimate = $false }
            ability2 = @{ name = "antimage_spell_shield"; level = 4; can_use = $true;   cooldown = 0;      ultimate = $false }
            ability3 = @{ name = "antimage_mana_void";   level = 3; can_use = $ultCanUse; cooldown = $ultCd; ultimate = $true }
        }
        items = @{
            slot0 = @{ name = "item_power_treads" }
            slot1 = @{ name = "item_battlefury"   }
            slot2 = @{ name = "item_manta"        }
            slot3 = @{ name = "item_empty"        }
            slot4 = @{ name = "item_empty"        }
            slot5 = @{ name = "item_empty"        }
        }
        minimap = @{
            h1 = @{ team = 3; unitname = "npc_dota_hero_juggernaut" }
            h2 = @{ team = 3; unitname = "npc_dota_hero_lion"       }
            h3 = @{ team = 3; unitname = "npc_dota_hero_tidehunter"  }
            h4 = @{ team = 2; unitname = "npc_dota_hero_crystal_maiden" }
            h5 = @{ team = 2; unitname = "npc_dota_hero_earthshaker"    }
        }
    }
}

# ── check listener is up ───────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Dota GSI Notifier Test Suite ===" -ForegroundColor Cyan
Write-Host "Hero: Anti-Mage | Enemies: Juggernaut, Lion, Tidehunter" -ForegroundColor Cyan
Write-Host "Watch the notifier window for Claude responses." -ForegroundColor Cyan
Write-Host ""

try {
    Invoke-WebRequest -Uri $uri -Method POST -Body '{}' -ContentType "application/json" `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "[TEST] Listener is UP on port $port" -ForegroundColor Green
} catch {
    Write-Host "[TEST] ERROR: Listener not responding on port $port. Start dota-gsi-listener.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Start-Sleep -Seconds 2

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1: Game Start (PRE_GAME)
# Expected: GAME PLAN call — lane strategy, win condition, biggest threat
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 1: GAME START ---" -ForegroundColor Magenta
Write-Host "    Expected: GAME PLAN (draft analysis, lane plan, win condition)"
$s1 = Make-State -gameState "DOTA_GAMERULES_STATE_PRE_GAME" -clock -30 -level 1 -kills 0 -deaths 0 -assists 0 -gold 600
Send-State $s1 "PRE_GAME / Game Start"
Wait-ForNotifier 14

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2: Kill at 4 minutes
# Expected: KILL event — what to do with the advantage
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 2: KILL ---" -ForegroundColor Magenta
Write-Host "    Expected: KILL event with follow-up advice"
# First send baseline (clock=60, kills=0) so notifier sets prev.kills=0
$s2a = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 60 -level 3 -kills 0 -gold 1200
Send-State $s2a "IN_PROGRESS baseline"
Wait-ForNotifier 12

# Now increment kills
$s2b = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 80 -level 3 -kills 1 -gold 1600
Send-State $s2b "Kill #1"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3: Fight — heavy HP drop (40% in one tick)
# Expected: HEAVY DAMAGE alert
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 3: FIGHT / HP DROP ---" -ForegroundColor Magenta
Write-Host "    Expected: HEAVY DAMAGE — fight or escape decision"
# First establish HP at full (1000/1000)
$s3a = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 120 -level 3 -kills 1 -hp 1000 -maxHp 1000
Send-State $s3a "Full HP baseline"
Wait-ForNotifier 12

# Drop HP by 42% (420 health)
$s3b = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 130 -level 3 -kills 1 -hp 580 -maxHp 1000
Send-State $s3b "HP drop 42% — in a fight"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4: Death
# Expected: DIED event — respawn plan, buyback check
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 4: DEATH ---" -ForegroundColor Magenta
Write-Host "    Expected: DIED event — where to go on respawn"
$s4 = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 150 -level 3 -kills 1 -deaths 1 -hp 0 -maxHp 1000 -alive $false
Send-State $s4 "Death #1"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5: Level 6 power spike
# Expected: Level spike call — what changes at level 6
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 5: LEVEL 6 SPIKE ---" -ForegroundColor Magenta
Write-Host "    Expected: Level 6 call — power spike, what changes"
# First send level 5 to give notifier prev.level=5
$s5a = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 300 -level 5 -kills 1 -deaths 1 -hp 900 -maxHp 1200 -alive $true -gold 2000
Send-State $s5a "Level 5 baseline"
Wait-ForNotifier 12

# Now hit level 6
$s5b = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 320 -level 6 -kills 1 -deaths 1 -hp 900 -maxHp 1200 -alive $true -gold 2000
Send-State $s5b "Level 6 — ult unlocked"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6: Ult comes off cooldown
# Expected: "ult ready" call
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 6: ULT OFF COOLDOWN ---" -ForegroundColor Magenta
Write-Host "    Expected: Ult ready call — when and how to use it"
# First: ult on cooldown (60s) — sets ultWasOnCD=true
$s6a = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 400 -level 6 -kills 2 -deaths 1 -hp 1100 -maxHp 1300 -alive $true -gold 3500 -gpm 420 -ultCd 60 -ultCanUse $false
Send-State $s6a "Ult on cooldown"
Wait-ForNotifier 12

# Now: ult ready
$s6b = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 465 -level 6 -kills 2 -deaths 1 -hp 1100 -maxHp 1300 -alive $true -gold 3800 -gpm 430 -ultCd 0 -ultCanUse $true
Send-State $s6b "Ult off cooldown"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7: Critical low HP (<20%)
# Expected: LOW HP call — escape route
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 7: LOW HP ---" -ForegroundColor Magenta
Write-Host "    Expected: LOW HP call — escape options"
$s7 = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 500 -level 7 -kills 2 -deaths 1 -hp 180 -maxHp 1400 -alive $true -gold 4000
Send-State $s7 "HP at 13% — critical"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8: Game over — Victory
# Expected: Post-game summary
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "--- SCENARIO 8: GAME OVER (VICTORY) ---" -ForegroundColor Magenta
Write-Host "    Expected: Post-game summary block"
# Need to first be in IN_PROGRESS so the transition fires
$s8a = Make-State -gameState "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS" -clock 2400 -level 18 -kills 10 -deaths 2 -hp 2000 -maxHp 2000 -alive $true -gold 8000 -gpm 680
Send-State $s8a "Late game IN_PROGRESS"
Wait-ForNotifier 12

$s8b = @{
    map    = @{ game_state = "DOTA_GAMERULES_STATE_POST_GAME"; clock_time = 2450; game_time = 2450 }
    hero   = @{ name = "npc_dota_hero_antimage"; level = 18; health = 2000; max_health = 2000; mana = 400; max_mana = 400; alive = $true }
    player = @{ kills = 10; deaths = 2; assists = 5; gold = 8000; gold_per_min = 680; buyback_cost = 800; net_worth = 28000; xp_per_min = 820; team_name = "radiant"; win = 1 }
}
Send-State $s8b "POST_GAME — Victory"
Wait-ForNotifier 12

# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "=== TEST RUN COMPLETE ===" -ForegroundColor Cyan
Write-Host "Check the notifier window for all 8 scenarios." -ForegroundColor Cyan
Write-Host "Grading rubric:" -ForegroundColor White
Write-Host "  1. GAME PLAN   — lane plan, win condition, biggest threat named?" -ForegroundColor White
Write-Host "  2. KILL        — specific follow-up action (push, smoke, roshan)?" -ForegroundColor White
Write-Host "  3. FIGHT       — clear fight-or-escape call with items mentioned?" -ForegroundColor White
Write-Host "  4. DEATH       — respawn routing + buyback mention?" -ForegroundColor White
Write-Host "  5. LEVEL 6     — ult usage advice specific to Anti-Mage?" -ForegroundColor White
Write-Host "  6. ULT READY   — conditions for Mana Void, mana threshold?" -ForegroundColor White
Write-Host "  7. LOW HP      — escape path, Blink usage mentioned?" -ForegroundColor White
Write-Host "  8. POST GAME   — summary block (KDA, GPM, net worth) printed?" -ForegroundColor White
Write-Host ""
Write-Host "Format check: every Claude response should follow NOW / NEXT / WATCH" -ForegroundColor Yellow
Write-Host "Latency check: watch [claude XXXms] tags — ideally under 2000ms" -ForegroundColor Yellow
