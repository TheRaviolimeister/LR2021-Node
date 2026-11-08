# LR2021 Node - Software-Update der Node (Paket aus packages\ hochladen)
param([string]$Paket, [string]$Adresse)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "find_node.ps1")
try {
  if (-not $Paket) {
    $p = Get-ChildItem (Join-Path $NodeDir "packages") -Filter "lr2021-update-*.tar.gz" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $p) { throw "Kein Paket in packages\ gefunden. Zuerst Build_Update_Package.bat ausfuehren." }
    $Paket = $p.FullName
  }
  if (-not (Test-Path $Paket)) { throw "Paket $Paket nicht gefunden" }
  Write-Host "Paket: $Paket  ($([math]::Round((Get-Item $Paket).Length / 1KB)) KB)"
  $n = Find-Node $Adresse
  if (-not $n) { throw "Keine Node gefunden." }
  Write-Host ("Node gefunden: {0} ({1}), Version {2}" -f $n.Status.name, $n.Adresse, $n.Status.version) -ForegroundColor Green
  $ok = Read-Host "Update jetzt einspielen? (j/n)"
  if ($ok -notmatch '^[jJyY]') { Write-Host "Abgebrochen."; return }
  $h = Get-AuthHeader
  Write-Host "Lade hoch ..."
  if (Send-NodeFile "http://$($n.Adresse)/api/update" $Paket $h) {
    Save-NodeAdresse $n.Adresse
    Write-Host "Warte auf Neustart des Dienstes ..."
    Start-Sleep -Seconds 6
    $s = $null
    for ($i = 0; $i -lt 10 -and -not $s; $i++) { $s = Test-Node $n.Adresse; if (-not $s) { Start-Sleep 2 } }
    if ($s) { Write-Host "Node laeuft wieder, Version $($s.version)" -ForegroundColor Green }
    else { Write-Host "Node antwortet noch nicht - im Browser http://$($n.Adresse) pruefen." -ForegroundColor Yellow }
  }
} catch {
  Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
}
