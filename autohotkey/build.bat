@echo off
echo Compiling WorkspaceLayoutManager...
where Ahk2Exe >nul 2>&1
if %errorlevel% equ 0 (
    Ahk2Exe /in "WorkspaceLayoutManager.ahk" /out "WorkspaceLayoutManager.exe"
    echo Done: WorkspaceLayoutManager.exe
) else (
    echo Ahk2Exe not found in PATH.
    echo Install AutoHotkey v2 with the compiler, or use:
    echo   "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in "WorkspaceLayoutManager.ahk" /out "WorkspaceLayoutManager.exe"
)
pause
