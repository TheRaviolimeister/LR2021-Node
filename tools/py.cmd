@echo off
rem Find Python 3 and run the script with it (Python from python.org, Windows launcher or PlatformIO).
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY if exist "%USERPROFILE%\.platformio\python3\python.exe" set "PY="%USERPROFILE%\.platformio\python3\python.exe""
if not defined PY (
  echo Python 3 was not found. Please install it from https://www.python.org/downloads/
  exit /b 1
)
%PY% %*
