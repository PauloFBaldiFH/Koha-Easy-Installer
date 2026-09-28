@echo off
rem Koha Easy Installer for Windows: double-click to install Koha on this PC.
rem Runs windows\install.ps1 from this folder, or downloads it when this
rem file was copied alone. Running it again continues where it stopped.
setlocal
title Koha Easy Installer
if exist "%~dp0windows\install.ps1" (
    set "KOHAEASY_SOURCE=%~dp0."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\install.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1 | iex"
)
echo.
pause
