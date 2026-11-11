$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$stateDirectory = Join-Path $root 'measurement-state'
New-Item -ItemType Directory -Force $stateDirectory | Out-Null
$ledgerPath = Join-Path $stateDirectory 'ledger.json'
$report = Get-Content (Join-Path $root 'son-durum.json') -Raw | ConvertFrom-Json -AsHashtable
if ($report.Durum -eq 'HATA') { throw 'Basarisiz taramadan olcum uretilmez.' }
function MeasureApi([string]$path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return Invoke-RestMethod -Uri ('https://data-api.binance.vision/api/v3/' + $path) -TimeoutSec 20 }
        catch { if ($attempt -eq 3) { throw }; Start-Sleep -Seconds 2 }
    }
}
function MeasureNumber($value) { [double]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture) }
function SaveLedger {
    $ledger | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 ($ledgerPath + '.tmp')
    Move-Item -LiteralPath ($ledgerPath + '.tmp') -Destination $ledgerPath -Force
}
function ReadMeasurementBars([string]$coin, [long]$start, [long]$end) {
    $bars = [Collections.Generic.List[object]]::new()
    $cursor = $start
    while ($cursor -le $end) {
        $raw = MeasureApi "klines?symbol=$coin&interval=1m&startTime=$cursor&endTime=$end&limit=1000"
        $batch = @($raw | ForEach-Object { ,$_ })
        if ($batch.Count -eq 0) { throw "Eksik olcum mumlari: $coin" }
        foreach ($bar in $batch) {
            if ([long]$bar[0] -ne $cursor -or [long]$bar[6] -ne ($cursor + 59999)) { throw "Olcum zaman boslugu: $coin" }
            $bars.Add($bar)
            $cursor += 60000
        }
    }
    return ,$bars.ToArray()
}
if (Test-Path $ledgerPath) {
    $ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
    if ($ledger.Version -ne 1) { throw 'Bilinmeyen olcum kayit surumu' }
} else {
    $ledger = @{Version=1; StartedAt=[DateTimeOffset]::UtcNow.ToString('o'); Events=@(); LastSignals=@{}; LastCutoff=0}
}
$now = [long](MeasureApi 'time').serverTime
$measurementErrors = [Collections.Generic.List[string]]::new()
$completed = [Collections.Generic.List[object]]::new()
foreach ($event in $ledger.Events) {
    foreach ($hours in @(1,4,24)) {
        $key = [string]$hours
        if ($event.Outcomes.ContainsKey($key)) { continue }
        $endOpen = [long]([math]::Floor([double]$event.ObservedAt / 60000) * 60000) + $hours * 3600000L - 60000L
        $endClose = $endOpen + 59999
        if ($now -le $endClose) { continue }
        try {
            # First partial minute is excluded from intraperiod high/low calculations.
            $start = [long]([math]::Floor([double]$event.ObservedAt / 60000) * 60000) + 60000
            $bars = ReadMeasurementBars $event.Coin $start $endClose
            $btc = ReadMeasurementBars 'BTCUSDT' $endOpen $endClose
            $exitPrice = MeasureNumber $bars[-1][4]
            $btcExit = MeasureNumber $btc[-1][4]
            $return = ($exitPrice / $event.EntryPrice - 1) * 100
            $btcReturn = ($btcExit / $event.BtcEntryPrice - 1) * 100
            $low = ($bars | ForEach-Object { MeasureNumber $_[3] } | Measure-Object -Minimum).Minimum
            $high = ($bars | ForEach-Object { MeasureNumber $_[2] } | Measure-Object -Maximum).Maximum
            $outcome = @{
                Hours=$hours; EndAt=$endClose; ExitPrice=$exitPrice
                ReturnPct=[math]::Round($return,4); BtcReturnPct=[math]::Round($btcReturn,4)
                ExcessPoints=[math]::Round($return-$btcReturn,4)
                Positive=($return -gt 0); BeatBtc=($return -gt $btcReturn)
                WorstPct=[math]::Round([math]::Min(0,($low/$event.EntryPrice-1)*100),4)
                BestPct=[math]::Round([math]::Max(0,($high/$event.EntryPrice-1)*100),4)
            }
            $event.Outcomes[$key] = $outcome
            $completed.Add(@{Coin=$event.Coin; Signal=$event.Signal; EntryPrice=$event.EntryPrice; Outcome=$outcome})
            SaveLedger
        } catch { $measurementErrors.Add("$($event.Coin) $hours saat: $($_.Exception.Message)") }
    }
}
$cutoff = [long]($report.Sonuclar | Select-Object -First 1).MumKapanis
$newCandidates = @($report.Adaylar | Where-Object { $ledger.LastSignals[$_.Coin] -ne $_.Sinyal })
if ($cutoff -gt [long]$ledger.LastCutoff) {
    if ($newCandidates.Count -gt 0) {
        try {
            $quotes = @{}
            foreach ($quote in (MeasureApi 'ticker/price')) { $quotes[$quote.symbol] = MeasureNumber $quote.price }
            $observedAt = [long](MeasureApi 'time').serverTime
            foreach ($candidate in $newCandidates) {
                if (-not $quotes.ContainsKey($candidate.Coin) -or $quotes[$candidate.Coin] -le 0 -or $quotes['BTCUSDT'] -le 0) { throw 'Olcum baslangic fiyati bulunamadi' }
                $id = "$($candidate.Coin)-$cutoff-$($candidate.Sinyal)"
                if ($id -in @($ledger.Events.Id)) { continue }
                $ledger.Events += @{
                    Id=$id; Coin=$candidate.Coin; Signal=$candidate.Sinyal; SignalAt=$report.Zaman; CandleClose=$cutoff
                    SignalPrice=$candidate.Fiyat; ObservedAt=$observedAt; EntryPrice=$quotes[$candidate.Coin]; BtcEntryPrice=$quotes['BTCUSDT']
                    RelativeStrength=$candidate.BTCFarki4s; VolumeRatio=$candidate.HacimKati
                    OI1h=$candidate.OI1sYuzde; OI4h=$candidate.OI4sYuzde; Funding=$candidate.FonlamaYuzde; FuturesSource=$candidate.VadeliKaynak
                    Outcomes=@{}
                }
                SaveLedger
            }
        } catch { throw "Yeni sinyal kaydedilemedi: $($_.Exception.Message)" }
    }
    foreach ($row in $report.Sonuclar) { $ledger.LastSignals[$row.Coin] = $row.Sinyal }
    $ledger.LastCutoff = $cutoff
}
SaveLedger
$summary = @()
foreach ($signal in @('IZLE','KIRILMA')) {
    foreach ($hours in @(1,4,24)) {
        $samples = @($ledger.Events | Where-Object { $_.Signal -eq $signal -and $_.Outcomes.ContainsKey([string]$hours) } | ForEach-Object { $_.Outcomes[[string]$hours] })
        $summary += @{
            Signal=$signal; Hours=$hours; Count=$samples.Count
            PositivePct=$(if($samples.Count){[math]::Round(@($samples | Where-Object Positive).Count/$samples.Count*100,1)}else{$null})
            BeatBtcPct=$(if($samples.Count){[math]::Round(@($samples | Where-Object BeatBtc).Count/$samples.Count*100,1)}else{$null})
            MeanReturnPct=$(if($samples.Count){[math]::Round(($samples.ReturnPct | Measure-Object -Average).Average,4)}else{$null})
            MeanExcessPoints=$(if($samples.Count){[math]::Round(($samples.ExcessPoints | Measure-Object -Average).Average,4)}else{$null})
        }
    }
}
@{UpdatedAt=$report.Zaman; StartedAt=$ledger.StartedAt; EventCount=@($ledger.Events).Count; Summary=$summary; Completed=@($completed.ToArray()); Errors=@($measurementErrors.ToArray())} | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 (Join-Path $root 'olcum-sonuc.json')
"Olcum kaydi: $(@($ledger.Events).Count) sinyal, $($completed.Count) yeni sonuc, $($measurementErrors.Count) veri hatasi"


