@echo off
cd /d "%~dp0"
chcp 65001 >nul
echo Meshtastic chat - connect ESP32 A via USB COM, antenna attached.
call "%~dp0tools\py.cmd" modem_tool.py mesh
pause
