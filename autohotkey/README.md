# Workspace Layout Manager

A lightweight AutoHotkey v2 tray app that captures and restores named window
layouts across multiple monitors. No cloud, no installation, no admin rights.

---

## How to Use

### First Run

1. Make sure **AutoHotkey v2** is installed:
   `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`

2. Double-click `WorkspaceLayoutManager.ahk`
   (or right-click → "Run with AutoHotkey v2").

3. A tray icon appears in the system tray (bottom-right).
   A tooltip confirms the script is running.

---

### Hotkeys

| Hotkey | Action |
|--------|--------|
| `Ctrl+Alt+S` | **Save** current window layout (prompts for a name; blank → "Last") |
| `Ctrl+Alt+Q` | **Quick-save** to "QuickSave" slot (no prompt, instant) |
| `Ctrl+Alt+R` | **Restore** a saved layout (pick from list with preview) |
| `Ctrl+Alt+1` | Quick-restore **1st** layout (alphabetical order) |
| `Ctrl+Alt+2` | Quick-restore **2nd** layout |
| `Ctrl+Alt+3` | Quick-restore **3rd** layout |
| `Ctrl+Alt+L` | Toggle **auto-restore on login** ON/OFF |
| `Ctrl+Alt+D` | Toggle **debug logging** ON/OFF |

### Tray Menu

Right-click the tray icon for:
- **Save Layout** / **Quick Save** / **Restore Layout** — same as hotkeys
- **Manage Layouts** — rename, delete, set default startup layout
- **Settings** — configure auto-restore, delay, launch missing, auto-save interval, startup integration
- **Reload Script** / **Exit**

### Auto-Save

The script automatically saves an "AutoSave" layout every 15 minutes (configurable
in Settings). This acts as a safety net — if something crashes or you forget to save,
you can restore from AutoSave. Set to 0 in Settings to disable.

---

### Workflow

```
1. Arrange all your windows exactly how you want them.
2. Press Ctrl+Alt+S → type "Work" → Enter.
3. Later: press Ctrl+Alt+R → pick "Work" → click Restore.
   (or just press Ctrl+Alt+1 if "Work" is your first saved layout)
```

---

## Data Location

All data is stored in:

```
%APPDATA%\WorkspaceLayoutManager\
  layouts.json   ← all saved layouts
  settings.json  ← app settings
  debug.log      ← debug log (only when debug mode is ON)
```

`%APPDATA%` expands to something like `C:\Users\YourName\AppData\Roaming`.

---

## How to Add to Windows Startup

**Method A — via Settings GUI (recommended):**
1. Press `Ctrl+Alt+R` → Settings → click **"Add to Startup"**.

**Method B — manual registry:**
1. Open `regedit`.
2. Navigate to:
   `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`
3. Create a new **String Value** named `WorkspaceLayoutManager`.
4. Set its value to:
   ```
   "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\path\to\WorkspaceLayoutManager.ahk"
   ```

**Auto-restore on login:**
After adding to startup, enable auto-restore:
- Press `Ctrl+Alt+L` (toggles it), or open Settings and check "Auto-restore layout on login".
- Set "Startup layout" to whichever named layout you want.
- Default delay: 10 seconds (lets the desktop fully load first).

---

## How to Compile to a Standalone .exe

If you want a self-contained `.exe` (no AHK install needed on target machine):

1. Install **Ahk2Exe**: comes with AutoHotkey installer under `UX/`.
2. Run Ahk2Exe:
   ```
   "C:\Program Files\AutoHotkey\UX\Ahk2Exe.exe"
   ```
3. Source: point to `WorkspaceLayoutManager.ahk`
4. Destination: `WorkspaceLayoutManager.exe`
5. Compiler: leave as AutoHotkey64.exe
6. Click **Convert**.

---

## How to Customize Hotkeys

Open `WorkspaceLayoutManager.ahk` and find the `HOTKEYS` section (~line 50):

```ahk
^!s:: SaveLayoutAction()        ; Ctrl+Alt+S - Save
^!r:: RestoreLayoutAction()     ; Ctrl+Alt+R - Restore
^!1:: QuickRestore(1)
...
```

AHK v2 modifier symbols:
| Symbol | Key |
|--------|-----|
| `^` | Ctrl |
| `!` | Alt |
| `+` | Shift |
| `#` | Win |

