@echo off
rem TPV Widget: starts the widget from this folder. Nothing is installed.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start.ps1"
