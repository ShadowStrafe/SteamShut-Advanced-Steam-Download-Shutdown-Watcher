@echo off
cd /d "%~dp0"
echo Launching Steam Download Watcher...
powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0SteamDownloadWatcher.ps1"
