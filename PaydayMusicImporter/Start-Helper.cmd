@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Helper.ps1"
if errorlevel 1 (
    echo.
    echo The PAYDAY 2 Music Importer helper stopped with an error.
    pause
)
