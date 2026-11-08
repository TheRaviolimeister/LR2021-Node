@echo off
cd /d "%~dp0"
echo Transmit test - connect the ESP32 via USB COM, an antenna MUST be attached.
call "%~dp0tools\py.cmd" modem_tool.py tx
pause
