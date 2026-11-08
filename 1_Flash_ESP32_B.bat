@echo off
cd /d "%~dp0"
echo Flash ESP32 B - connect the USB cable to the COM socket of ESP32 B.
call "%~dp0tools\py.cmd" modem_tool.py flash B
pause
