@echo off
rem Koha Easy Installer for Windows: double-click to install Koha on this PC.
rem It runs exactly the PowerShell one-line command of the README (the latest
rem windows\install.ps1 from GitHub), so both ways install the same way.
rem Running it again continues where it stopped.
setlocal
title Koha Easy Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1 | iex"
echo.
pause
