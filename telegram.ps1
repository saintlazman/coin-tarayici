$ErrorActionPreference = 'Stop'
if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) { throw 'Telegram gizli ayarlari eksik.' }
$root = $PSScriptRoot
$report = Get-Content (Join-Path $root 'son-durum.json') -Raw | ConvertFrom-Json
if ($report.Durum -eq 'HATA') { throw 'Tarama basarisiz; eski adaylar gonderilmeyecek.' }
$path = Join-Path $root 'telegram-state.json'
$state = @{}
if (Test-Path $path) { $saved = Get-Content $path -Raw | ConvertFrom-Json; foreach($p in $saved.PSObject.Properties){$state[$p.Name]=$p.Value} }
function SendTelegram([string]$message) {
    try {
        $body = @{chat_id=$env:TELEGRAM_CHAT_ID;text=$message} | ConvertTo-Json -Compress
        $reply = Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot' + $env:TELEGRAM_BOT_TOKEN + '/sendMessage') -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20
        if (-not $reply.ok) { throw 'Not delivered' }
    } catch { throw 'Telegram mesaji gonderilemedi; bot anahtari, chat ID ve ag baglantisini kontrol edin.' }
}
if ($env:TELEGRAM_TEST -eq 'true') { SendTelegram 'Coin tarayici Telegram baglantisi calisiyor. Bu bir baglanti testidir.' }
SendTelegram ("Saatlik tarama: $($report.Zaman)`nSpot: $($report.Basarili)/$($report.Hedef) | Aday: $(@($report.Adaylar).Count)`nOKX OI: $(@($report.Sonuclar | Where-Object OIDurum -eq 'TAM').Count)/$($report.Basarili) | Fonlama: $(@($report.Sonuclar | Where-Object FonlamaDurum -eq 'TAM').Count)/$($report.Basarili)")
$measurementPath = Join-Path $root 'olcum-sonuc.json'
if (-not (Test-Path $measurementPath)) { throw 'Olcum sonucu eksik.' }
$measurement = Get-Content $measurementPath -Raw | ConvertFrom-Json
$statistics = @($measurement.Summary | Where-Object Count -gt 0 | ForEach-Object {
    "$($_.Signal) $($_.Hours) saat: n=$($_.Count), pozitif %$($_.PositivePct), BTC ustu %$($_.BeatBtcPct), ort. %$($_.MeanReturnPct)"
})
$measurementText = if ($statistics.Count) { $statistics -join "`n" } else { "Sonuc takibindeki sinyal: $($measurement.EventCount). Yeni sinyaller 1/4/24 saat sonra degerlendirilir." }
if ($measurement.Errors.Count) { $measurementText += "`nOlcum veri hatasi: $($measurement.Errors.Count). Eksik sonuclar sonraki turda yeniden denenir." }
SendTelegram ("Sinyal performansi (brut)`n$measurementText")
$resultMessage = ''
foreach ($item in $measurement.Completed) {
    $o = $item.Outcome
    $line = "$($item.Coin) $($item.Signal) $($o.Hours) saat: %$($o.ReturnPct), BTC farki $($o.ExcessPoints) puan; en dusuk %$($o.WorstPct), en yuksek %$($o.BestPct)`n"
    if (($resultMessage.Length + $line.Length) -gt 3200) { SendTelegram $resultMessage; $resultMessage = '' }
    $resultMessage += $line
}
if ($resultMessage) { SendTelegram ("Yeni olcum sonuclari`n$resultMessage") }

foreach ($c in $report.Adaylar) {
    if ($state[$c.Coin] -eq $c.Sinyal) { continue }
    $oi = if ($c.OIDurum -eq 'TAM') { "OI 1s: %$($c.OI1sYuzde); 4s: %$($c.OI4sYuzde)" } else { "OI: $($c.OIDurum)" }
    $funding = if ($c.FonlamaDurum -eq 'TAM') { "Fonlama: %$($c.FonlamaYuzde)" } else { "Fonlama: $($c.FonlamaDurum)" }
    SendTelegram ("Deneysel aday: $($c.Coin) - $($c.Sinyal)`nTarama: $($report.Zaman)`nFiyat: $($c.Fiyat)`nBTC farki (4s): $($c.BTCFarki4s) puan`nHacim: $($c.HacimKati) kat`nVadeli kaynak: OKX`n$oi`n$funding (yaklasan odeme icin tahmini)`nBu sinyal 1/4/24 saatlik sonuc takibine alindi. Oranlar saatlik performans mesajinda.")
    $state[$c.Coin] = $c.Sinyal
    $state | ConvertTo-Json | Set-Content -Encoding UTF8 $path
}
foreach ($r in $report.Sonuclar) { $state[$r.Coin] = $r.Sinyal }
$state | ConvertTo-Json | Set-Content -Encoding UTF8 $path


