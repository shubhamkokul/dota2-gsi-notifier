# Dota 2 GSI Listener
# Receives HTTP POST requests from Dota 2's Game State Integration system.
# Writes the full raw JSON to dota_state.json so dota-notifier.ps1 can read it.
#
# Run this FIRST, before starting dota-notifier.ps1.
# Keep it running for the entire session — if it stops, the notifier gets stale data.

$port       = 49152                          # must match uri in gamestate_integration_claude.cfg
$outputFile = "$PSScriptRoot\dota_state.json"

# Change-tracking — only log to console when something meaningful shifts.
# Avoids spamming a new line every second during quiet stretches.
$script:lastKDA      = ""
$script:lastGoldBand = -1   # changes every 500g
$script:lastHpBand   = -1   # changes every 20% HP

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

Write-Host "Dota 2 GSI listener started on port $port" -ForegroundColor Green
Write-Host "State file: $outputFile" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop.`n"

try {
    while ($listener.IsListening) {
        # Blocks here until Dota 2 sends the next POST
        $context = $listener.GetContext()
        $request = $context.Request

        if ($request.HttpMethod -eq "POST") {
            $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
            $body   = $reader.ReadToEnd()
            $reader.Close()

            # Write the full JSON payload — notifier reads this file on every cycle
            $body | Out-File -FilePath $outputFile -Encoding utf8 -Force

            # Parse and log a condensed one-liner per tick, but only when something changed.
            # Checking bands (500g, 20% HP) instead of exact values avoids a log line every second.
            try {
                $state = $body | ConvertFrom-Json

                $t    = if ($state.map) { $state.map.clock_time } else { 0 }
                $mins = [math]::Floor([math]::Abs($t) / 60)
                $secs = [math]::Abs($t) % 60
                $tStr = ($(if ($t -lt 0) { "-" } else { "" })) + ("{0}:{1:D2}" -f $mins, $secs)

                $hero = if ($state.hero) {
                    (($state.hero.name -replace "npc_dota_hero_","") -replace "_"," ").ToUpper()
                } else { "NO HERO" }

                $hp   = if ($state.hero -and $state.hero.max_health -gt 0) {
                    [math]::Round($state.hero.health / $state.hero.max_health * 100)
                } else { 0 }

                $mp   = if ($state.hero -and $state.hero.max_mana -gt 0) {
                    [math]::Round($state.hero.mana / $state.hero.max_mana * 100)
                } else { 0 }

                $kda  = if ($state.player) {
                    "$($state.player.kills)/$($state.player.deaths)/$($state.player.assists)"
                } else { "-/-/-" }

                $gold = if ($state.player) { $state.player.gold } else { 0 }

                $gs       = if ($state.map) { $state.map.game_state } else { "" }
                $goldBand = [math]::Floor($gold / 500)
                $hpBand   = [math]::Floor($hp   / 20)

                $changed = ($kda -ne $script:lastKDA) -or ($goldBand -ne $script:lastGoldBand) -or ($hpBand -ne $script:lastHpBand)

                if ($changed -and $state.hero -and $gs -in @("DOTA_GAMERULES_STATE_PRE_GAME","DOTA_GAMERULES_STATE_GAME_IN_PROGRESS")) {
                    Write-Host ("[$([datetime]::Now.ToString('HH:mm:ss'))] $tStr | $hero HP:$hp% | KDA:$kda | $($gold)g")
                    $script:lastKDA      = $kda
                    $script:lastGoldBand = $goldBand
                    $script:lastHpBand   = $hpBand
                }
            } catch { }
        }

        # Always respond 200 OK — Dota 2 will back off or stop sending if it gets errors
        $response            = $context.Response
        $response.StatusCode = 200
        $response.Close()
    }
} finally {
    $listener.Stop()
    if (Test-Path $outputFile) {
        Remove-Item $outputFile -Force
        Write-Host "State file deleted." -ForegroundColor DarkGray
    }
    Write-Host "Listener stopped."
}
