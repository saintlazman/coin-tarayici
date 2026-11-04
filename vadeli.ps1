function FuturesApi([string]$path) {
    $r = Invoke-RestMethod -Uri ('https://www.okx.com/api/v5/' + $path) -TimeoutSec 15
    if ($r.code -ne '0') { throw "OKX $($r.code): $($r.msg)" }
    return $r
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
        $exchange = FuturesApi 'public/instruments?instType=SWAP'
        foreach ($s in $exchange.data) {
            if ($s.state -eq 'live' -and $s.settleCcy -eq 'USDT' -and $s.ctType -eq 'linear') {
                $contracts[($s.instId -replace '-USDT-SWAP$','USDT')] = $s.instId
            }
        }
    } catch { $exchangeError = $_.Exception.Message }
    foreach ($c in $candidates) {
        $extra = [ordered]@{VadeliKaynak='OKX'; VadeliKontrat=$null; OI1sYuzde=$null; OI4sYuzde=$null; OIMiktar=$null; OIZaman=$null; OIDurum='VERI_YOK'; OIYorum=''; FonlamaYuzde=$null; FonlamaZaman=$null; SonrakiFonlama=$null; FonlamaDurum='VERI_YOK'; VadeliHata=''}
        $problems = @()
        if ($exchangeError) { $problems += "OKX baglanti: $exchangeError" }
        elseif (-not $contracts.ContainsKey($c.Coin)) {
            $extra.OIDurum = 'OKX_KONTRAT_YOK'; $extra.FonlamaDurum = 'OKX_KONTRAT_YOK'
        } else {
            $id = $contracts[$c.Coin]; $extra.VadeliKontrat = $id
            try {
                $r = FuturesApi "rubik/stat/contracts/open-interest-history?instId=$id&period=1H&limit=10&end=$($target+1)"
                $hist = @($r.data | ForEach-Object { [pscustomobject]@{timestamp=[long]$_[0]; sumOpenInterest=$_[2]} })
                $change = OiChanges $hist $target
                foreach($p in $change.PSObject.Properties){ $extra[$p.Name] = $p.Value }
                $extra.OIDurum = 'TAM'
            } catch { $problems += "OI: $($_.Exception.Message)" }
            try {
                $r = FuturesApi "public/funding-rate?instId=$id"
                $f = @($r.data)[0]
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if ([string]::IsNullOrWhiteSpace($f.fundingRate) -or $f.instId -ne $id -or [math]::Abs($now - [long]$f.ts) -gt 300000 -or [long]$f.fundingTime -le $now) { throw 'Fonlama verisi eksik/eski' }
                $extra.FonlamaYuzde = [math]::Round((Num $f.fundingRate) * 100, 5)
                $extra.FonlamaZaman = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$f.ts).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm zzz')
                $extra.SonrakiFonlama = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$f.fundingTime).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm zzz')
                $extra.FonlamaDurum = 'TAM'
            } catch { $problems += "Fonlama: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 250
        }
        $extra.VadeliHata = $problems -join '; '
        foreach($key in $extra.Keys){ $c | Add-Member -NotePropertyName $key -NotePropertyValue $extra[$key] -Force }
    }
}
