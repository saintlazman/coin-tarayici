function SetRelativeWatchSignals($rows, [int]$expectedCount) {
    $complete = @($rows).Count -eq $expectedCount
    foreach ($row in $rows) {
        $eligible = $complete -and $row.Coin -ne 'BTCUSDT'
        $ranks = @()
        for ($offset = 0; $offset -lt 3; $offset++) {
            $point = $row.GucIzleri[$offset]
            $rank = 1 + @($rows | Where-Object { $_.GucIzleri[$offset].Getiri4s -gt $point.Getiri4s }).Count
            $ranks += $rank
            if ($point.BTCFarki4s -lt 1 -or $point.BTCGetiri4s -gt 0 -or $rank -gt 3) { $eligible = $false }
        }
        $row | Add-Member -NotePropertyName GucSirasi -NotePropertyValue $ranks -Force
        $row | Add-Member -NotePropertyName DenemeGucKosulu -NotePropertyValue $eligible -Force
        $row | Add-Member -NotePropertyName DenemeGucDurum -NotePropertyValue $(if ($complete) { 'TAM' } else { 'EKSIK_KAPSAM' }) -Force
        if ($eligible -and $row.Sinyal -eq 'YOK') { $row.Sinyal = 'GORELI_GUC_DENEME' }
    }
}
