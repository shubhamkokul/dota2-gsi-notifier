# Dota 2 Notifier v3
# Fast loop (8s)     — combat detection: HP trend, K/D/A, ult timing
# Slow loop (3 mins) — strategy: items, farm efficiency, team presence, Roshan

$stateFile         = "$PSScriptRoot\dota_state.json"
$fastPoll          = 8    # seconds per tick
$strategicInterval = 180  # game-seconds between strategic advice passes

# ── Output ────────────────────────────────────────────────────────────────────
function Send-Toast($title, $body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml("<toast duration='short'><visual><binding template='ToastGeneric'><text>$title</text><text>$body</text></binding></visual></toast>")
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { }
}

function Print-Block($title, $points, [switch]$critical) {
    $ts    = "[" + [datetime]::Now.ToString('HH:mm:ss') + "]"
    $color = if ($critical) { "Red" } else { "Cyan" }
    $tag   = if ($critical) { "[!!]" } else { "[>>]" }
    Write-Host ("$ts $tag $title") -ForegroundColor $color
    $i = 1
    foreach ($p in $points) { Write-Host ("       $i. $p") -ForegroundColor White; $i++ }
    if ($critical) { Send-Toast $title ($points -join " | ") }
}

# ── Data helpers ──────────────────────────────────────────────────────────────
function Get-HeroName($raw) {
    if (-not $raw) { return "HERO" }
    ($raw -replace "npc_dota_hero_","" -replace "_"," ").ToUpper()
}

