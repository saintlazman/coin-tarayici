param([switch]$Notify)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
. (Join-Path $root 'vadeli.ps1')
$data = Join-Path $root 'kayitlar'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\OsmanCoinScannerV1')
if (-not $mutex.WaitOne(0)) { exit 0 }
function Api([string]$path) {
    Invoke-RestMethod -Uri ('https://data-api.binance.vision/api/v3/' + $path) -TimeoutSec 20
}
function Num($v) { [double]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) }
function Bars([string]$symbol) {
    $raw = Api "klines?symbol=$symbol&interval=1h&limit=80&endTime=$script:cutoff"
    $bars = @($raw | Where-Object { [long]$_[6] -le $script:cutoff })
    if ($bars.Count -lt 49 -or [long]$bars[-1][6] -ne $script:cutoff) { throw 'Eksik veya eski mum verisi' }
    for ($i=1; $i -lt $bars.Count; $i++) {
        if (([long]$bars[$i][0] - [long]$bars[$i-1][0]) -ne 3600000) { throw 'Mumlar arasinda bosluk var' }
    }
    return ,$bars
}
try {
    $server = [long](Api 'time').serverTime
    $script:cutoff = $server - ($server % 3600000) - 1
    $stamp = [DateTimeOffset]::FromUnixTimeMilliseconds($server).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $exchange = Api 'exchangeInfo'
    $allowed = @{}
    $watchlist = @('ETHUSDT','ENAUSDT','UNIUSDT','ONDOUSDT','AAVEUSDT','BTCUSDT','TAOUSDT','LDOUSDT','ETHFIUSDT','PEPEUSDT','ASTERUSDT','SYRUPUSDT')
    $excluded = @('USDC','FDUSD','TUSD','USDP','DAI','USDD','USD1','USDE','BUSD','PAXG','XAUT','EUR','EURI','AEUR')
    foreach ($s in $exchange.symbols) {
        if ($s.status -eq 'TRADING' -and $s.quoteAsset -eq 'USDT' -and $s.isSpotTradingAllowed -and $s.baseAsset -notin $excluded -and $s.symbol -in $watchlist) { $allowed[$s.symbol] = $true }
    }
    $tickers = Api 'ticker/24hr'
    $universe = @($tickers | Where-Object { $allowed.ContainsKey($_.symbol) } | Sort-Object { Num $_.quoteVolume } -Descending | Select-Object -First 60)
    if ($universe.Count -eq 0) { throw 'Tarama evreni bos' }
    $btc = Bars 'BTCUSDT'
    $btc4 = ((Num $btc[-1][4]) / (Num $btc[-5][4]) - 1) * 100
    $rows = @(); $errors = @()
    foreach ($symbol in $watchlist) { if ($symbol -notin @($universe.symbol)) { $errors += ($symbol + ': Spot USDT verisi bulunamadi') } }
    foreach ($ticker in $universe) {
        try {
            $b = Bars $ticker.symbol
            $last = $b[-1]; $price = Num $last[4]
            $r1 = ($price / (Num $b[-2][4]) - 1) * 100
            $r4 = ($price / (Num $b[-5][4]) - 1) * 100
            $r24 = ($price / (Num $b[-25][4]) - 1) * 100
            $avgVol = ($b[($b.Count-25)..($b.Count-2)] | ForEach-Object { Num $_[7] } | Measure-Object -Average).Average
            if ($avgVol -le 0) { throw 'Hacim hesaplanamadi' }
            $vol = (Num $last[7]) / $avgVol
            $prior = $b[($b.Count-7)..($b.Count-2)]
            $high = ($prior | ForEach-Object { Num $_[2] } | Measure-Object -Maximum).Maximum
            $low = ($prior | ForEach-Object { Num $_[3] } | Measure-Object -Minimum).Minimum
            $range = ($high / $low - 1) * 100
            $relative = $r4 - $btc4
            $signal = 'YOK'
            if ((Num $ticker.quoteVolume) -ge 10000000 -and $relative -ge 0.5 -and $vol -ge 1.5 -and $range -le 4 -and $r24 -lt 12 -and $r1 -lt 5) {
                if ($price -gt $high) { $signal = 'KIRILMA' }
                elseif ($price -ge $high * 0.99 -and $r1 -gt 0) { $signal = 'IZLE' }
            }
            $rows += [pscustomobject]@{Coin=$ticker.symbol; Sinyal=$signal; Fiyat=$price; Getiri1s=[math]::Round($r1,2); Getiri4s=[math]::Round($r4,2); Getiri24s=[math]::Round($r24,2); BTCFarki4s=[math]::Round($relative,2); HacimKati=[math]::Round($vol,2); Onceki6sAralik=[math]::Round($range,2); Esik=$high; MumKapanis=$cutoff}
        } catch { $errors += "$($ticker.symbol): $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 120
    }
    if ($rows.Count -eq 0) { throw ('Tum veri istekleri basarisiz: ' + ($errors -join '; ')) }
    $candidates = @($rows | Where-Object { $_.Sinyal -ne 'YOK' } | Sort-Object HacimKati -Descending)
    EnrichFutures $candidates ($cutoff + 1)
    $record = [ordered]@{Zaman=$stamp; Durum=$(if($errors.Count){'KISMI'}else{'TAM'}); Hedef=$universe.Count; Basarili=$rows.Count; BTCDegisim4s=$btc4; Adaylar=$candidates; Sonuclar=$rows; Hatalar=$errors}
    $json = $record | ConvertTo-Json -Depth 8
    $runName = [DateTimeOffset]::FromUnixTimeMilliseconds($server).ToString('yyyyMMdd-HHmmss')
    $json | Set-Content -Encoding UTF8 (Join-Path $data "$runName.json")
    $json | Set-Content -Encoding UTF8 (Join-Path $root 'son-durum.json')
    $candidateHtml = if ($candidates.Count) { $candidates | Select-Object Coin,Sinyal,Fiyat,Getiri1s,BTCFarki4s,HacimKati,Esik | ConvertTo-Html -Fragment | Out-String } else { '<p>Bu turda kosullari karsilayan aday yok.</p>' }
    $candidateHtml += '<h2>Adaylarin vadeli piyasa verileri</h2><p>OI degisimleri miktar bazinda yuzdedir; spot kapanis saatiyle eslesir. FonlamaYuzde, API tarafindan bildirilen son orandir; yillik veya sabit 8 saatlik oran degildir. Fonlama ayri bir guncel anlik goruntudur. Bos hucre sifir demek degildir. OI tek basina long/short yonunu gostermez; spot sinyallerini elemez.</p>'
    if ($candidates.Count) {
        $candidateHtml += ($candidates | Select-Object Coin,OI1sYuzde,OI4sYuzde,OIZaman,OIDurum,OIYorum,FonlamaYuzde,FonlamaZaman,SonrakiFonlama,FonlamaDurum,VadeliHata | ConvertTo-Html -Fragment | Out-String)
    } else { $candidateHtml += '<p>Aday olmadigi icin vadeli sorgusu yapilmadi.</p>' }
    $allHtml = $rows | Sort-Object BTCFarki4s -Descending | Select-Object Coin,Sinyal,Fiyat,Getiri1s,Getiri4s,Getiri24s,BTCFarki4s,HacimKati,Onceki6sAralik,Esik,MumKapanis | ConvertTo-Html -Fragment | Out-String
    $errorHtml = [Net.WebUtility]::HtmlEncode(($errors -join '; '))
    @"
<!doctype html><html lang="tr"><meta charset="utf-8"><meta http-equiv="refresh" content="120"><title>Coin Tarayici</title><style>body{font:16px Segoe UI;background:#101827;color:#e8edf5;max-width:1250px;margin:40px auto;padding:20px}table{border-collapse:collapse;width:100%;font-size:14px}td,th{padding:10px;border-bottom:1px solid #354258;text-align:left}th{color:#61d5c5}h1,h2{color:#61d5c5}.note{background:#233147;padding:16px}</style><h1>Saatlik coin taramasi</h1><p>Son calisma (Turkiye): $stamp | Durum: $($record.Durum) | $($rows.Count)/$($universe.Count) parite</p><p class="note">Deneysel izleme sinyalleri; basari orani henuz olculmedi. Yalnizca kapanmis saatlik mumlar. Bu sayfa son kaydi gosterir; tarih eskiyse tarayici calismiyordur.</p><h2>Adaylar</h2>$candidateHtml<h2>Taranan pariteler</h2><p>BTCFarki4s: coin ve BTC'nin 4 saatlik getirileri arasindaki yuzde puan farki. HacimKati: son saat / onceki 24 saatin ortalamasi. Esik: onceki 6 saatin en yuksek fiyati.</p>$allHtml<h2>Veri hatalari</h2><p>$errorHtml</p></html>
"@ | Set-Content -Encoding UTF8 (Join-Path $root 'rapor.html')
    $statePath = Join-Path $root 'bildirim-durumu.json'
    $old = @{}
    if (Test-Path $statePath) { $saved = Get-Content $statePath -Raw | ConvertFrom-Json; foreach($p in $saved.PSObject.Properties){$old[$p.Name]=$p.Value} }
    $fresh = @($candidates | Where-Object { $old[$_.Coin] -ne $_.Sinyal })
    # Preserve states for symbols whose fetch failed, avoiding duplicate alerts after outages.
    foreach($r in $rows){$old[$r.Coin]=$r.Sinyal}
    if ($Notify -and $fresh.Count) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.ShowBalloonTip(10000,'Coin tarayici: yeni aday',(($fresh | ForEach-Object { "$($_.Coin) $($_.Sinyal)" }) -join ', '),[Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 12
        $icon.Dispose()
    }
    if ($Notify) { $old | ConvertTo-Json | Set-Content -Encoding UTF8 $statePath }
    Write-Output "$stamp | $($record.Durum) | $($rows.Count) parite | $($candidates.Count) aday | $($errors.Count) hata"
} catch {
    $message = "$(Get-Date -Format o) | HATA | $($_.Exception.Message)"
    Add-Content -Encoding UTF8 (Join-Path $root 'hatalar.log') $message
    @{Durum='HATA'; Zaman=(Get-Date -Format o); Hata=$_.Exception.Message} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root 'son-durum.json')
    "<html><meta charset='utf-8'><h1>Tarama tamamlanamadi</h1><p>$([Net.WebUtility]::HtmlEncode($message))</p><p>Eski sonuclar kayitlar klasorunde tutuluyor.</p></html>" | Set-Content -Encoding UTF8 (Join-Path $root 'rapor.html')
    Write-Error $message
    exit 1
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
