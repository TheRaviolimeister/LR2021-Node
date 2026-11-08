# LR2021 App – bauen (Windows + Android)
$ProgressPreference = "SilentlyContinue"
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $env:USERPROFILE "LR2021-Tools"
$work  = Join-Path $env:USERPROFILE "LR2021-Build"
$log   = Join-Path $here "build_log.txt"
Start-Transcript -Path $log -Force | Out-Null
$jdk = Get-ChildItem $tools -Directory -Filter "jdk-17*" | Select-Object -First 1
$env:JAVA_HOME = $jdk.FullName
$env:ANDROID_HOME = Join-Path $tools "android-sdk"
$env:Path = (Join-Path $tools "flutter\bin") + ";" + (Join-Path $tools "git\cmd") + ";" + (Join-Path $jdk.FullName "bin") + ";$env:Path"
$py = Join-Path $env:USERPROFILE ".platformio\python3\python.exe"
function Run($what, [scriptblock]$b) {
  Write-Host ""; Write-Host "=== $what ===" -ForegroundColor Yellow
  & $b 2>&1 | ForEach-Object { "$_" } | Out-Host
  if ($LASTEXITCODE -ne 0) { Write-Host "SCHRITT FEHLGESCHLAGEN: $what (Code $LASTEXITCODE)" -ForegroundColor Red; $script:fail = $true }
  return
}
$fail = $false
# Entwicklermodus (Flutter braucht symbolische Links für Plugins)
$dev = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -ErrorAction SilentlyContinue
if (-not $dev -or $dev.AllowDevelopmentWithoutDevLicense -ne 1) {
  Write-Host "Bitte den Entwicklermodus einschalten (Fenster oeffnet sich) und 2_Bauen danach neu starten." -ForegroundColor Red
  Start-Process "ms-settings:developers"
  Stop-Transcript | Out-Null
  exit 1
}
# Android SDK 36
$sdkman = Join-Path $env:ANDROID_HOME "cmdline-tools\latest\bin\sdkmanager.bat"
Run "Android SDK 36" { ("y`n" * 30) | & $sdkman --sdk_root=$env:ANDROID_HOME "platforms;android-36" "build-tools;36.0.0" "build-tools;28.0.3" }
# Quellcode aus App\source in den Bauordner kopieren (Plattformordner bleiben, damit es schneller geht)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$src = Join-Path $here "source"
$ver = (Select-String -Path (Join-Path $src "pubspec.yaml") -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$defs = @("--dart-define=APP_VERSION=$ver")
foreach ($d in @("lib", "test", "tools")) { if (Test-Path (Join-Path $work $d)) { Remove-Item (Join-Path $work $d) -Recurse -Force } }
Copy-Item (Join-Path $src "*") $work -Recurse -Force
Set-Location $work

Run "flutter doctor" { flutter doctor -v }
Run "flutter create" { flutter create --platforms=android,windows,linux --project-name lr2021_app --org de.lr2021 . }
Run "Plattformen anpassen" { & $py tools/patch_platforms.py }
Run "pub get" { flutter pub get }
Run "analyze" { flutter analyze --no-fatal-infos --no-fatal-warnings }
Run "test" { flutter test }
if ($fail) { Write-Host "Fehler im Code - Bauen uebersprungen" -ForegroundColor Red } else {
Run "Windows bauen" { flutter build windows --release @defs }
# Android-Plugins an aktuelles Gradle anpassen: alle auf compileSdk 36, ältere zusätzlich jcenter/namespace
Get-ChildItem (Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev") -Directory | ForEach-Object {
  $g = Join-Path $_.FullName "android\build.gradle"
  if (Test-Path $g) {
    $t0 = Get-Content $g -Raw
    $t = $t0.TrimStart([char]0xFEFF) -replace 'jcenter\(\)', 'mavenCentral()'
    $t = $t -replace 'compileSdkVersion\s+\d+', 'compileSdkVersion 36' -replace 'compileSdk\s*=?\s*\d+', 'compileSdk 36'
    $ns = if ($_.Name -like "usb_serial-*") { "dev.bessems.usbserial" } elseif ($_.Name -like "flutter_libserialport-*") { "org.sigrok.flutter_libserialport" } else { "" }
    if ($ns -and $t -notmatch 'namespace') { $t = $t -replace 'android\s*\{', "android {`n    namespace '$ns'" }
    if ($t -ne $t0) { [IO.File]::WriteAllText($g, $t); Write-Host "Plugin-Gradle angepasst: $g" }
  }
}
$gp = Join-Path $work "android\gradle.properties"
$gt = Get-Content $gp -Raw
foreach ($kv in @("android.newDsl=false", "android.builtInKotlin=false")) { if ($gt -notmatch [regex]::Escape($kv.Split("=")[0])) { $gt = $gt.TrimEnd() + "`r`n" + $kv + "`r`n" } }
[IO.File]::WriteAllText($gp, $gt)
Write-Host "gradle.properties:"; Write-Host $gt
Run "Android bauen" { flutter build apk --release @defs }
}

$out = Join-Path $here "output"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$rel = Join-Path $work "build\windows\x64\runner\Release"
if (Test-Path (Join-Path $rel "lr2021_app.exe")) {
  $dst = Join-Path $out "LR2021-Node-Windows"
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
  Copy-Item $rel $dst -Recurse
  Write-Host "Windows-App: $dst\lr2021_app.exe" -ForegroundColor Green
}
$apk = Join-Path $work "build\app\outputs\flutter-apk\app-release.apk"
if (Test-Path $apk) {
  Copy-Item $apk (Join-Path $out "LR2021-Node.apk") -Force
  Write-Host "Android-App: $out\LR2021-Node.apk" -ForegroundColor Green
}
if ($fail) { Write-Host "BAUEN MIT FEHLERN BEENDET" -ForegroundColor Red } else { Write-Host "BAUEN FERTIG" -ForegroundColor Green }
Stop-Transcript | Out-Null