function Get-CurrentItems($s) {
    if (-not $s.items) { return @() }
    $items = @()
    foreach ($slot in (@(0..5|%{"slot$_"}) + @(0..4|%{"stash$_"}))) {
        $item = $s.items.$slot
        if ($item -and $item.name -and $item.name -ne "item_empty") { $items += $item.name -replace "item_","" }
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

# ── Hero metadata ─────────────────────────────────────────────────────────────
$heroRoles = @{
    "weaver"="carry"; "antimage"="carry"; "juggernaut"="carry"; "phantom_assassin"="carry"
    "faceless_void"="carry"; "drow_ranger"="carry"; "luna"="carry"; "terrorblade"="carry"
    "medusa"="carry"; "spectre"="carry"; "ursa"="carry"; "gyrocopter"="carry"
    "invoker"="mid"; "lina"="mid"; "shadow_fiend"="mid"; "sniper"="mid"; "storm_spirit"="mid"
    "axe"="offlane"; "dragon_knight"="offlane"; "bristleback"="offlane"
    "tidehunter"="offlane"; "earthshaker"="offlane"; "pudge"="offlane"; "centaur"="offlane"
    "crystal_maiden"="support"; "lion"="support"; "rubick"="support"
    "enigma"="support"; "witch_doctor"="support"; "shadow_shaman"="support"
}

# Expected GPM by role at game time (rough benchmarks)
function Get-ExpectedGPM($heroRaw, $clockSecs) {
    $key  = $heroRaw -replace "npc_dota_hero_",""
    $role = if ($heroRoles.ContainsKey($key)) { $heroRoles[$key] } else { "carry" }
    $mins = $clockSecs / 60
    switch ($role) {
        "carry"   { return [int][math]::Min(700, 200 + $mins * 18) }
        "mid"     { return [int][math]::Min(620, 180 + $mins * 15) }
        "offlane" { return [int][math]::Min(520, 150 + $mins * 12) }
        "support" { return [int][math]::Min(320,  90 + $mins *  7) }
        default   { return [int][math]::Min(600, 180 + $mins * 15) }
    }
}

$heroBuilds = @{
    "weaver"           = @("aghanims_scepter","sphere","manta","skadi","butterfly","monkey_king_bar")
    "antimage"         = @("battlefury","manta","abyssal_blade","skadi","butterfly")
    "juggernaut"       = @("battlefury","manta","aghanims_scepter","basher","butterfly")
    "invoker"          = @("blink","aghanims_scepter","octarine_core","refresher")
    "pudge"            = @("blink","aghanims_scepter","heart","black_king_bar")
    "phantom_assassin" = @("battlefury","desolator","abyssal_blade","butterfly","moonshard")
    "faceless_void"    = @("maelstrom","manta","black_king_bar","mjollnir","butterfly")
    "drow_ranger"      = @("dragon_lance","hurricane_pike","manta","butterfly","aghanims_scepter")
    "luna"             = @("manta","butterfly","aghanims_scepter","skadi")
    "sniper"           = @("maelstrom","hurricane_pike","aghanims_scepter","butterfly","monkey_king_bar")
    "axe"              = @("blink","blade_mail","heart","black_king_bar","crimson_guard")
    "dragon_knight"    = @("blink","aghanims_scepter","black_king_bar","heart","assault")
    "crystal_maiden"   = @("blink","aghanims_scepter","glimmer_cape","refresher")
    "lion"             = @("blink","aghanims_scepter","aether_lens","glimmer_cape")
    "rubick"           = @("blink","aether_lens","aghanims_scepter","force_staff")
    "bristleback"      = @("blade_mail","crimson_guard","aghanims_scepter","heart","assault")
    "ursa"             = @("blink","abyssal_blade","black_king_bar","aghanims_scepter","butterfly")
    "lina"             = @("blink","aghanims_scepter","bloodthorn","sheepstick")
    "shadow_fiend"     = @("blink","aghanims_scepter","bloodthorn","butterfly","skadi")
    "terrorblade"      = @("manta","skadi","butterfly","aghanims_scepter","monkey_king_bar")
    "medusa"           = @("manta","skadi","butterfly","aghanims_scepter","monkey_king_bar")
    "spectre"          = @("radiance","manta","aghanims_scepter","heart","butterfly")
    "earthshaker"      = @("blink","aghanims_scepter","black_king_bar","heart")
    "tidehunter"       = @("blink","aghanims_scepter","heart","crimson_guard","assault")
    "enigma"           = @("blink","black_king_bar","aghanims_scepter","refresher")
    "witch_doctor"     = @("aghanims_scepter","glimmer_cape","blink","aether_lens")
}

$itemDisplay = @{
    "aghanims_scepter"="Aghanim Scepter|4200"; "sphere"="Linken Sphere|4600"
    "manta"="Manta Style|4100"; "skadi"="Eye of Skadi|5450"; "butterfly"="Butterfly|4975"
    "monkey_king_bar"="MKB|5050"; "black_king_bar"="BKB|4050"; "blink"="Blink Dagger|2250"
    "battlefury"="Battle Fury|4100"; "desolator"="Desolator|3500"; "basher"="Skull Basher|2875"
    "abyssal_blade"="Abyssal Blade|6250"; "refresher"="Refresher Orb|5000"; "heart"="Heart|5000"
    "blade_mail"="Blade Mail|2200"; "crimson_guard"="Crimson Guard|3525"; "assault"="Assault Cuirass|5250"
    "maelstrom"="Maelstrom|3000"; "mjollnir"="Mjollnir|5600"; "hurricane_pike"="Hurricane Pike|4200"
    "dragon_lance"="Dragon Lance|1900"; "aether_lens"="Aether Lens|2275"; "glimmer_cape"="Glimmer Cape|1950"
    "force_staff"="Force Staff|2250"; "octarine_core"="Octarine Core|4700"; "sheepstick"="Hex|5175"
    "bloodthorn"="Bloodthorn|6800"; "radiance"="Radiance|5050"; "moonshard"="Moon Shard|4000"
}

$enemySituational = @{
    "ENIGMA"="BKB (4050g)|Black Hole deletes you - BKB breaks it"
    "FACELESS VOID"="BKB (4050g)|Chronosphere locks you - BKB breaks out"
    "SILENCER"="BKB (4050g)|Global Silence shuts you off"
    "LION"="BKB or Linken (4050g)|Hex + Finger combo kills in 1 second"
    "LINA"="BKB (4050g)|Lina burst will kill you before you react"
    "PHANTOM ASSASSIN"="MKB (5050g)|PA has 50% evasion - MKB cuts through"
    "PHANTOM LANCER"="MKB (5050g)|Illusions need MKB to clear cleanly"
    "NAGA SIREN"="MKB (5050g)|Illusions need MKB to clear cleanly"
    "ANTI MAGE"="Linken Sphere (4600g)|Mana Void targets isolated heroes"
    "INVOKER"="BKB (4050g)|Invoker combo bursts without magic immunity"
    "BLOODSEEKER"="TP Scroll always|Rupture kills if you move - TP out"
}

$heroSynergy = @{
    "weaver"="LION,SHADOW SHAMAN,EARTHSHAKER,RUBICK,CLOCKWERK"
    "antimage"="EARTHSHAKER,ENIGMA,CRYSTAL MAIDEN,NAGA SIREN"
    "juggernaut"="CRYSTAL MAIDEN,LION,EARTHSHAKER,SHADOW SHAMAN"
    "invoker"="PUCK,ENIGMA,EARTHSHAKER,LESHRAC,SHADOW DEMON"
    "pudge"="LION,NYX ASSASSIN,SHADOW SHAMAN,CLOCKWERK"
    "phantom_assassin"="MAGNUS,EARTHSHAKER,SHADOW DEMON,LION"
    "faceless_void"="CRYSTAL MAIDEN,SHADOW SHAMAN,LION,WITCH DOCTOR"
    "drow_ranger"="CRYSTAL MAIDEN,EARTHSHAKER,MAGNUS,SHADOW SHAMAN"
    "luna"="LION,SHADOW SHAMAN,EARTHSHAKER,MAGNUS"
    "sniper"="CRYSTAL MAIDEN,LION,SHADOW SHAMAN,SKYWRATH MAGE"
    "axe"="CRYSTAL MAIDEN,LION,SHADOW SHAMAN,LINA"
    "ursa"="SHADOW SHAMAN,LION,EARTHSHAKER,CRYSTAL MAIDEN"
    "terrorblade"="SHADOW DEMON,CRYSTAL MAIDEN,EARTHSHAKER,MAGNUS"
    "spectre"="CRYSTAL MAIDEN,LION,SHADOW SHAMAN,WITCH DOCTOR"
}

function Get-SynergyPartners($heroRaw, $allies) {
    $key = $heroRaw -replace "npc_dota_hero_",""
    if (-not $heroSynergy.ContainsKey($key)) { return @() }
    $ideal = $heroSynergy[$key] -split ","
    return $allies | Where-Object { $_ -in $ideal }
}

function Get-ItemPoints($heroRaw, $enemies, $currentItems, $gold) {
    $heroKey = $heroRaw -replace "npc_dota_hero_",""
    $points  = @()
    $count   = 0
    if ($heroBuilds.ContainsKey($heroKey)) {
        foreach ($item in $heroBuilds[$heroKey]) {
            if ($count -ge 3) { break }
            if ($item -notin $currentItems -and $itemDisplay.ContainsKey($item)) {
                $parts  = $itemDisplay[$item] -split "\|"
                $cost   = [int]$parts[1]
                $afford = if ($gold -ge $cost) { "BUY NOW" } else { "$($cost - $gold)g away" }
                $points += "Core $($count+1): $($parts[0]) ($($cost)g) - $afford"
                $count++
            }
        }
    }
    foreach ($enemy in $enemies) {
        if ($enemySituational.ContainsKey($enemy)) {
            $parts = $enemySituational[$enemy] -split "\|"
            $points += ("vs " + $enemy + ": Buy " + $parts[0] + " - " + $parts[1])
            break
        }
    }
    return $points
}

# Power items that signal "stop farming, group up"
$powerItems = @("blink","black_king_bar","aghanims_scepter","manta","butterfly","skadi","refresher","abyssal_blade")

# Roshan contest windows (clock seconds)
$roshanWindows = @(480, 1200, 1800, 2400)

# Time triggers
$timeTriggers = @(
    @{ t=0;    h="Laning starts";       m="CS wins lanes. Only trade if completely free." }
    @{ t=180;  h="3 min - Bounties";    m="Secure bounty runes. Every 80g matters early." }
    @{ t=360;  h="6 min - Runes up";    m="Power and bounty runes spawning. Contest river now." }
    @{ t=420;  h="7 min";               m="Winning lane? Rotate and kill. Do not just farm." }
    @{ t=600;  h="10 min";              m="Tier 1 pressure. Stop trading, start pushing." }
    @{ t=720;  h="12 min";              m="Mid game. Wards, rotations, objectives." }
    @{ t=900;  h="15 min";              m="Check core item. Not there yet? Farm safely, no 5v5." }
    @{ t=1200; h="20 min - ACT";        m="Stop farming. Take Rosh or a tower. Force it." }
    @{ t=1500; h="25 min - Group up";   m="Stop split farming. Move as a unit." }
    @{ t=1800; h="30 min";              m="Commit to a win condition. Stop floating." }
    @{ t=2400; h="40 min";              m="Play for pickoffs before high ground. One bad fight = lost game." }
)

# ── State ─────────────────────────────────────────────────────────────────────
$prev = @{
    gameState        = ""
    deaths           = -1
    kills            = -1
    assists          = -1
    level            = 0
    alive            = $true
    hpRaw            = 0
    hpMax            = 1
    lowHpFired       = $false
    inFightFired     = $false
    ultWasOnCD       = $false
    ultReadyFired    = $false
    enemyShown       = $false
    synergyShown     = $false
    lastStrategicClock = -999
    lastFightAlert   = 0
    lastGPMClock     = -999
    lastPresenceClock = -999
    lastRoshClock    = -999
    buildingHP       = @{}
    firedTriggers    = [System.Collections.Generic.HashSet[int]]::new()
    firedRosh        = [System.Collections.Generic.HashSet[int]]::new()
}
$keyLevels = @(6, 11, 16, 20, 25)
$startTime = [datetime]::Now

Write-Host "Dota Notifier v3 | fast:${fastPoll}s | strategic:every 3 game-min | Ctrl+C to stop" -ForegroundColor Green

# ── Main loop ─────────────────────────────────────────────────────────────────
while ($true) {
    Start-Sleep -Seconds $fastPoll

    if (-not (Test-Path $stateFile)) { continue }
    try { $s = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }

    $map    = $s.map
    $hero   = $s.hero
    $player = $s.player
    if (-not $map -or -not $hero -or -not $player) { continue }

    $gameState = $map.game_state
    $clock     = [int]$map.clock_time
    $active    = $gameState -eq "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS"
    $heroName  = Get-HeroName $hero.name
    $enemies   = Get-EnemyHeroes $s
    $allies    = Get-AlliedHeroes $s
    $partners  = Get-SynergyPartners $hero.name $allies

    # ── Game start ────────────────────────────────────────────────────────────
    if ($gameState -in @("DOTA_GAMERULES_STATE_PRE_GAME","DOTA_GAMERULES_STATE_GAME_IN_PROGRESS") `
        -and $prev.gameState -notin @("DOTA_GAMERULES_STATE_PRE_GAME","DOTA_GAMERULES_STATE_GAME_IN_PROGRESS")) {
        foreach ($k in @("deaths","kills","assists","level","hpRaw","lastStrategicClock","lastFightAlert","lastGPMClock","lastPresenceClock","lastRoshClock")) { $prev[$k] = 0 }
        $prev.alive = $true; $prev.lowHpFired = $false; $prev.inFightFired = $false
        $prev.ultWasOnCD = $false; $prev.enemyShown = $false; $prev.synergyShown = $false
        $prev.firedTriggers.Clear(); $prev.firedRosh.Clear(); $prev.hpMax = 1; $prev.buildingHP = @{}
        $prev.kills = $player.kills; $prev.deaths = $player.deaths; $prev.assists = $player.assists
        Print-Block "Game live - $heroName" @(
            "Focus on CS in early laning - it determines your item timing"
            "Only trade if it is completely free"
            "Keep a TP scroll at all times"
        )
    }

    # ── Enemy + synergy (once per game) ──────────────────────────────────────
    if ($active -and -not $prev.enemyShown -and $enemies.Count -gt 0) {
        $itemPoints = Get-ItemPoints $hero.name $enemies @() $player.gold
        Print-Block "Enemy team" (@($enemies -join ", ") + $itemPoints)
        $prev.enemyShown = $true
    }
    if ($active -and -not $prev.synergyShown -and $partners.Count -gt 0) {
        Print-Block "Best roaming partners on your team" @(
            "Roam with: " + ($partners -join ", ")
            "Coordinate ganks with them after laning phase"
            "Ping them when your ult is ready for a kill"
        )
        $prev.synergyShown = $true
    }

    # ── Game end ──────────────────────────────────────────────────────────────
    if ($gameState -eq "DOTA_GAMERULES_STATE_POST_GAME" -and $prev.gameState -eq "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS") {
        $outcome = if ($player.win -eq 1) { "VICTORY" } else { "DEFEAT" }
        Print-Block ("$heroName - $outcome") @(
            "K/D/A: $($player.kills)/$($player.deaths)/$($player.assists)"
            "GPM: $($player.gold_per_min) | XPM: $($player.xp_per_min)"
        ) -critical
    }

    if (-not $active) { $prev.gameState = $gameState; continue }

    $currentItems = Get-CurrentItems $s
    $hpPct        = if ($hero.max_health -gt 0) { $hero.health / $hero.max_health } else { 1 }
    $manaPct      = if ($hero.max_mana -gt 0) { $hero.mana / $hero.max_mana } else { 0 }
    $clockMins    = $clock / 60

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # FAST CHECKS (every 8s) — combat detection
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    # Fight detection via HP trend
    if ($prev.hpMax -gt 0 -and $hero.alive -and $prev.alive) {
        $hpDrop    = $prev.hpRaw - $hero.health
        $hpDropPct = if ($prev.hpMax -gt 0) { $hpDrop / $prev.hpMax } else { 0 }
        if ($hpDropPct -gt 0.35 -and $prev.lastFightAlert -lt ([datetime]::Now.AddSeconds(-30).Ticks)) {
            $threat  = if ($enemies.Count -gt 0) { $enemies[0] } else { "enemy" }
            Print-Block "TAKING HEAVY DAMAGE - DECIDE NOW" @(
                "HP dropped $([math]::Round($hpDropPct*100))% - $threat is on you"
                "Fight back if you have ult + mana, else GET OUT"
                "Use mobility item: blink, manta, or force staff"
            ) -critical
            $prev.lastFightAlert = [datetime]::Now.Ticks
        } elseif ($hpDropPct -gt 0.15 -and $prev.lastFightAlert -lt ([datetime]::Now.AddSeconds(-60).Ticks)) {
            $threat = if ($enemies.Count -gt 0) { $enemies[0] } else { "enemy" }
            Print-Block "YOU ARE IN A FIGHT" @(
                "HP dropping fast - $threat nearby"
                if ($manaPct -gt 0.5) { "You have mana - use ult and fight" } else { "Low mana - play safe or run" }
                if ($partners.Count -gt 0) { "Ping " + $partners[0] + " for backup" } else { "Call for team help" }
            ) -critical
            $prev.lastFightAlert = [datetime]::Now.Ticks
        }
    }
    $prev.hpRaw = $hero.health
    $prev.hpMax = $hero.max_health

    # Tower / building tracking
    if ($s.buildings -and $player) {
        $myTeamKey    = if ($player.team_name -eq "radiant") { "radiant" } else { "dire" }
        $enemyTeamKey = if ($player.team_name -eq "radiant") { "dire" } else { "radiant" }
        $myBuildings  = $s.buildings.$myTeamKey
        $enemyBuildings = $s.buildings.$enemyTeamKey
        foreach ($side in @(@{data=$myBuildings;friendly=$true}, @{data=$enemyBuildings;friendly=$false})) {
            if (-not $side.data) { continue }
            $side.data.PSObject.Properties | ForEach-Object {
                $bName = $_.Name
                $bHP   = $_.Value.health
                $bMax  = $_.Value.max_health
                $prevHP = $prev.buildingHP[$bName]
                if ($null -ne $prevHP -and $bMax -gt 0) {
                    $drop = ($prevHP - $bHP) / $bMax
                    $label = $bName -replace "dota_(goodguys|badguys)_","" -replace "good_|bad_","" -replace "_"," "
                    if ($side.friendly) {
                        if ($bHP -eq 0 -and $prevHP -gt 0) {
                            Print-Block "YOUR $($label.ToUpper()) LOST" @(
                                "Regroup and defend - do not let them push further"
                                "Trade objectives: push an enemy tower while they celebrate"
                                "Buy back if you are dead and this is a critical fight"
                            ) -critical
                        } elseif ($drop -gt 0.25) {
                            Print-Block "YOUR $($label.ToUpper()) UNDER ATTACK" @(
                                "Get to the tower NOW or lose it"
                                if ($partners.Count -gt 0) { "Bring " + $partners[0] + " with you" } else { "Go as a team" }
                            ) -critical
                        }
                    } else {
                        if ($bHP -eq 0 -and $prevHP -gt 0) {
                            Print-Block "ENEMY $($label.ToUpper()) DESTROYED" @(
                                "Push the next tower immediately while they are on the back foot"
                                "Set up vision and look for a pick"
                                "Consider Roshan if the lane is open"
                            )
                        } elseif ($drop -gt 0.3) {
                            Print-Block "ENEMY $($label.ToUpper()) LOW - PUSH IT" @(
                                "Get on that tower and destroy it"
                                "Do not let the momentum slip"
                            )
                        }
                    }
                }
                $prev.buildingHP[$bName] = $bHP
            }
        }
    }

    # Kill
    if ($prev.kills -ge 0 -and $player.kills -gt $prev.kills) {
        $itemPoints = Get-ItemPoints $hero.name $enemies $currentItems $player.gold
        $roamTip    = if ($partners.Count -gt 0) { "Rotate with " + $partners[0] + " for the next kill" } else { "Rotate to nearest lane" }
        Print-Block ("KILL! $heroName K:$($player.kills)") (@(
            "Push the advantage now - do not back off"
            "Check Roshan - if it is up take it immediately"
            $roamTip
        ) + $itemPoints) -critical
    }
    $prev.kills = $player.kills

    # Assist
    if ($prev.assists -ge 0 -and $player.assists -gt $prev.assists) {
        $roamTip = if ($partners.Count -gt 0) { "Stay with " + $partners[0] + " and repeat" } else { "Stay with your team" }
        Print-Block ("ASSIST! A:$($player.assists)") @(
            $roamTip
            "Push the wave or take the tower now"
            "Ward the area to control the next fight"
        ) -critical
    }
    $prev.assists = $player.assists

    # Death
    if ($prev.deaths -ge 0 -and $player.deaths -gt $prev.deaths) {
        $canBB   = $player.gold -ge $player.buyback_cost
        $bbPoint = if ($canBB) { "BUYBACK READY ($($player.gold)g) - use if fight is game-critical" } `
                   else { "No buyback. $($player.gold)g of $($player.buyback_cost)g. Sit it out." }
        $itemPoints = Get-ItemPoints $hero.name $enemies $currentItems $player.gold
        Print-Block ("$heroName DIED D:$($player.deaths)") (@(
            $bbPoint
            "Identify why you died and avoid that position"
            "Use respawn time to plan your next rotation"
        ) + $itemPoints) -critical
        $prev.lowHpFired = $false
        $prev.inFightFired = $false
    }
    $prev.deaths = $player.deaths

    # Respawn
    if (-not $prev.alive -and $hero.alive) {
        $roamTip = if ($partners.Count -gt 0) { "Regroup with " + $partners[0] + " before engaging" } else { "Regroup with team before committing" }
        Print-Block "$heroName respawned" @(
            $roamTip
            "Check the map before moving - enemies will be hunting you"
        )
        $prev.lowHpFired = $false
    }
    $prev.alive = [bool]$hero.alive

    if ($hero.alive) {

        # Level milestones
        if ($hero.level -gt $prev.level -and $hero.level -in $keyLevels) {
            $tips = @{6="ULT ONLINE - this is your kill window. Find it NOW."; 11="Ult level 2. Rotate and stop farming."; 16="Ult maxed. Group and teamfight."; 20="Pick level 20 talent then force a fight."; 25="Max level. End the game."}
            $roamLine = if ($partners.Count -gt 0) { "Roam with " + ($partners[0..([math]::Min(1,$partners.Count-1))] -join " or ") + " for kills" } else { "" }
            $allPoints = @($tips[$hero.level]) + (Get-ItemPoints $hero.name $enemies $currentItems $player.gold)
            if ($roamLine) { $allPoints += $roamLine }
            Print-Block ("$heroName Level $($hero.level)!") $allPoints -critical
        }
        $prev.level = $hero.level

        # Ult ready + mana check = fight signal
        $ult = Get-UltAbility $s
        if ($ult) {
            $ultReady = ($ult.cooldown -eq 0 -and $ult.can_use -eq $true)
            if ($ultReady -and $prev.ultWasOnCD) {
                $engage = if ($manaPct -gt 0.5 -and $clockMins -gt 7) {
                    "ULT + MANA READY - this is your window. Find the fight NOW."
                } else { "Ult ready. Wait for mana before committing." }
                $roamTip = if ($partners.Count -gt 0) { "Link up with " + $partners[0] + " to engage" } else { "Find the right position." }
                Print-Block "$heroName ult back up" @( $engage; $roamTip ) -critical
            }
            $prev.ultWasOnCD = -not $ultReady
        }

        # Low HP
        if ($hpPct -lt 0.2 -and -not $prev.lowHpFired) {
            $threat = if ($enemies.Count -gt 0) { $enemies[0] + " will finish you" } else { "you are exposed" }
            Print-Block ("$heroName LOW HP $([math]::Round($hpPct*100))%") @(
                "GET OUT NOW - $threat"
                "Use mobility items to escape - blink or manta"
                "Do NOT fight until you recover to 50%+"
            ) -critical
            $prev.lowHpFired = $true
        }
        if ($hpPct -gt 0.5) { $prev.lowHpFired = $false }
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # SLOW CHECKS (every 3 game-minutes) — strategic advice
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    $doStrategic = ($clock - $prev.lastStrategicClock) -ge $strategicInterval

    if ($doStrategic) {

        # Time triggers
        foreach ($trigger in $timeTriggers) {
            if ($clock -ge $trigger.t -and -not $prev.firedTriggers.Contains($trigger.t)) {
                $itemPoints = Get-ItemPoints $hero.name $enemies $currentItems $player.gold
                Print-Block $trigger.h (@($trigger.m) + $itemPoints)
                $prev.firedTriggers.Add($trigger.t) | Out-Null
            }
        }

        # Farm efficiency
        if ($clock -gt 300 -and ($clock - $prev.lastGPMClock) -ge $strategicInterval) {
            $actualGPM   = $player.gold_per_min
            $expectedGPM = Get-ExpectedGPM $hero.name $clock
            $gpmDiff     = $actualGPM - $expectedGPM
            if ($gpmDiff -lt -80) {
                Print-Block "Farm efficiency WARNING" @(
                    "Your GPM: $actualGPM | Expected for $heroName at $([math]::Round($clockMins))min: $expectedGPM"
                    "You are $([math]::Abs($gpmDiff)) GPM behind - stack camps or rotate to richer areas"
                    "Avoid low-value fights until your item timing is back on track"
                )
            } elseif ($gpmDiff -gt 50) {
                Print-Block "Farm efficiency GOOD" @(
                    "GPM $actualGPM vs expected $expectedGPM - you are ahead"
                    "Consider converting farm lead into fight aggression"
                )
            }
            $prev.lastGPMClock = $clock
        }

        # Team presence signal
        if ($clock -gt 600 -and ($clock - $prev.lastPresenceClock) -ge $strategicInterval) {
            $hasPowerItem = $currentItems | Where-Object { $_ -in $powerItems }
            $points = @()
            if ($clockMins -gt 25) {
                $points += "You are past 25 min - ALWAYS be with your team from now on"
                $points += "Solo farming at this point loses games"
            } elseif ($hasPowerItem -and $clockMins -gt 15) {
                $points += "You have $($hasPowerItem[0]) - stop farming and group up"
                $points += "Your power item is only useful in fights, not in the jungle"
            }
            if ($partners.Count -gt 0) { $points += "Best to group with: " + ($partners -join ", ") }
            if ($points.Count -gt 0) { Print-Block "Team presence" $points }
            $prev.lastPresenceClock = $clock
        }

        # Roshan windows
        foreach ($roshT in $roshanWindows) {
            if ($clock -ge ($roshT - 60) -and $clock -le ($roshT + 120) -and -not $prev.firedRosh.Contains($roshT)) {
                $mins = [math]::Round($roshT / 60)
                Print-Block "ROSHAN WINDOW (~$mins min)" @(
                    "Roshan is likely available - contest it now"
                    "Aegis gives a free death - invaluable for forcing high ground"
                    if ($partners.Count -gt 0) { "Bring " + $partners[0] + " for the fight" } else { "Go as a team, not alone" }
                )
                $prev.firedRosh.Add($roshT) | Out-Null
            }
        }

        # Item advice
        $itemPoints = Get-ItemPoints $hero.name $enemies $currentItems $player.gold
        if ($itemPoints.Count -gt 0) { Print-Block "Item advice" $itemPoints }

        $prev.lastStrategicClock = $clock
    }

    $prev.gameState = $gameState
}
