@echo off
rem Fallback start path for WinPE builds that run startnet.cmd instead of
rem winpeshl.ini. Both paths lead to the same installer.
rem
rem ShimUEFI portable Windows - licensed under the GNU GPL v3.

wpeinit

echo.
echo ShimUEFI portable Windows
echo.

if exist X:\wintogo\wintogo.ps1 goto run
echo The installer payload is missing from this medium (X:\wintogo).
echo Rebuild the medium with wintogo/build/build-media.sh.
goto end

:run
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\wintogo\wintogo.ps1
if errorlevel 1 goto failed

echo.
echo The installer exited.
goto end

:failed
echo.
echo The installer reported a problem. Nothing was written to any internal disk.
echo Press any key to get a command prompt for diagnostics.
pause >nul
cmd.exe

:end
echo Press any key to reboot.
pause >nul
wpeutil reboot
