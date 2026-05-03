# Dota 2 Notifier v5 — Claude AI powered
# Fast loop (8s)     — event detection: fights, kills, deaths, towers, levels, ult
# KDA check (120s)   — smart pacing: reminder if quiet, force call if 5min+ no events
# Late game (>50min) — intervals stretch to 6-8 min (game slows down)
#
# API call strategy:
#   ALWAYS call Claude: kill, death, assist, fight, low HP, level spike, ult ready, tower
#   SKIP call (reminder only): 120s elapsed, KDA unchanged, last call <5min ago
#   FORCE call: 5min with no Claude call regardless of KDA
#   LATE GAME: force call every 7min after 50min mark

$stateFile = "$PSScriptRoot\dota_state.json"
$fastPoll  = 8   # seconds per detection cycle

# ── API key ────────────────────────────────────────────────────────────────────
$envPath = "$PSScriptRoot\.env"
if (Test-Path $envPath) {
    Get-Content $envPath | Where-Object { $_ -match "^\s*[^#].*=" } | ForEach-Object {
        $parts = $_ -split "=", 2
        if ($parts.Count -eq 2) {
            [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}
$script:apiKey         = $env:ANTHROPIC_API_KEY
$script:totalTokensIn  = 0
$script:totalTokensOut = 0

# ── Output ─────────────────────────────────────────────────────────────────────
# [!!] red  = urgent (fight, death, tower, low HP)
# [>>] cyan = informational (kill, level, strategic)
# [--] gray = reminder (no API call, zero tokens)
function Print-Block($title, $points, [switch]$critical, [switch]$reminder) {
    $ts    = "[" + [datetime]::Now.ToString('HH:mm:ss') + "]"
    if ($reminder) {
        Write-Host ("$ts [--] $title") -ForegroundColor DarkGray
        foreach ($p in $points) { Write-Host ("       - $p") -ForegroundColor DarkGray }
        return
    }
    $color = if ($critical) { "Red" } else { "Cyan" }
    $tag   = if ($critical) { "[!!]" } else { "[>>]" }
    Write-Host ("$ts $tag $title") -ForegroundColor $color
    $i = 1
    foreach ($p in $points) { Write-Host ("       $i. $p") -ForegroundColor White; $i++ }
}

# ── Data helpers ───────────────────────────────────────────────────────────────
function Get-HeroName($raw) {
    if (-not $raw) { return "HERO" }
    ($raw -replace "npc_dota_hero_","" -replace "_"," ").ToUpper()
}

function Get-CurrentItems($s) {
    if (-not $s.items) { return @() }
    $items = @()
    foreach ($slot in (@(0..5|%{"slot$_"}) + @(0..4|%{"stash$_"}))) {
        $item = $s.items.$slot
        if ($item -and $item.name -and $item.name -ne "item_empty") {
            $items += $item.name -replace "item_",""
        }
    }
    return $items
}

function Get-EnemyHeroes($s) {
    if (-not $s.draft -or -not $s.player) { return @() }
    $key = if ($s.player.team_name -eq "radiant") { "team3" } else { "team2" }
    $d = $s.draft.$key; if (-not $d) { return @() }
    0..4 | ForEach-Object { $p = $d."pick$_"; if ($p -and $p.id) { Get-HeroName $p.id } } | Where-Object { $_ }
}

function Get-AlliedHeroes($s) {
    if (-not $s.draft -or -not $s.player) { return @() }
    $key = if ($s.player.team_name -eq "radiant") { "team2" } else { "team3" }
    $d = $s.draft.$key; if (-not $d) { return @() }
    0..4 | ForEach-Object { $p = $d."pick$_"; if ($p -and $p.id) { Get-HeroName $p.id } } | Where-Object { $_ }
}

function Get-UltAbility($s) {
    if (-not $s.abilities) { return $null }
    $s.abilities.PSObject.Properties.Value | Where-Object { $_.ultimate -eq $true } | Select-Object -First 1
}

# ── Claude integration ─────────────────────────────────────────────────────────
# Compact single-line context: ~60 tokens per call
function Build-GameContext($hero, $player, $clock, $currentItems, $enemies, $allies) {
    $hp   = if ($hero.max_health -gt 0) { [math]::Round($hero.health / $hero.max_health * 100) } else { 0 }
    $mp   = if ($hero.max_mana   -gt 0) { [math]::Round($hero.mana   / $hero.max_mana   * 100) } else { 0 }
    $bb   = if ($player.buyback_cost -gt 0 -and $player.gold -ge $player.buyback_cost) { "BB:yes" } else { "BB:no($($player.buyback_cost)g)" }
    $itms = if ($currentItems.Count -gt 0) { $currentItems -join "," } else { "none" }
    $ene  = if ($enemies.Count -gt 0) { $enemies -join "," } else { "?" }
    $ally = if ($allies.Count   -gt 0) { $allies  -join "," } else { "?" }
    $mins = [math]::Round($clock / 60, 1)
    return "$(Get-HeroName $hero.name) lv$($hero.level) HP:$hp% MP:$mp% gold:$($player.gold) GPM:$($player.gold_per_min) KDA:$($player.kills)/$($player.deaths)/$($player.assists) $bb | items:$itms | $mins min | vs:$ene | allies:$ally"
}

# Consistent output format enforced via system prompt — every Claude response looks the same:
#   1. NOW:   what to do immediately
#   2. NEXT:  priority for the next 60-120 seconds
#   3. WATCH: threat or opportunity to be aware of
# Token budget: ~110 in / ~90 out = ~200 tokens per call on Haiku (~$0.0002)
# ~25-35 calls per game = ~$0.005-0.007 total
function Get-ClaudeAdvice($trigger, $ctx) {
    if (-not $script:apiKey) {
        return @("No API key — add ANTHROPIC_API_KEY to .env and restart")
    }

    $systemPrompt = "You are a Dota 2 in-game coach. Respond in exactly this format — no deviations, no preamble:
1. NOW: [what to do this second]
2. NEXT: [priority for next 60-120 seconds]
3. WATCH: [key threat or opportunity]
One sentence per line. Be specific: name items, heroes, objectives."

    $userMsg = "$trigger | $ctx"

    $bodyObj = [ordered]@{
        model      = "claude-haiku-4-5-20251001"
        max_tokens = 120
        system     = $systemPrompt
        messages   = @(@{ role = "user"; content = $userMsg })
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 5 -Compress))

    try {
        $t0   = [datetime]::Now
        $resp = Invoke-WebRequest `
            -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers @{
                "x-api-key"         = $script:apiKey
                "anthropic-version" = "2023-06-01"
                "content-type"      = "application/json"
            } `
            -Body $bodyBytes `
            -UseBasicParsing -ErrorAction Stop

        $ms     = ([datetime]::Now - $t0).TotalMilliseconds
        $result = $resp.Content | ConvertFrom-Json
        $text   = $result.content[0].text

        $script:totalTokensIn  += $result.usage.input_tokens
        $script:totalTokensOut += $result.usage.output_tokens
        Write-Host ("       [claude $([math]::Round($ms))ms | in:$($result.usage.input_tokens) out:$($result.usage.output_tokens) | session:$($script:totalTokensIn)/$($script:totalTokensOut)]") -ForegroundColor DarkGray

        $points = $text -split "`n" |
                  Where-Object { $_ -match "^\s*\d+\." } |
                  ForEach-Object { ($_ -replace "^\s*\d+\.\s*","").Trim() }

        if ($points.Count -eq 0) { return @($text.Trim()) }
        return $points

    } catch {
        $msg = $_.Exception.Message
        if ($msg.Length -gt 100) { $msg = $msg.Substring(0, 100) }
        return @("Claude error: $msg")
    }
}

# Hardcoded nudges — zero API cost, fire when game is quiet (no KDA change, no events)
# Phrased as low-urgency prompts, shown in gray so they don't distract
function Get-Reminder($clock) {
    $mins = [math]::Round($clock / 60)
    if ($mins -lt 8)  { return "Quiet — focus on last hits and deny. Don't trade unless it's free." }
    if ($mins -lt 15) { return "Still farming — check rune timer and ward the river." }
    if ($mins -lt 25) { return "Nothing happening — push a lane or stack jungle camps." }
    if ($mins -lt 35) { return "Quiet stretch — look for Roshan or a pickoff before next teamfight." }
    if ($mins -lt 45) { return "Long game — stay grouped, don't get caught out alone." }
    return "Very late — one lost fight can end it. Play for picks, not forced fights."
}

# ── Roshan windows (clock seconds) ─────────────────────────────────────────────
$roshanWindows = @(480, 1200, 1800, 2400)

# ── Time milestones ────────────────────────────────────────────────────────────
$timeMilestones = @(
    @{ t=180;  label="3 min: bounty runes up" }
    @{ t=420;  label="7 min: rotation window" }
    @{ t=600;  label="10 min: tier 1 pressure" }
    @{ t=900;  label="15 min: item timing check" }
    @{ t=1200; label="20 min: mid game objectives" }
    @{ t=1500; label="25 min: group up phase" }
    @{ t=1800; label="30 min: commit to win condition" }
    @{ t=2400; label="40 min: late game" }
)

$keyLevels = @(6, 11, 16, 20, 25)

# ── State ──────────────────────────────────────────────────────────────────────
$prev = @{
    gameState       = ""
    kills           = -1
    deaths          = -1
    assists         = -1
    level           = 0
    alive           = $true
    hpRaw           = 0
    hpMax           = 1
    lowHpFired      = $false
    ultWasOnCD      = $false
    lastFightAlert  = 0          # stores Ticks, used for fight cooldown
    lastClaudeClock = -999       # game-seconds when last Claude call was made
    lastCheckClock  = -999       # game-seconds of last 120s KDA check
    lastKDACheck    = ""         # KDA string at last check ("kills/deaths/assists")
    buildingHP      = @{}
    firedTriggers   = [System.Collections.Generic.HashSet[int]]::new()
    firedRosh       = [System.Collections.Generic.HashSet[int]]::new()
}

Write-Host "Dota Notifier v5 | Claude-powered | fast:${fastPoll}s | KDA-check:120s | force-call:5min | Ctrl+C to stop" -ForegroundColor Green
if ($script:apiKey) {
    Write-Host "API key loaded. Model: claude-haiku-4-5-20251001" -ForegroundColor Green
} else {
    Write-Host "WARNING: ANTHROPIC_API_KEY not set. Add it to .env" -ForegroundColor Yellow
}

# ── Main loop ──────────────────────────────────────────────────────────────────
while ($true) {
    Start-Sleep -Seconds $fastPoll

    if (-not (Test-Path $stateFile)) { continue }
    try { $s = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }

    $map    = $s.map
    $hero   = $s.hero
    $player = $s.player
    if (-not $map -or -not $hero -or -not $player) { continue }

    $gameState    = $map.game_state
    $clock        = [int]$map.clock_time
    $active       = $gameState -eq "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS"
    $heroName     = Get-HeroName $hero.name
    $enemies      = Get-EnemyHeroes $s
    $allies       = Get-AlliedHeroes $s
    $currentItems = Get-CurrentItems $s
    $hpPct        = if ($hero.max_health -gt 0) { $hero.health / $hero.max_health } else { 1 }
    $manaPct      = if ($hero.max_mana   -gt 0) { $hero.mana   / $hero.max_mana   } else { 0 }
    $clockMins    = [math]::Round($clock / 60, 1)
    $ctx          = Build-GameContext $hero $player $clock $currentItems $enemies $allies

    # ── Game start ─────────────────────────────────────────────────────────────
    if ($gameState -in @("DOTA_GAMERULES_STATE_PRE_GAME","DOTA_GAMERULES_STATE_GAME_IN_PROGRESS") `
        -and $prev.gameState -notin @("DOTA_GAMERULES_STATE_PRE_GAME","DOTA_GAMERULES_STATE_GAME_IN_PROGRESS")) {

        $prev.kills = $player.kills; $prev.deaths = $player.deaths; $prev.assists = $player.assists
        $prev.alive = $true; $prev.lowHpFired = $false; $prev.ultWasOnCD = $false
        $prev.hpMax = 1; $prev.hpRaw = 0; $prev.lastClaudeClock = 0; $prev.lastCheckClock = 0
        $prev.lastKDACheck = "$($player.kills)/$($player.deaths)/$($player.assists)"
        $prev.level = $hero.level; $prev.buildingHP = @{}
        $prev.firedTriggers.Clear(); $prev.firedRosh.Clear()

        # Full game plan based on the draft — the first and most important Claude call
        $allyStr  = if ($allies.Count  -gt 0) { $allies  -join ", " } else { "unknown" }
        $enemyStr = if ($enemies.Count -gt 0) { $enemies -join ", " } else { "unknown" }
        $trigger  = "GAME START. Hero: $heroName. Allies: $allyStr. Enemies: $enemyStr. Give the game plan: how to lane, win condition for this draft, and biggest enemy threat to respect."
        $points   = Get-ClaudeAdvice $trigger $ctx
        Print-Block "GAME PLAN — $heroName" $points
        $prev.lastClaudeClock = $clock
    }

    # ── Game end ───────────────────────────────────────────────────────────────
    if ($gameState -eq "DOTA_GAMERULES_STATE_POST_GAME" -and $prev.gameState -eq "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS") {
        $outcome = if ($player.win -eq 1) { "VICTORY" } else { "DEFEAT" }
        Print-Block ("$heroName - $outcome") @(
            "K/D/A: $($player.kills)/$($player.deaths)/$($player.assists)"
            "GPM: $($player.gold_per_min) | XPM: $($player.xp_per_min)"
            "Net worth: $($player.net_worth)"
        ) -critical
    }

    if (-not $active) { $prev.gameState = $gameState; continue }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # FAST CHECKS (every 8s) — all events call Claude and update lastClaudeClock
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    # Fight detection via HP trend
    if ($prev.hpMax -gt 0 -and $hero.alive -and $prev.alive) {
        $hpDrop    = $prev.hpRaw - $hero.health
        $hpDropPct = if ($prev.hpMax -gt 0) { $hpDrop / $prev.hpMax } else { 0 }

        if ($hpDropPct -gt 0.35 -and $prev.lastFightAlert -lt ([datetime]::Now.AddSeconds(-30).Ticks)) {
            $points = Get-ClaudeAdvice "CRITICAL: HP dropped $([math]::Round($hpDropPct*100))% in 8s — heavy damage incoming. Fight or escape?" $ctx
            Print-Block "HEAVY DAMAGE — DECIDE NOW" $points -critical
            $prev.lastFightAlert  = [datetime]::Now.Ticks
            $prev.lastClaudeClock = $clock

        } elseif ($hpDropPct -gt 0.15 -and $prev.lastFightAlert -lt ([datetime]::Now.AddSeconds(-60).Ticks)) {
            $points = Get-ClaudeAdvice "HP dropped $([math]::Round($hpDropPct*100))% in 8s — taking damage. In a fight?" $ctx
            Print-Block "YOU ARE IN A FIGHT" $points -critical
            $prev.lastFightAlert  = [datetime]::Now.Ticks
            $prev.lastClaudeClock = $clock
        }
    }
    $prev.hpRaw = $hero.health
    $prev.hpMax = $hero.max_health

    # Tower / building tracking
    if ($s.buildings -and $player) {
        $myKey    = if ($player.team_name -eq "radiant") { "radiant" } else { "dire" }
        $enemyKey = if ($player.team_name -eq "radiant") { "dire" }    else { "radiant" }
        foreach ($side in @(@{data=$s.buildings.$myKey;friendly=$true}, @{data=$s.buildings.$enemyKey;friendly=$false})) {
            if (-not $side.data) { continue }
            $side.data.PSObject.Properties | ForEach-Object {
                $bName  = $_.Name
                $bHP    = $_.Value.health
                $bMax   = $_.Value.max_health
                $prevHP = $prev.buildingHP[$bName]
                if ($null -ne $prevHP -and $bMax -gt 0) {
                    $drop  = ($prevHP - $bHP) / $bMax
                    $label = ($bName -replace "dota_(goodguys|badguys)_","" -replace "good_|bad_","" -replace "_"," ").ToUpper()
                    if ($side.friendly) {
                        if ($bHP -eq 0 -and $prevHP -gt 0) {
                            $points = Get-ClaudeAdvice "Your $label was destroyed. What now?" $ctx
                            Print-Block "YOUR $label LOST" $points -critical
                            $prev.lastClaudeClock = $clock
                        } elseif ($drop -gt 0.25) {
                            $points = Get-ClaudeAdvice "Your $label is under attack — $([math]::Round($drop*100))% HP lost this tick. Defend or trade?" $ctx
                            Print-Block "YOUR $label UNDER ATTACK" $points -critical
                            $prev.lastClaudeClock = $clock
                        }
                    } else {
                        if ($bHP -eq 0 -and $prevHP -gt 0) {
                            $points = Get-ClaudeAdvice "Enemy $label destroyed. How to press this?" $ctx
                            Print-Block "ENEMY $label DESTROYED" $points
                            $prev.lastClaudeClock = $clock
                        } elseif ($drop -gt 0.3) {
                            $points = Get-ClaudeAdvice "Enemy $label is very low — commit to take it?" $ctx
                            Print-Block "ENEMY $label LOW" $points
                            $prev.lastClaudeClock = $clock
                        }
                    }
                }
                $prev.buildingHP[$bName] = $bHP
            }
        }
    }

    # Kill
    if ($prev.kills -ge 0 -and $player.kills -gt $prev.kills) {
        $points = Get-ClaudeAdvice "Got a kill — $($player.kills) kills total. What to do with this advantage?" $ctx
        Print-Block "KILL! $heroName K:$($player.kills)" $points -critical
        $prev.lastClaudeClock = $clock
    }
    $prev.kills = $player.kills

    # Assist
    if ($prev.assists -ge 0 -and $player.assists -gt $prev.assists) {
        $points = Get-ClaudeAdvice "Got an assist — $($player.assists) assists total. Follow up?" $ctx
        Print-Block "ASSIST! A:$($player.assists)" $points -critical
        $prev.lastClaudeClock = $clock
    }
    $prev.assists = $player.assists

    # Death
    if ($prev.deaths -ge 0 -and $player.deaths -gt $prev.deaths) {
        $bbStatus = if ($player.buyback_cost -gt 0 -and $player.gold -ge $player.buyback_cost) {
            "buyback available ($($player.buyback_cost)g)"
        } else {
            "no buyback ($($player.gold)g of $($player.buyback_cost)g needed)"
        }
        $points = Get-ClaudeAdvice "Died — death #$($player.deaths). $bbStatus. What to do on respawn?" $ctx
        Print-Block "$heroName DIED D:$($player.deaths)" $points -critical
        $prev.lowHpFired      = $false
        $prev.lastClaudeClock = $clock
    }
    $prev.deaths = $player.deaths

    # Respawn
    if (-not $prev.alive -and $hero.alive) {
        $points = Get-ClaudeAdvice "Just respawned. Where to go first?" $ctx
        Print-Block "$heroName respawned" $points
        $prev.lowHpFired      = $false
        $prev.lastClaudeClock = $clock
    }
    $prev.alive = [bool]$hero.alive

    if ($hero.alive) {

        # Level milestones
        if ($hero.level -gt $prev.level -and $hero.level -in $keyLevels) {
            $points = Get-ClaudeAdvice "Hit level $($hero.level) — power spike. What does this change?" $ctx
            Print-Block "$heroName Level $($hero.level)!" $points -critical
            $prev.lastClaudeClock = $clock
        }
        $prev.level = $hero.level

        # Ult ready
        $ult = Get-UltAbility $s
        if ($ult) {
            $ultReady = ($ult.cooldown -eq 0 -and $ult.can_use -eq $true)
            if ($ultReady -and $prev.ultWasOnCD) {
                $points = Get-ClaudeAdvice "Ult off cooldown. Mana: $([math]::Round($manaPct*100))%. When and how to use it?" $ctx
                Print-Block "$heroName ult ready" $points -critical
                $prev.lastClaudeClock = $clock
            }
            $prev.ultWasOnCD = -not $ultReady
        }

        # Low HP
        if ($hpPct -lt 0.2 -and -not $prev.lowHpFired) {
            $points = Get-ClaudeAdvice "HP at $([math]::Round($hpPct*100))% — critically low. How to escape?" $ctx
            Print-Block "$heroName LOW HP $([math]::Round($hpPct*100))%" $points -critical
            $prev.lowHpFired      = $true
            $prev.lastClaudeClock = $clock
        }
        if ($hpPct -gt 0.5) { $prev.lowHpFired = $false }
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # KDA CHECK LOOP — runs every 120s (stretches to 360s after 50 min)
    # Decision tree:
    #   KDA changed?       -> events already handled it, update tracking, skip
    #   KDA unchanged
    #     < 5min since last Claude call  -> hardcoded reminder (0 tokens)
    #     >= 5min since last Claude call -> force strategic Claude call
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    $isLateGame     = $clock -gt 3000   # > 50 minutes
    $checkInterval  = if ($isLateGame) { 360 } else { 120 }   # how often to check
    $forceInterval  = if ($isLateGame) { 420 } else { 300 }   # max gap before force call

    if (($clock - $prev.lastCheckClock) -ge $checkInterval) {

        $currentKDA = "$($player.kills)/$($player.deaths)/$($player.assists)"

        if ($currentKDA -ne $prev.lastKDACheck) {
            # KDA changed — events already fired Claude calls, nothing extra needed
            # Just update tracking silently
        } else {
            # Nothing happened since last check
            $silentSecs = $clock - $prev.lastClaudeClock

            if ($silentSecs -ge $forceInterval) {
                # 5+ min (7+ min late game) with no events — force a strategic call
                $pending = @()
                foreach ($m in $timeMilestones) {
                    if ($clock -ge $m.t -and -not $prev.firedTriggers.Contains($m.t)) {
                        $pending += $m.label
                        $prev.firedTriggers.Add($m.t) | Out-Null
                    }
                }
                $roshNote = ""
                foreach ($roshT in $roshanWindows) {
                    if ($clock -ge ($roshT - 60) -and $clock -le ($roshT + 120) -and -not $prev.firedRosh.Contains($roshT)) {
                        $roshNote = "Roshan window open (~$([math]::Round($roshT/60)) min)."
                        $prev.firedRosh.Add($roshT) | Out-Null
                    }
                }
                $parts = @("Quiet game — no kills or deaths for $([math]::Round($silentSecs/60)) minutes. Strategic check at $clockMins min.")
                if ($pending.Count -gt 0) { $parts += "Milestones: $($pending -join '; ')." }
                if ($roshNote)           { $parts += $roshNote }
                $parts += "What should I be doing right now?"

                $points = Get-ClaudeAdvice ($parts -join " ") $ctx
                Print-Block "Strategic check ($clockMins min)" $points
                $prev.lastClaudeClock = $clock

            } else {
                # Quiet but recent event was not long ago — just nudge, no API call
                Print-Block "Reminder ($clockMins min)" @(Get-Reminder $clock) -reminder
            }
        }

        $prev.lastKDACheck  = $currentKDA
        $prev.lastCheckClock = $clock
    }

    $prev.gameState = $gameState
}
