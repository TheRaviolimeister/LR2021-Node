@echo off
title LR2021 Node - Software-Update
rem Spielt das neueste Paket aus packages\ auf die Node (USB-C oder WLAN verbunden).
rem Anderes Paket: Datei auf diese .bat ziehen.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update_node.ps1" %1
echo.
pause