Examples:
- `^+s::` = Ctrl+Shift+S
- `#F1::` = Win+F1
- `^!F5::` = Ctrl+Alt+F5

---

## How to Customize Window Matching

Open `lib\WindowMatch.ahk`:

- **Skip certain apps from capture** — add exe names to `_SkipExes`:
  ```ahk
  global _SkipExes := [
      "SearchHost.exe", "StartMenuExperienceHost.exe",
      "MyUnwantedApp.exe",   ; ← add here
  ]
  ```

- **Skip certain window classes** — add to `_SkipClasses`.

- **Title cleaning** — add entries to `AppSuffixes` in `CleanTitle()`:
  ```ahk
  " - My Custom App",   ; ← add suffix to strip
  ```

- **Matching logic** — `FindMatchingWindow()` uses:
  1. Process name + window class (primary key)
  2. Title similarity score (tiebreaker for multiple matches)
  Adjust `TitleSimilarity()` if you need stricter/looser matching.

---

## Known Limitations

### Admin-elevated windows
AHK runs as a normal user by default. It **cannot move or resize** windows that
run as Administrator (e.g., Task Manager, some installers, elevated command prompts).

**Fix:** Run the script itself as Administrator:
- Right-click `WorkspaceLayoutManager.ahk` → "Run as administrator".
- Or compile to `.exe`, then right-click → Properties → Compatibility →
  "Run as administrator".

### UWP / Microsoft Store apps
Apps like Calculator, Photos, and Microsoft To Do use UWP/WinUI. They are often
cloaked or running inside a `ApplicationFrameWindow` shell. Capture works for some,
but repositioning may be unreliable.

### DPI scaling on mixed-monitor setups
If your monitors have **different DPI scaling** (e.g., 150% on a laptop screen,
100% on an external), the x/y/w/h values saved by AHK are in **physical pixels
relative to the primary monitor's DPI**. Restoring to the same physical setup
works fine, but after changing DPI settings you may need to re-capture layouts.

**Workaround:** Set all monitors to the same DPI percentage in Windows Settings.

### Minimized windows
Minimized windows are captured and restored to the minimized state. They will not
be moved (Windows doesn't allow repositioning minimized windows meaningfully).
Maximize-then-minimize-restore is handled correctly.

### App startup timing
When "Launch missing apps" is enabled, the script launches apps and then waits
(with backoff, up to ~25 seconds total) for their windows to appear.
Heavy apps (browsers with many tabs, IDEs loading projects) may appear after
the retry window expires. Re-running the restore (`Ctrl+Alt+R`) after the app
has finished loading will place it correctly.

### Chrome / Edge multiple windows
If you have two Chrome windows open, the matching uses title similarity to pick
the best candidate. If both windows have the same page loaded, matching may assign
them in the wrong order. This is a fundamental limitation of title-based matching.

---

## Troubleshooting

**Script doesn't start / "Not a valid AHK v2 script" error:**
Make sure you're running with AutoHotkey **v2** specifically. Right-click the
`.ahk` file → "Open with" → browse to `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

**Hotkeys don't work when another app is focused:**
Some apps (games, fullscreen apps, other hotkey managers) consume hotkeys before
AHK sees them. Try running WLM as Administrator.

**Windows are placed on the wrong monitor:**
This usually means monitor indices changed (e.g., you connected/disconnected a monitor).
Simply re-capture the layout on your current monitor setup.

**"Could not read layouts file" error on startup:**
The `layouts.json` is corrupted. Back it up and delete it; the script will create a fresh one.
You can also check the file manually — it is plain JSON you can edit in Notepad.

**Debug log:**
Press `Ctrl+Alt+D` to enable debug logging. All capture/restore decisions are
written to `%APPDATA%\WorkspaceLayoutManager\debug.log`. Share this file when
reporting issues.

---

## File Structure

```
autohotkey/
  WorkspaceLayoutManager.ahk   Main script (hotkeys, orchestration)
  lib/
    Json.ahk                   JSON parser + serializer (vendored, no internet)
    Monitors.ahk               Monitor detection helpers
    WindowMatch.ahk            Window capture, filtering, matching, placement
    UI.ahk                     Tray menu, all GUIs, toast notifications
  sample_layouts.json          Example of what layouts.json looks like
  README.md                    This file
```
