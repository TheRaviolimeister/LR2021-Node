# LR2021 Node - ESP32-Firmware ueber die Node flashen (/api/esp/A bzw. /api/esp/B)
param([ValidateSet("A", "B", "AB", "")][string]$Ziel = "", [string]$Datei, [string]$Adresse)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "find_node.ps1")

function Find-Firmware([string]$rolle) {
  $name = "lr2021_modem_$rolle.bin"
  foreach ($d in @("..\firmware\bin", "..\bin", "firmware", ".")) {
    $p = Join-Path $NodeDir (Join-Path $d $name)
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = "Firmware fuer ESP32 $rolle waehlen ($name)"
  $dlg.Filter = "ESP32-Firmware (*.bin)|*.bin"
  if ($dlg.ShowDialog() -eq "OK") { return $dlg.FileName }
  return $null
}

try {
  if (-not $Ziel) {
    Write-Host "Welchen ESP32 flashen?"
    Write-Host "  A  = ESP32 A (HF 868)"
    Write-Host "  B  = ESP32 B (LF 433)"
    Write-Host "  AB = beide"
    $Ziel = (Read-Host "Auswahl").Trim().ToUpper()
  }
  if ($Ziel -notin @("A", "B", "AB")) { throw "Ungueltige Auswahl" }
  $jobs = @()
  foreach ($r in $Ziel.ToCharArray()) {
    $r = [string]$r
    $f = if ($Datei -and $Ziel.Length -eq 1) { $Datei } else { Find-Firmware $r }
    if (-not $f -or -not (Test-Path $f)) { throw "Keine Firmware fuer ESP32 $r gewaehlt" }
    $b = [IO.File]::ReadAllBytes($f)
    if ($b.Length -lt 1024 -or $b[0] -ne 0xE9) { throw "$f ist keine ESP32-Firmware (erstes Byte muss 0xE9 sein)" }
    Write-Host ("ESP32 {0}: {1} ({2} KB)" -f $r, $f, [math]::Round($b.Length / 1KB))
    $jobs += @{ Rolle = $r; Datei = $f }
  }
  $n = Find-Node $Adresse
  if (-not $n) { throw "Keine Node gefunden." }
  Write-Host ("Node gefunden: {0} ({1})" -f $n.Status.name, $n.Adresse) -ForegroundColor Green
  foreach ($j in $jobs) {
    $m = $n.Status.modems.($j.Rolle)
    $st = if ($m.verbunden) { "verbunden an $($m.anschluss), Firmware $($m.firmware)" } else { "NICHT verbunden" }
    Write-Host ("  ESP32 {0}: {1}" -f $j.Rolle, $st)
  }
  $ok = Read-Host "Jetzt flashen? (j/n)"
  if ($ok -notmatch '^[jJyY]') { Write-Host "Abgebrochen."; return }
  $h = Get-AuthHeader
  foreach ($j in $jobs) {
    Write-Host ""
    Write-Host "Flashe ESP32 $($j.Rolle) ... (ca. 30-60 s, nicht trennen)"
    if (-not (Send-NodeFile "http://$($n.Adresse)/api/esp/$($j.Rolle)" $j.Datei $h)) { throw "Flashen von ESP32 $($j.Rolle) fehlgeschlagen" }
  }
  Save-NodeAdresse $n.Adresse
} catch {
  Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
}
