@echo off
setlocal
cd /d "%~dp0"
if not exist "ScreenSwitch.exe" (
    "%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe" /nologo /target:winexe /optimize+ /platform:anycpu /codepage:65001 /r:System.Drawing.dll /r:System.Windows.Forms.dll /out:ScreenSwitch.exe ScreenSwitch.cs Relay.cs
    if errorlevel 1 (
        echo Could not build ScreenSwitch.exe. Check that .NET Framework 4.x is enabled and this folder is writable.
        pause
        exit /b 1
    )
)
start "" "%~dp0ScreenSwitch.exe"
