@echo off
title LR2021 Node - Update-Paket bauen
rem Packt source\opt\lr2021 als lr2021/ in packages\lr2021-update-JJJJMMTT-HHMM.tar.gz,
rem dazu install.sh (Systemkorrekturen) und die Dateien, die install.sh braucht.
rem Die .dtbo-Dateien in source\overlay erzeugt Build_Image.bat aus den .dts-Quellen.
setlocal
cd /d "%~dp0"
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmm"') do set "STAMP=%%T"
if not exist packages mkdir packages
set "OUT=packages\lr2021-update-%STAMP%.tar.gz"
set "TAR=%SystemRoot%\System32\tar.exe"
for %%O in (lr2021-nothermal lr2021-uart34) do (
  if not exist source\overlay\%%O.dtbo (
    echo FEHLER: source\overlay\%%O.dtbo fehlt ^(wird von Build_Image.bat erzeugt^).
    goto ende
  )
)
"%TAR%" -czf "%OUT%" --exclude "__pycache__" --exclude "*.pyc" ^
  -C source\opt lr2021 ^
  -C ..\update install.sh ^
  -C ..\rootfs etc/udev/rules.d/90-lr2021-usb-gadget.rules etc/udev/rules.d/91-lr2021-wlan.rules ^
     etc/systemd/system/serial-getty@.service.d/lr2021.conf ^
     etc/systemd/system/lr2021-hotspot.service usr/local/sbin/lr2021-hotspot ^
  -C ..\overlay lr2021-nothermal.dtbo lr2021-uart34.dtbo
if errorlevel 1 (
  echo FEHLER beim Packen.
) else (
  echo Paket erstellt: %OUT%
  "%TAR%" -tzf "%OUT%"
  echo.
  echo Einspielen: Update_Node.bat  oder per SSH:
  echo   scp %OUT% lr2021@192.168.7.1:
  echo   ssh lr2021@192.168.7.1 sudo lr2021-update lr2021-update-%STAMP%.tar.gz
)
:ende
echo.
pause
