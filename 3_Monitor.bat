@echo off
cd /d "%~dp0"
call "%~dp0tools\py.cmd" modem_tool.py monitor
pause
