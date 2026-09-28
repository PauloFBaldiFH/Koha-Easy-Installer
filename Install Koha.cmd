@echo off
rem Koha Easy Installer for Windows: double-click to install Koha on this PC.
rem It runs exactly the PowerShell one-liner of the README, so there is one
rem way to install: the latest windows\install.ps1 from GitHub. Running it
rem again continues where it stopped.
setlocal
title Koha Easy Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1 | iex"
echo.
pause
