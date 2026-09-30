@echo off
rem LoL OBS Scene Switcher launcher.
rem -ExecutionPolicy Bypass applies to this one process only (system policy is not changed).
rem The window is minimized, not hidden. Source: LolObsSceneSwitcher.ps1 (plain text, read it).
start "LoL OBS Scene Switcher" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0LolObsSceneSwitcher.ps1"
