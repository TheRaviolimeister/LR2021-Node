# LR2021 Node - Schritt 1: Armbian-Image laden und pruefen
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dl = Join-Path $here "download"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
Start-Transcript -Path (Join-Path $here "log_download.txt") -Force | Out-Null
try {
  $base = "https://dl.armbian.com/orangepizero2w/Trixie_current_minimal"
  # Pruefsumme IMMER von dl.armbian.com (nicht von der umgeleiteten GitHub-URL!)
  Write-Host "Lade Pruefsumme ..."
  $shaTxt = (Invoke-WebRequest -Uri "$base.sha" -UseBasicParsing).Content
  if ($shaTxt -is [byte[]]) { $shaTxt = [Text.Encoding]::ASCII.GetString($shaTxt) }
  $parts = $shaTxt.Trim() -split "\s+"
  $want = $parts[0].ToLower()
  $name = $parts[1].TrimStart('*')
  if ($want -notmatch '^[0-9a-f]{64}$' -or $name -notmatch '\.img\.xz$') { throw "Unerwartete Pruefsummen-Datei: $shaTxt" }
  Write-Host "Image: $name"
  $img = Join-Path $dl $name
  if (-not (Test-Path $img)) {
    Write-Host "Lade Image (ca. 300 MB) ..."
    Invoke-WebRequest -Uri $base -OutFile "$img.part" -UseBasicParsing
    Move-Item "$img.part" $img -Force
  }
  Set-Content -Path "$img.sha" -Value "$want $name" -Encoding ascii
  $have = (Get-FileHash $img -Algorithm SHA256).Hash.ToLower()
  Write-Host "SHA256 soll: $want"
  Write-Host "SHA256 ist : $have"
  if ($want -ne $have) { throw "Pruefsumme falsch - Download beschaedigt. Datei loeschen und neu starten." }
  Write-Host "Pruefsumme OK" -ForegroundColor Green
  Write-Host ""
  Write-Host "DOWNLOAD FERTIG" -ForegroundColor Green
} catch {
  Write-Host "FEHLER: $_" -ForegroundColor Red
}
Stop-Transcript | Out-Null
