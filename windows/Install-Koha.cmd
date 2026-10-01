@echo off
setlocal
title Koha Easy Installer
rem Koha Easy Installer for Windows: double-click to install Koha on this PC.
rem It runs exactly the PowerShell one-line command of the README (the latest
rem windows\install.ps1 from GitHub), so both ways install the same way.
rem Running it again continues where it stopped.
rem Run it as the signed-in user, not "as administrator": Koha, Debian and the
rem shortcuts belong to this user, and Windows asks for permission itself at
rem the steps that need it. PowerShell is called by its full path.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1 | iex"
if errorlevel 1 (
    echo.
    echo If the only message above is "Access denied", Windows or an antivirus
    echo did not let PowerShell start. Open PowerShell from the Start menu and
    echo paste the install line from the README, or allow PowerShell in the
    echo antivirus and run this file again.
)
echo.
pause
