# LR2021 Node - gemeinsame Hilfsfunktionen fuer die Update-Scripte (wird per "." eingebunden)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$NodeDir = $PSScriptRoot
$MerkDatei = Join-Path $NodeDir "node_adresse.txt"

function Test-Node([string]$adr) {
  try {
    $r = Invoke-WebRequest -Uri "http://$adr/api/status" -UseBasicParsing -TimeoutSec 3
    $s = $r.Content | ConvertFrom-Json
    if ($s.kennung) { return $s }
  } catch { }
  return $null
}

function Find-Node([string]$Adresse) {
  $kandidaten = @()
  if ($Adresse) { $kandidaten += $Adresse }
  $kandidaten += "192.168.7.1"          # USB-C
  $kandidaten += "10.42.0.1"            # WLAN-Hotspot
  if (Test-Path $MerkDatei) { $kandidaten += (Get-Content $MerkDatei -TotalCount 1).Trim() }
  $kandidaten += "lr2021-node.local"    # vor der Ersteinrichtung
  foreach ($a in ($kandidaten | Where-Object { $_ } | Select-Object -Unique)) {
    Write-Host ("Suche Node unter {0} ..." -f $a)
    $s = Test-Node $a
    if ($s) { return @{ Adresse = $a; Status = $s } }
  }
  Write-Host ""
  Write-Host "Node nicht automatisch gefunden (USB 192.168.7.1 / WLAN 10.42.0.1)." -ForegroundColor Yellow
  $e = Read-Host "Adresse oder 4-stellige Kennung eingeben (z. B. 1A2B -> lr2021-1a2b.local), leer = Abbruch"
  if (-not $e) { return $null }
  if ($e -match '^[0-9A-Fa-f]{4}$') { $e = "lr2021-$($e.ToLower()).local" }
  $s = Test-Node $e
  if ($s) { return @{ Adresse = $e; Status = $s } }
  Write-Host "Unter $e antwortet keine Node." -ForegroundColor Red
  return $null
}

function Get-AuthHeader {
  $sec = Read-Host "Admin-Passwort der Node (Enter = Standard lr2021node)" -AsSecureString
  $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if (-not $pw) { $pw = "lr2021node" }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$pw"))
  return @{ Authorization = "Basic $b64" }
}

function Send-NodeFile([string]$url, [string]$datei, $headers) {
  try {
    $r = Invoke-WebRequest -Uri $url -Method Post -InFile $datei -ContentType "application/octet-stream" `
         -Headers $headers -UseBasicParsing -TimeoutSec 900
    $j = $r.Content | ConvertFrom-Json
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 401) { Write-Host "Passwort falsch." -ForegroundColor Red; return $false }
    $txt = ""
    if ($resp) { $txt = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() }
    try { $j = $txt | ConvertFrom-Json } catch { Write-Host "FEHLER: $($_.Exception.Message) $txt" -ForegroundColor Red; return $false }
  }
  $farbe = if ($j.ok) { "Green" } else { "Red" }
  Write-Host ""
  Write-Host $j.meldung -ForegroundColor $farbe
  if ($j.ausgabe) { Write-Host $j.ausgabe }
  return [bool]$j.ok
}

function Save-NodeAdresse([string]$adr) {
  if ($adr -notin @("192.168.7.1", "10.42.0.1")) { Set-Content -Path $MerkDatei -Value $adr -Encoding ascii }
}
