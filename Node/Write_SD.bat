@echo off
title LR2021 Node - SD-Karte schreiben
rem Schreibt das neueste image\LR2021-Node-*.img auf die SD-Karte mit dem Namen LR2021.
rem Fragt nach Administratorrechten und vor dem Schreiben nach "ja".
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0write_sd.ps1" %*
echo.
pause
