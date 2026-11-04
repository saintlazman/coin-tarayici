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
foreach ($c in $report.Adaylar) {
    if ($state[$c.Coin] -eq $c.Sinyal) { continue }
    $oi = if ($c.OIDurum -eq 'TAM') { "OI 1s: %$($c.OI1sYuzde); 4s: %$($c.OI4sYuzde)" } else { "OI: $($c.OIDurum)" }
    $funding = if ($c.FonlamaDurum -eq 'TAM') { "Fonlama: %$($c.FonlamaYuzde)" } else { "Fonlama: $($c.FonlamaDurum)" }
    SendTelegram ("Deneysel aday: $($c.Coin) - $($c.Sinyal)`nTarama: $($report.Zaman)`nFiyat: $($c.Fiyat)`nBTC farki (4s): $($c.BTCFarki4s) puan`nHacim: $($c.HacimKati) kat`nVadeli kaynak: OKX`n$oi`n$funding (yaklasan odeme icin tahmini)`nBasari orani henuz olculmedi.")
    $state[$c.Coin] = $c.Sinyal
    $state | ConvertTo-Json | Set-Content -Encoding UTF8 $path
}
foreach ($r in $report.Sonuclar) { $state[$r.Coin] = $r.Sinyal }
$state | ConvertTo-Json | Set-Content -Encoding UTF8 $path

