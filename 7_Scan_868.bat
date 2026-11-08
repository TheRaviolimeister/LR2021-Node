@echo off
cd /d "%~dp0"
echo Scan 868 MHz (6 minutes) - connect ESP32 A via USB COM.
call "%~dp0tools\py.cmd" modem_tool.py scan
pause
