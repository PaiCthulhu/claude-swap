@echo off
rem Lets cmd.exe (and anything else that runs .cmd files) call claude-swap.
pwsh -NoLogo -NoProfile -File "%~dp0claude-swap.ps1" %*
