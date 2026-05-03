# Dota 2 GSI Listener
# Run this before/during a Dota 2 session.
# Saves live game state to dota_state.json so Claude can read it.

$port = 49152
$outputFile = "$PSScriptRoot\dota_state.json"

$script:lastGameState = ""
$script:lastDeaths    = -1
$script:lastKDA       = ""
$script:lastGoldBand  = -1
$script:lastHpBand    = -1

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

Write-Host "Dota 2 GSI listener started on port $port" -ForegroundColor Green
Write-Host "State file: $outputFile" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop.`n"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request

        if ($request.HttpMethod -eq "POST") {
            $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            # Save raw JSON
            $body | Out-File -FilePath $outputFile -Encoding utf8 -Force

            # Condensed one-liner per tick
            try {
                $state  = $body | ConvertFrom-Json
                $t      = if ($state.map) { $state.map.clock_time } else { 0 }
                $mins   = [math]::Floor([math]::Abs($t) / 60); $secs = [math]::Abs($t) % 60
                $tStr   = ($(if ($t -lt 0) { "-" } else { "" })) + ("{0}:{1:D2}" -f $mins, $secs)
                $hero   = if ($state.hero) { (($state.hero.name -replace "npc_dota_hero_","") -replace "_"," ").ToUpper() } else { "NO HERO" }
                $hp     = if ($state.hero -and $state.hero.max_health -gt 0) { [math]::Round($state.hero.health/$state.hero.max_health*100) } else { 0 }
                $mp     = if ($state.hero -and $state.hero.max_mana -gt 0) { [math]::Round($state.hero.mana/$state.hero.max_mana*100) } else { 0 }
                $kda    = if ($state.player) { "$($state.player.kills)/$($state.player.deaths)/$($state.player.assists)" } else { "-/-/-" }
                $gold   = if ($state.player) { $state.player.gold } else { 0 }
                if ($state.hero -and $state.map -and $state.map.game_state -eq "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS") {
                    $goldBand = [math]::Floor($gold / 500)   # changes every 500g
                    $hpBand   = [math]::Floor($hp / 20)      # changes every 20% HP
                    $changed  = ($kda -ne $script:lastKDA) -or
                                ($goldBand -ne $script:lastGoldBand) -or
                                ($hpBand -ne $script:lastHpBand)
                    if ($changed) {
                        Write-Host ("[$([datetime]::Now.ToString('HH:mm:ss'))] " + $tStr + " | " + $hero + " HP:" + $hp + "% | KDA:" + $kda + " | " + $gold + "g")
                        $script:lastKDA      = $kda
                        $script:lastGoldBand = $goldBand
                        $script:lastHpBand   = $hpBand
                    }
                }
            } catch { }
        }

        # Always respond 200 OK
        $response = $context.Response
        $response.StatusCode = 200
        $response.Close()
    }
} finally {
    $listener.Stop()
    Write-Host "Listener stopped."
}
