@echo off
title LR2021 Node - Image bauen (WSL)
rem Baut das SD-Karten-Image in WSL2/Ubuntu. Dauert ca. 20-40 min.
set "NODEDIR=%~dp0"
for /f "usebackq delims=" %%P in (`wsl.exe -d Ubuntu -u root -- wslpath -a "%NODEDIR%build\build_image.sh"`) do set "SCRIPT=%%P"
if "%SCRIPT%"=="" (
  echo FEHLER: WSL/Ubuntu nicht startbar. Siehe README.txt ^(Virtualisierung im BIOS^).
  pause
  exit /b 1
)
wsl.exe -d Ubuntu -u root -- bash "%SCRIPT%" 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath '%NODEDIR%log_build.txt'"
echo.
pause
