@echo off
cd /d "%~dp0"
echo Flash ESP32 A - connect the USB cable to the COM socket of ESP32 A.
call "%~dp0tools\py.cmd" modem_tool.py flash A
pause
