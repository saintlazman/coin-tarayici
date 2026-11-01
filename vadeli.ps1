function FuturesApi([string]$path) {
    Invoke-RestMethod -Uri ('https://fapi.binance.com/' + $path) -TimeoutSec 15
}
function OiChanges($history, [long]$target) {
    $points = @{}
    foreach ($p in $history) { $points[[long]$p.timestamp] = $p }
    foreach ($t in @($target, ($target-3600000), ($target-14400000))) {
        if (-not $points.ContainsKey([long]$t)) { throw 'OI zamanlari eksik/eski; spot kapanisiyla eslesmedi' }
        if ((Num $points[[long]$t].sumOpenInterest) -le 0) { throw 'Gecersiz OI miktari' }
    }
    $latest = Num $points[$target].sumOpenInterest
    [pscustomobject]@{
        OI1sYuzde = [math]::Round(($latest / (Num $points[($target-3600000)].sumOpenInterest) - 1) * 100, 3)
        OI4sYuzde = [math]::Round(($latest / (Num $points[($target-14400000)].sumOpenInterest) - 1) * 100, 3)
        OIMiktar = $latest
        OIZaman = [DateTimeOffset]::FromUnixTimeMilliseconds($target).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm zzz')
    }
}
function EnrichFutures($candidates, [long]$target) {
    if (-not $candidates.Count) { return }
    $contracts = @{}; $exchangeError = $null
    try {
        $exchange = FuturesApi 'fapi/v1/exchangeInfo'
        foreach ($s in $exchange.symbols) {
            if ($s.status -eq 'TRADING' -and $s.contractType -eq 'PERPETUAL' -and $s.quoteAsset -eq 'USDT') { $contracts[$s.symbol] = $true }
        }
    } catch { $exchangeError = $_.Exception.Message }
    foreach ($c in $candidates) {
        $extra = [ordered]@{OI1sYuzde=$null; OI4sYuzde=$null; OIMiktar=$null; OIZaman=$null; OIDurum='VERI_YOK'; OIYorum=''; FonlamaYuzde=$null; FonlamaZaman=$null; SonrakiFonlama=$null; FonlamaDurum='VERI_YOK'; VadeliHata=''}
        $problems = @()
        if ($exchangeError) { $problems += "Vadeli baglanti: $exchangeError" }
        elseif (-not $contracts.ContainsKey($c.Coin)) {
            $extra.OIDurum = 'ESLESEN_KONTRAT_YOK'; $extra.FonlamaDurum = 'ESLESEN_KONTRAT_YOK'
        } else {
            try {
                $hist = FuturesApi "futures/data/openInterestHist?symbol=$($c.Coin)&period=1h&limit=8&endTime=$target"
                $change = OiChanges $hist $target
                foreach($p in $change.PSObject.Properties){ $extra[$p.Name] = $p.Value }
                $extra.OIDurum = 'TAM'
                if ($c.Getiri4s -gt 0 -and $change.OI4sYuzde -gt 0) { $extra.OIYorum = 'Fiyat ve OI artiyor' }
                elseif ($c.Getiri4s -gt 0 -and $change.OI4sYuzde -lt 0) { $extra.OIYorum = 'Fiyat artiyor; OI azaliyor' }
                elseif ($c.Getiri4s -lt 0 -and $change.OI4sYuzde -gt 0) { $extra.OIYorum = 'Fiyat dusuyor; OI artiyor' }
                elseif ($c.Getiri4s -lt 0 -and $change.OI4sYuzde -lt 0) { $extra.OIYorum = 'Fiyat ve OI azaliyor' }
                else { $extra.OIYorum = 'Fiyat veya OI yatay' }
            } catch { $problems += "OI: $($_.Exception.Message)" }
            try {
                $f = FuturesApi "fapi/v1/premiumIndex?symbol=$($c.Coin)"
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if ($null -eq $f.lastFundingRate -or $f.symbol -ne $c.Coin -or [math]::Abs($now - [long]$f.time) -gt 300000) { throw 'Fonlama verisi eksik/eski' }
                $extra.FonlamaYuzde = [math]::Round((Num $f.lastFundingRate) * 100, 5)
                $extra.FonlamaZaman = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$f.time).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm zzz')
                $extra.SonrakiFonlama = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$f.nextFundingTime).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm zzz')
                $extra.FonlamaDurum = 'TAM'
            } catch { $problems += "Fonlama: $($_.Exception.Message)" }
        }
        $extra.VadeliHata = $problems -join '; '
        foreach($key in $extra.Keys){ $c | Add-Member -NotePropertyName $key -NotePropertyValue $extra[$key] -Force }
    }
}
