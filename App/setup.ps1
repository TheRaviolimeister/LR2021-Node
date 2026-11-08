# LR2021 App – Werkzeuge einrichten (ohne Adminrechte, außer Visual Studio C++)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $env:USERPROFILE "LR2021-Tools"
$log   = Join-Path $here "setup_log.txt"
Start-Transcript -Path $log -Force | Out-Null
New-Item -ItemType Directory -Force -Path $tools | Out-Null
function Step($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Yellow }
function Get-File($url, $dest) {
  Write-Host "Lade $url"
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  Write-Host ("  {0:N0} MB" -f ((Get-Item $dest).Length / 1MB))
}

try {
  # ---- Git (Flutter braucht es) ----
  Step "Git"
  $gitExe = Join-Path $tools "git\cmd\git.exe"
  if (-not (Get-Command git -ErrorAction SilentlyContinue) -and -not (Test-Path $gitExe)) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{ "User-Agent" = "lr2021-setup" }
    $asset = $rel.assets | Where-Object { $_.name -match '^MinGit-[\d\.]+-64-bit\.zip$' } | Select-Object -First 1
    $z = Join-Path $tools "mingit.zip"
    Get-File $asset.browser_download_url $z
    New-Item -ItemType Directory -Force -Path (Join-Path $tools "git") | Out-Null
    tar -xf $z -C (Join-Path $tools "git")
    Remove-Item $z
  }
  Write-Host "Git ok"

  # ---- Java 17 ----
  Step "Java 17"
  $jdkDir = Get-ChildItem $tools -Directory -Filter "jdk-17*" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $jdkDir) {
    $z = Join-Path $tools "jdk.zip"
    Get-File "https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse" $z
    tar -xf $z -C $tools
    Remove-Item $z
    $jdkDir = Get-ChildItem $tools -Directory -Filter "jdk-17*" | Select-Object -First 1
  }
  Write-Host "Java: $($jdkDir.FullName)"

  # ---- Flutter ----
  Step "Flutter"
  $flutterBin = Join-Path $tools "flutter\bin\flutter.bat"
  if (-not (Test-Path $flutterBin)) {
    $base = "https://storage.googleapis.com/flutter_infra_release/releases"
    $j = Invoke-RestMethod "$base/releases_windows.json"
    $hash = $j.current_release.stable
    $r = $j.releases | Where-Object { $_.hash -eq $hash } | Select-Object -First 1
    Write-Host "Flutter $($r.version)"
    $z = Join-Path $tools "flutter.zip"
    Get-File "$base/$($r.archive)" $z
    Write-Host "Entpacke Flutter (dauert ein paar Minuten) ..."
    tar -xf $z -C $tools
    Remove-Item $z
  }
  Write-Host "Flutter ok"

  # ---- Android SDK ----
  Step "Android SDK"
  $sdk = Join-Path $tools "android-sdk"
  $sdkman = Join-Path $sdk "cmdline-tools\latest\bin\sdkmanager.bat"
  if (-not (Test-Path $sdkman)) {
    $z = Join-Path $tools "cmdtools.zip"
    Get-File "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" $z
    $tmp = Join-Path $tools "cmdtools_tmp"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    tar -xf $z -C $tmp
    New-Item -ItemType Directory -Force -Path (Join-Path $sdk "cmdline-tools") | Out-Null
    Move-Item (Join-Path $tmp "cmdline-tools") (Join-Path $sdk "cmdline-tools\latest")
    Remove-Item $tmp -Recurse; Remove-Item $z
  }
  $env:JAVA_HOME = $jdkDir.FullName
  $env:ANDROID_HOME = $sdk
  $env:ANDROID_SDK_ROOT = $sdk
  $yes = ("y`n" * 50)
  $yes | & $sdkman --sdk_root=$sdk --licenses | Out-Null
  & $sdkman --sdk_root=$sdk "platform-tools" "platforms;android-35" "build-tools;35.0.0"
  $yes | & $sdkman --sdk_root=$sdk --licenses | Out-Null
  Write-Host "Android SDK ok"

  # ---- Umgebungsvariablen dauerhaft ----
  Step "Pfade"
  [Environment]::SetEnvironmentVariable("JAVA_HOME", $jdkDir.FullName, "User")
  [Environment]::SetEnvironmentVariable("ANDROID_HOME", $sdk, "User")
  $p = [Environment]::GetEnvironmentVariable("Path", "User")
  foreach ($add in @((Join-Path $tools "flutter\bin"), (Join-Path $tools "git\cmd"), (Join-Path $jdkDir.FullName "bin"))) {
    if ($p -notlike "*$add*") { $p = "$p;$add" }
  }
  [Environment]::SetEnvironmentVariable("Path", $p, "User")
  $env:Path = "$env:Path;" + (Join-Path $tools "flutter\bin") + ";" + (Join-Path $tools "git\cmd") + ";" + (Join-Path $jdkDir.FullName "bin")

  # ---- Visual Studio C++ (für die Windows-App, braucht Adminrechte) ----
  Step "Visual Studio C++ Build Tools"
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $haveVC = $false
  if (Test-Path $vswhere) {
    $inst = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($inst) { $haveVC = $true }
  }
  if (-not $haveVC) {
    $z = Join-Path $tools "vs_buildtools.exe"
    Get-File "https://aka.ms/vs/17/release/vs_buildtools.exe" $z
    Write-Host "Installiere C++-Werkzeuge (Windows fragt nach Adminrechten, 10-30 min) ..."
    $pr = Start-Process -FilePath $z -Verb RunAs -Wait -PassThru -ArgumentList @(
      "--quiet", "--wait", "--norestart", "--nocache",
      "--add", "Microsoft.VisualStudio.Workload.VCTools",
      "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
      "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621",
      "--includeRecommended")
    Write-Host "Visual Studio Installer Rueckgabe: $($pr.ExitCode)"
  }
  Write-Host "C++ ok"

  # ---- Flutter prüfen ----
  Step "flutter doctor"
  & $flutterBin config --no-analytics | Out-Null
  & $flutterBin config --android-sdk $sdk | Out-Null
  & $flutterBin --disable-analytics | Out-Null
  & $flutterBin precache --windows --android
  & $flutterBin doctor -v
  Write-Host ""
  Write-Host "EINRICHTEN FERTIG" -ForegroundColor Green
} catch {
  Write-Host "FEHLER: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
}
Stop-Transcript | Out-Null
