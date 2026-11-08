# LR2021 Node - Image roh auf die SD-Karte mit dem Datentraegernamen "LR2021" schreiben.
#   -Image        .img-Datei (Standard: neueste image\LR2021-Node-*.img)
#   -NurPruefen   nur Karte suchen und anzeigen, nichts schreiben
#   -DiskNummer   erwartete Disk-Nummer (Pflicht zusammen mit -Bestaetigt)
#   -Bestaetigt   keine Rueckfrage (nur zusammen mit -DiskNummer, die zur Karte passen muss)
#   -OhneLabel    Karte hat kein Label "LR2021" mehr (schon geflasht): Disk per -DiskNummer waehlen,
#                 alle anderen Pruefungen gelten weiter
#   -NurVergleichen  nichts schreiben, nur erste 64 MB der Karte mit dem Image vergleichen
param([string]$Image, [switch]$NurPruefen, [int]$DiskNummer = -1, [switch]$Bestaetigt, [switch]$OhneLabel, [switch]$NurVergleichen)
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
$here = $PSScriptRoot
$log = Join-Path $here "write_sd_log.txt"
Start-Transcript -Path $log -Force | Out-Null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class LrRawDisk {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint ret, IntPtr ov);
  const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, SHARE_RW = 3, OPEN_EXISTING = 3;
  const uint FSCTL_LOCK_VOLUME = 0x00090018, FSCTL_DISMOUNT_VOLUME = 0x00090020;
  public static SafeFileHandle Open(string path, bool write) {
    SafeFileHandle h = CreateFile(path, write ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("Kann " + path + " nicht oeffnen (Windows-Fehler " + Marshal.GetLastWin32Error() + ")");
    return h;
  }
  public static SafeFileHandle LockDismount(string vol) {
    SafeFileHandle h = Open(vol, true);
    uint r;
    if (!DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero))
      throw new IOException("Laufwerk " + vol + " laesst sich nicht sperren (Fehler " + Marshal.GetLastWin32Error() + ") - Explorer-Fenster/Programme auf der Karte schliessen");
    if (!DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero))
      throw new IOException("Laufwerk " + vol + " laesst sich nicht aushaengen (Fehler " + Marshal.GetLastWin32Error() + ")");
    return h;
  }
}
"@

function Get-Karte {
  if ($OhneLabel) {
    if ($DiskNummer -lt 0) { throw "-OhneLabel braucht -DiskNummer N" }
    return Get-Disk -Number $DiskNummer
  }
  $vols = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'LR2021' })
  if ($vols.Count -ne 1) {
    throw ("Es muss genau EIN Laufwerk mit dem Namen LR2021 geben, gefunden: {0}. " +
           "(Schon geflashte Karte: in Windows als FAT32 mit Namen LR2021 formatieren oder -OhneLabel -DiskNummer N)") -f $vols.Count
  }
  $disks = @($vols[0] | Get-Partition | Get-Disk | Select-Object -Unique)
  if ($disks.Count -ne 1) { throw "Laufwerk LR2021 laesst sich keinem einzelnen Datentraeger zuordnen" }
  return $disks[0]
}

function Show-Size([UInt64]$b) { "{0:N1} GB ({1:N0} Bytes)" -f ($b / 1e9), $b }

function Compare-Karte([int]$n) {
  # Pruefen: erste 64 MB von der Karte zuruecklesen und per SHA256 mit dem Image vergleichen
  $cmp = [int][Math]::Min([long]64MB, [long]($imgLen - ($imgLen % 512)))
  $h = [LrRawDisk]::Open("\\.\PhysicalDrive$n", $false)
  $disk = New-Object IO.FileStream($h, [IO.FileAccess]::Read, 1)
  $a = New-Object byte[] $cmp
  $o = 0; while ($o -lt $cmp) { $k = $disk.Read($a, $o, $cmp - $o); if ($k -le 0) { break }; $o += $k }
  $disk.Close()
  $b = New-Object byte[] $cmp
  $s = [IO.File]::OpenRead($Image); $o2 = 0; while ($o2 -lt $cmp) { $k = $s.Read($b, $o2, $cmp - $o2); if ($k -le 0) { break }; $o2 += $k }; $s.Close()
  $sha = [Security.Cryptography.SHA256]::Create()
  $h1 = [BitConverter]::ToString($sha.ComputeHash($a, 0, $o)).Replace("-", "")
  $h2 = [BitConverter]::ToString($sha.ComputeHash($b, 0, $o2)).Replace("-", "")
  Write-Host ("SHA256 erste {0} MB Image: {1}" -f ($o2 / 1MB), $h2)
  Write-Host ("SHA256 erste {0} MB Karte: {1}" -f ($o / 1MB), $h1)
  if ($h1 -ne $h2 -or $o -ne $o2) { throw "PRUEFUNG FEHLGESCHLAGEN - Karte nicht verwenden, neu schreiben!" }
  Write-Host "Pruefung OK." -ForegroundColor Green
}

