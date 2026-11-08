@echo off
cd /d "%~dp0"
echo Receive test, 5 minutes - connect the ESP32 via USB COM, antenna attached.
call "%~dp0tools\py.cmd" modem_tool.py rx
pause
