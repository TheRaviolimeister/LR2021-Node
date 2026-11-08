@echo off
cd /d "%~dp0"
echo Analyze ESP32 - connect the USB cable to the COM socket.
call "%~dp0tools\py.cmd" modem_tool.py analyse
pause
