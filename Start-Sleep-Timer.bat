@echo off
chcp 65001 >nul
powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Sleep-Timer-GUI.ps1"