try {
  if (-not $Image) {
    $i = Get-ChildItem (Join-Path $here "image") -Filter "LR2021-Node-*.img" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($i) { $Image = $i.FullName } elseif (-not $NurPruefen) { throw "Kein Image in image\ gefunden" }
  }
  $imgLen = if ($Image) { (Get-Item $Image).Length } else { 0 }
  if ($Image) { Write-Host "Image: $Image  ($(Show-Size $imgLen))" } else { Write-Host "(noch kein Image vorhanden - nur Kartenpruefung)" }

  $d = Get-Karte
  Write-Host ""
  Write-Host "Gefundene SD-Karte:" -ForegroundColor Cyan
  Write-Host ("  Disk-Nummer : {0}" -f $d.Number)
  Write-Host ("  Modell      : {0}" -f $d.FriendlyName)
  Write-Host ("  Groesse     : {0}" -f (Show-Size $d.Size))
  Write-Host ("  Bus         : {0}   Boot: {1}   System: {2}" -f $d.BusType, $d.IsBoot, $d.IsSystem)
  Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
    $v = $_ | Get-Volume -ErrorAction SilentlyContinue
    Write-Host ("  Partition {0}: {1}  {2} {3}" -f $_.PartitionNumber, (Show-Size $_.Size), $_.DriveLetter, $(if ($v) { "[$($v.FileSystemLabel) $($v.FileSystem)]" } else { "" }))
  }

  # Sicherheitspruefungen
  if ($d.BusType -notin @('SD', 'USB', 'MMC')) { throw "Abbruch: BusType '$($d.BusType)' ist nicht SD/USB/MMC" }
  if ($d.IsBoot -or $d.IsSystem) { throw "Abbruch: Datentraeger ist Boot-/Systemlaufwerk" }
  if ($d.Size -gt 256GB) { throw "Abbruch: groesser als 256 GB" }
  if ($d.Size -lt $imgLen) { throw "Abbruch: Karte kleiner als das Image" }
  if ($DiskNummer -ge 0 -and $d.Number -ne $DiskNummer) { throw "Abbruch: Karte ist Disk $($d.Number), erwartet war Disk $DiskNummer" }
  Write-Host "Pruefungen OK." -ForegroundColor Green
  if ($NurPruefen) { return }
  if ($NurVergleichen) {
    if (-not $isAdmin) { throw "Zum Vergleichen bitte als Administrator starten." }
    Compare-Karte $d.Number
    return
  }

  if (-not $isAdmin) { throw "Zum Schreiben bitte als Administrator starten (Write_SD.bat fragt automatisch)." }
  if ($Bestaetigt) {
    if ($DiskNummer -lt 0) { throw "-Bestaetigt nur zusammen mit -DiskNummer" }
  } else {
    Write-Host ""
    Write-Host "ALLE Daten auf Disk $($d.Number) ($($d.FriendlyName)) werden ueberschrieben!" -ForegroundColor Yellow
    if ((Read-Host "Zum Schreiben 'ja' eingeben") -ne 'ja') { Write-Host "Abgebrochen."; return }
  }

  $n = $d.Number
  $locks = @()
  $offline = $false
  try {
    if ($d.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
    # Volumes sperren + aushaengen (klappt auch bei Kartenlesern, die kein Offline erlauben)
    foreach ($p in @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
      $v = $p | Get-Volume -ErrorAction SilentlyContinue
      if ($v -and $v.Path) {
        $locks += [LrRawDisk]::LockDismount($v.Path.TrimEnd('\'))
        Write-Host "Ausgehaengt: $($v.Path) $($p.DriveLetter)"
      }
    }
    try { Set-Disk -Number $n -IsOffline $true; $offline = $true; Write-Host "Disk $n offline." }
    catch { Write-Host "Hinweis: Disk laesst sich nicht offline setzen ($($_.Exception.Message)) - Volumes sind gesperrt, weiter." }

    $h = [LrRawDisk]::Open("\\.\PhysicalDrive$n", $true)
    $disk = New-Object IO.FileStream($h, [IO.FileAccess]::ReadWrite, 1)
    $src = [IO.File]::OpenRead($Image)
    $buf = New-Object byte[] (4MB)
    $done = [UInt64]0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($r = $src.Read($buf, 0, $buf.Length)) -gt 0) {
      while ($r -lt $buf.Length) {          # Datei-Lesevorgaenge koennen kuerzer sein: auffuellen
        $k = $src.Read($buf, $r, $buf.Length - $r); if ($k -le 0) { break }; $r += $k
      }
      $w = $r
      if ($w % 512) { $pad = 512 - ($w % 512); [Array]::Clear($buf, $w, $pad); $w += $pad }
      $disk.Write($buf, 0, $w)
      $done += $r
      $pct = [int](100 * $done / $imgLen)
      $mbs = ($done / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.1)
      Write-Progress -Activity "Schreibe auf Disk $n" -Status ("{0} % - {1:N0} / {2:N0} MB - {3:N1} MB/s" -f $pct, ($done / 1MB), ($imgLen / 1MB), $mbs) -PercentComplete $pct
    }
    $disk.Flush()
    $disk.Close()
    $src.Close()
    Write-Progress -Activity "Schreibe auf Disk $n" -Completed
    Write-Host ("Geschrieben: {0:N0} MB in {1:N0} s" -f ($done / 1MB), $sw.Elapsed.TotalSeconds)
    Compare-Karte $n
  } finally {
    foreach ($l in $locks) { try { $l.Close() } catch { } }
    if ($offline) { try { Set-Disk -Number $n -IsOffline $false; Write-Host "Disk $n wieder online." } catch { } }
  }
  Write-Host ""
  Write-Host "FERTIG. Fragt Windows jetzt 'Datentraeger formatieren?' -> ABBRECHEN klicken!" -ForegroundColor Green
  Write-Host "Karte auswerfen, in den Orange Pi stecken, Strom an. Erster Start dauert 2-4 Minuten."
} catch {
  Write-Host ""
  Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
  $global:LASTEXITCODE = 1
} finally {
  Stop-Transcript | Out-Null
}
