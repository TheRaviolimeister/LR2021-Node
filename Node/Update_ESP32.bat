@echo off
title LR2021 Node - ESP32-Firmware flashen
rem Flasht lr2021_modem_A.bin / _B.bin ueber die Node (USB-C oder WLAN verbunden).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update_esp32.ps1"
echo.
pause
