# Workspace Layout Manager

Save and restore your entire Windows workspace — window positions, sizes, and virtual desktops — with a single hotkey.

## Requirements

- **Windows 10 or 11**
- **[AutoHotkey v2](https://www.autohotkey.com/)** (free, ~5 MB)
  - Download from https://www.autohotkey.com/ → "Download" → **v2 installer**

## Installation

1. **Install AutoHotkey v2** (link above — run the installer, accept defaults)
2. **Download this repo** — click the green **Code** button → **Download ZIP**, then extract it anywhere (e.g. `C:\Tools\WorkspaceLayoutManager`)
3. **Run the script** — double-click `autohotkey\WorkspaceLayoutManager.ahk`
   - A small icon appears in the system tray (bottom-right, near the clock) — the app is running
4. *(First time only)* Right-click the tray icon → **Settings** → **Advanced** → **Scan & Auto-Configure** to detect your system and apply optimal settings

## Add to Windows Startup (optional)

Right-click the tray icon → **Settings** → **Startup** → **Add to Startup**

The script will then launch automatically when you log in.

## Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+Alt+S` | Save layout (with name prompt) |
| `Ctrl+Alt+Q` | Quick-save to "QuickSave" |
| `Ctrl+Alt+R` | Quick-restore most recently saved layout |
| `Ctrl+Alt+1/2/3` | Quick-restore 1st / 2nd / 3rd layout |
| `Ctrl+Alt+N` | Cycle through all layouts |
| `Ctrl+Alt+Tab` | Quick-switch between last two layouts |

## Usage

1. Arrange your windows the way you want
2. Press `Ctrl+Alt+S` to save the layout (give it a name, or leave blank for "Last")
3. Press `Ctrl+Alt+R` to restore it at any time

All layout data is saved in `%AppData%\WorkspaceLayoutManager\` and persists across reboots.

## Notes

- **Virtual desktop restore** (moving windows back to their saved desktop) requires **Windows 11 24H2 or later**. On older systems, windows are still placed on the correct monitor.
- If something looks off after updating Windows, run **Scan & Auto-Configure** again from the Settings.
