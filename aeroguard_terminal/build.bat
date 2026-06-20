@echo off
echo ================================================================
echo   AeroGuard ZTNA Terminal — Build Script
echo ================================================================
echo.

echo [1/3] Checking Python...
python --version
if errorlevel 1 (
    echo ERROR: Python not found. Install Python 3.10+ and add to PATH.
    pause & exit /b 1
)

echo [2/3] Installing build dependencies...
pip install pyinstaller pystray Pillow --quiet

echo [3/3] Building AeroGuard_Terminal.exe ...
pyinstaller aeroguard_terminal.spec --noconfirm --clean

echo.
echo ================================================================
echo   BUILD COMPLETE
echo   Output: dist\AeroGuard_Terminal.exe
echo ================================================================
echo.
echo DEPLOYMENT STEPS:
echo   1. Copy dist\AeroGuard_Terminal.exe to the operator workstation
echo   2. Copy airport_system.db to the SAME folder as the .exe
echo   3. Run it — it starts hidden in the system tray and silently
echo      polls the gateway. No setup, no Windows Startup entry needed
echo      to test; add one separately only for a permanent admin box.
echo   4. The terminal pops to the foreground automatically the
echo      moment the gateway grants this machine's IP a session —
echo      nothing needs to be called from the gateway side.
echo.
pause
