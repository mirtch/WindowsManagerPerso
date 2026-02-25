# Next-Level Workspace Layout Manager — 43 Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the MVP workspace layout manager into a polished, silent, self-adapting power tool across 43 features in 6 phases.

**Architecture:** Each phase builds on the previous. Phase 1 adds infrastructure (notification system, monitor fingerprinting, layout versioning) that later phases depend on. Phase 2 optimizes the core engine. Phase 3 adds monitor intelligence. Phase 4 adds productivity features. Phase 5 overhauls the UI. Phase 6 polishes and packages.

**Tech Stack:** AutoHotkey v2, Win32 COM APIs, DllCall, GDI+ for icons, shell32.dll for system icons.

**Note:** AHK v2 has no automated test framework. Each task includes manual verification steps. Test by reloading the script (`Ctrl+Alt+R` in tray or `Reload` menu item).

---

## Phase 1: Infrastructure Foundation

These create the building blocks that later features depend on.

---

### Task 1: Notification Levels System (#28)

Add a `notificationLevel` setting: `"verbose"`, `"normal"`, `"silent"`, `"errors"`. All existing ShowToast/MsgBox calls route through this gate. Later features (#29, #30, #31, #32) build on this.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add `ShouldNotify(level)` gate, update `ShowToast`, add `NotifyError`
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add `notificationLevel` to `DefaultSettings()`, route calls through gate

**Step 1: Add notification gate to UI.ahk**

In `UI.ahk`, add after `HideProgress()`:

```ahk
; Notification levels: "verbose" (everything), "normal" (saves/restores),
; "silent" (nothing), "errors" (only errors)
; msgLevel is what THIS message requires: "verbose", "normal", or "error"
ShouldNotify(msgLevel) {
    global Settings
    setting := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    if setting == "verbose"
        return true
    if setting == "normal"
        return (msgLevel == "normal" || msgLevel == "error")
    if setting == "errors"
        return (msgLevel == "error")
    return false  ; "silent"
}

; Wrapper: only shows toast if notification level allows it
Notify(msg, level := "normal", durationMs := 3000) {
    if ShouldNotify(level)
        ShowToast(msg, durationMs)
}

; Error notifications: shows as MsgBox in verbose/normal, tray balloon in errors mode
NotifyError(msg, title := "Error") {
    global AppName
    if !ShouldNotify("error")
        return
    setting := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    if (setting == "errors" || setting == "silent") {
        TrayTip(msg, AppName . " - " . title, "Icon!")
    } else {
        MsgBox(msg, AppName . " - " . title, "Icon!")
    }
}
```

**Step 2: Add default setting**

In `WorkspaceLayoutManager.ahk` `DefaultSettings()`, add:
```ahk
s["notificationLevel"] := "normal"  ; verbose | normal | silent | errors
```

**Step 3: Replace direct ShowToast/MsgBox calls**

- `SaveLayout()`: change `ShowToast("Saved layout:...")` to `Notify("Saved layout:...")`
- `RestoreLayout()`: change `ShowToast("Restoring:...")` to `Notify("Restoring:...")`
- `ToggleAutoRestoreAction()`: change `ShowToast(...)` to `Notify(..., "verbose")`
- `ToggleDebugAction()`: change `ShowToast(...)` to `Notify(..., "verbose")`
- `RestoreJob.Done()`: change `MsgBox(...)` for missing windows to `NotifyError(...)`
- `LoadLayouts()` catch: change `MsgBox(...)` to `NotifyError(...)`
- `SaveLayouts()` catch: change `MsgBox(...)` to `NotifyError(...)`
- `SaveSettings()` catch: change `MsgBox(...)` to `NotifyError(...)`

**Step 4: Add to Settings dialog**

In `ShowSettingsDialog()`, add a DropDownList for notification level after the auto-save interval section:
```ahk
setGui.Add("Text", "xm y+8", "Notification level:")
levels := ["verbose", "normal", "silent", "errors"]
ddlNotif := setGui.Add("DropDownList", "xm w250 vNotificationLevel", levels)
currentLevel := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
notifIdx := 2
Loop levels.Length {
    if levels[A_Index] == currentLevel {
        notifIdx := A_Index
        break
    }
}
ddlNotif.Choose(notifIdx)
```

In `OnSave`, add:
```ahk
Settings["notificationLevel"] := ddlNotif.Text
```

**Verify:** Reload script. Open Settings, change to "silent". Save a layout — no toast should appear. Change to "errors" — only errors show. Change to "verbose" — everything shows.

**Commit:** `git commit -m "feat: add notification levels (verbose/normal/silent/errors)"`

---

### Task 2: Monitor Configuration Fingerprint (#33)

Create a fingerprint string from monitor topology. Used by #1, #6 for auto-profile matching.

**Files:**
- Modify: `autohotkey/lib/Monitors.ahk` — add `GetMonitorFingerprint()`

**Step 1: Add fingerprint function**

Append to `Monitors.ahk`:

```ahk
; Build a stable fingerprint of the current monitor topology.
; Format: "N:WxH@X,Y|WxH@X,Y|..." sorted by position.
; Example: "2:1920x1080@0,0|2560x1440@1920,0"
GetMonitorFingerprint() {
    count := MonitorGetCount()
    parts := []
    Loop count {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        w := right - left
        h := bottom - top
        parts.Push(w . "x" . h . "@" . left . "," . top)
    }
    ; Sort parts alphabetically for stable ordering
    Loop parts.Length - 1 {
        i := A_Index
        Loop parts.Length - i {
            j := A_Index + i
            if StrCompare(parts[j], parts[j - 1]) < 0 {
                tmp := parts[j]
                parts[j] := parts[j - 1]
                parts[j - 1] := tmp
            }
        }
    }
    result := count . ":"
    for i, p in parts {
        if i > 1
            result .= "|"
        result .= p
    }
    return result
}
```

**Verify:** Add a temporary `MsgBox(GetMonitorFingerprint())` call in `Initialize()`. Reload, check the fingerprint matches your monitor setup. Remove the MsgBox.

**Commit:** `git commit -m "feat: add monitor topology fingerprint"`

---

### Task 3: Layout Versioning (#19)

Keep last N versions of each named layout. When saving "Work", the previous "Work" is stored as a version entry.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add `_VersionLayout()` before overwrite, add `maxLayoutVersions` to defaults

**Step 1: Add version storage**

In `DefaultSettings()`:
```ahk
s["maxLayoutVersions"] := 3
```

**Step 2: Add versioning logic**

In `WorkspaceLayoutManager.ahk`, add before `SaveLayout()`:

```ahk
; Store a version of an existing layout before overwriting it.
; Versions stored as "_versions" array inside the layout Map.
_VersionLayout(name) {
    global Layouts, Settings
    if !Layouts.Has(name)
        return
    maxVersions := Settings.Has("maxLayoutVersions") ? Settings["maxLayoutVersions"] : 3
    if maxVersions <= 0
        return
    old := Layouts[name]
    ; Initialize versions array if missing
    if !old.Has("_versions")
        old["_versions"] := []
    versions := old["_versions"]
    ; Save a snapshot (without nested _versions to avoid recursion)
    snapshot := Map()
    snapshot["timestamp"] := old.Has("timestamp") ? old["timestamp"] : ""
    snapshot["windows"]   := old.Has("windows") ? old["windows"] : []
    versions.Push(snapshot)
    ; Trim to max versions
    while versions.Length > maxVersions
        versions.RemoveAt(1)
}
```

**Step 3: Call versioning in SaveLayout()**

In `SaveLayout()`, add before `Layouts[name] := layout`:
```ahk
_VersionLayout(name)
```

**Verify:** Save a layout "Test" three times. In `layouts.json`, verify the "Test" entry has `_versions` with up to 3 entries.

**Commit:** `git commit -m "feat: keep last N versions of each saved layout"`

---

### Task 4: Backup Before Overwrite (#42)

When saving a layout that already exists, log that we're overwriting. (Versioning from Task 3 already preserves the old data, so this task just adds a debug log and a safety check.)

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add overwrite warning in `SaveLayout()`

**Step 1: Add overwrite log**

In `SaveLayout()`, after `_VersionLayout(name)` and before `Layouts[name] := layout`:
```ahk
if Layouts.Has(name) {
    oldCount := Layouts[name].Has("windows") ? Layouts[name]["windows"].Length : 0
    DebugLog("Overwriting layout '" . name . "' (had " . oldCount . " windows)")
}
```

**Verify:** Enable debug mode. Save "Test" twice. Check debug.log shows the overwrite message with window count.

**Commit:** `git commit -m "feat: log overwrite warnings when saving over existing layout"`

---

### Task 5: Layout Garbage Collection (#35)

Auto-delete AutoSave versions older than 7 days. Runs at startup.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add `CleanOldAutoSaves()`, call from `Initialize()`

**Step 1: Add cleanup function**

```ahk
; Remove AutoSave entries older than N days (default 7).
CleanOldAutoSaves() {
    global Layouts
    maxAgeDays := 7
    now := A_Now  ; YYYYMMDDHHMMSS format
    toDelete := []
    for name, layout in Layouts {
        ; Only clean names starting with "AutoSave"
        if SubStr(name, 1, 8) != "AutoSave"
            continue
        if !layout.Has("timestamp")
            continue
        ; Parse "yyyy-MM-dd HH:mm:ss" to YYYYMMDDHHMMSS
        ts := layout["timestamp"]
        ts := StrReplace(StrReplace(StrReplace(ts, "-"), ":"), " ")
        if StrLen(ts) < 14
            continue
        diff := DateDiff(now, ts, "Days")
        if diff > maxAgeDays
            toDelete.Push(name)
    }
    if toDelete.Length > 0 {
        for name in toDelete
            Layouts.Delete(name)
        SaveLayouts()
        DebugLog("GC: removed " . toDelete.Length . " old AutoSave entries")
    }
}
```

**Step 2: Call from Initialize()**

Add after `Layouts := LoadLayouts()`:
```ahk
CleanOldAutoSaves()
```

**Verify:** Manually edit `layouts.json` to add an AutoSave with a timestamp from 10 days ago. Reload. Check it's been removed.

**Commit:** `git commit -m "feat: auto-cleanup AutoSave entries older than 7 days"`

---

### Task 6: Lazy JSON Writes / Debounce (#10)

Debounce `SaveLayouts()` so rapid saves don't thrash disk.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — wrap `SaveLayouts()` with debounce

**Step 1: Add debounced save**

Replace `SaveLayouts()` with:

```ahk
global _SaveLayoutsPending := false

SaveLayouts() {
    global _SaveLayoutsPending
    if _SaveLayoutsPending
        return  ; Already scheduled
    _SaveLayoutsPending := true
    SetTimer(_FlushLayouts, -200)  ; 200ms debounce
}

_FlushLayouts() {
    global AppDir, LayoutsFile, Layouts, AppName, _SaveLayoutsPending
    _SaveLayoutsPending := false
    DirCreate(AppDir)
    try {
        content := JSON.Stringify(Layouts)
        f := FileOpen(LayoutsFile, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        NotifyError("Could not save layouts:`n" . e.Message . "`n`n" . e.Stack)
    }
}
```

**Verify:** Quick-save 3 times rapidly. Check that `layouts.json` is only written once (timestamp in the file should match the last save).

**Commit:** `git commit -m "feat: debounce layout file writes (200ms)"`

---

### Task 7: Tray Icon Shows Current Layout (#40)

Show a tick mark next to the most recently restored layout in the tray menu.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — track `_CurrentLayoutName`
- Modify: `autohotkey/lib/UI.ahk` — update tray menu dynamically

**Step 1: Add global tracker**

In `WorkspaceLayoutManager.ahk` globals section:
```ahk
global _CurrentLayoutName := ""
```

**Step 2: Set on restore**

In `RestoreLayout()`, after `job.Start()`:
```ahk
global _CurrentLayoutName := name
```

**Step 3: Update tray tip**

In `RestoreJob.Done()`, update the icon tip:
```ahk
A_IconTip := "WLM — " . this.layout["name"]
```

**Verify:** Restore a layout. Hover over tray icon — should show layout name.

**Commit:** `git commit -m "feat: show current layout name in tray icon tooltip"`

---

## Phase 2: Core Engine Optimizations

Make restoring faster, smoother, and more accurate.

---

### Task 8: Diff-Based Restore (#3)

Before moving a window, check if it's already in the correct position. Skip if already placed.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — add `IsAlreadyPlaced()` check
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — use it in `RestoreJob`

**Step 1: Add position check**

In `WindowMatch.ahk`, add:

```ahk
; Check if a window is already at the position described by the entry.
; Returns true if position, size, and state all match within tolerance.
IsAlreadyPlaced(hwnd, entry) {
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
        minmax := WinGetMinMax(hwnd)
        state := "normal"
        if minmax == 1
            state := "maximized"
        else if minmax == -1
            state := "minimized"

        ; State must match
        if state != entry["state"]
            return false
        ; For maximized/minimized, just check state — position doesn't matter
        if state != "normal"
            return true
        ; Position tolerance: 10px (accounts for DPI rounding)
        tolerance := 10
        if Abs(x - entry["x"]) > tolerance
            return false
        if Abs(y - entry["y"]) > tolerance
            return false
        if Abs(w - entry["w"]) > tolerance
            return false
        if Abs(h - entry["h"]) > tolerance
            return false
        return true
    } catch {
        return false
    }
}
```

**Step 2: Use in RestoreJob.Start() and Retry()**

In `RestoreJob.Start()`, after `hwnd := FindMatchingWindow(...)`, change the if-block:
```ahk
if hwnd {
    if IsAlreadyPlaced(hwnd, entry) {
        this.placed++
        DebugLog("Already placed: " . entry["exe"] . " '" . entry["cleanTitle"] . "'")
    } else {
        PlaceWindow(hwnd, entry)
        this.placed++
        deskLabel := entry.Has("desktopIndex") && entry["desktopIndex"] > 0
            ? " -> D" . entry["desktopIndex"] : ""
        DebugLog("Placed: " . entry["exe"] . " '" . entry["cleanTitle"] . "'" . deskLabel)
    }
```

Do the same in `Retry()`.

**Verify:** Save a layout, then immediately restore it. Debug log should show "Already placed" for all windows. No screen flicker.

**Commit:** `git commit -m "feat: skip windows already in correct position during restore"`

---

### Task 9: Skip-If-Placed Optimization (#9)

Remove matched hwnds from the candidate pool during retry so they aren't re-scanned.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — track placed hwnds in `RestoreJob`

**Step 1: Track placed hwnds**

In `RestoreJob.__New()`, add:
```ahk
this.placedHwnds := Map()  ; hwnd -> true
```

**Step 2: Filter candidates**

In `RestoreJob.Start()` and `Retry()`, after `candidates := WinGetList()`, add:
```ahk
; Filter out already-placed windows
filtered := []
for hwnd in candidates {
    if !this.placedHwnds.Has(hwnd)
        filtered.Push(hwnd)
}
candidates := filtered
```

When a window is placed, add:
```ahk
this.placedHwnds[hwnd] := true
```

**Verify:** Enable debug mode. Restore a layout with 10+ windows. Check that retry rounds scan fewer candidates each time.

**Commit:** `git commit -m "feat: remove placed hwnds from candidate pool in retry loops"`

---

### Task 10: Parallel App Launching (#7)

Launch all missing apps at once instead of sequentially with implicit waits.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — `LaunchMissingApps` already launches sequentially via `Run()`, which is non-blocking. This is already effectively parallel since `Run()` returns immediately. Just add a small stagger to prevent resource contention.

**Step 1: Add slight stagger**

In `LaunchMissingApps()`, after each `try Run(...)`, add:
```ahk
Sleep(100)  ; Brief stagger to prevent resource contention
```

This is actually already close to optimal. The main improvement is ensuring we don't `Sleep()` unnecessarily. Keep the function as-is but add a count log:

```ahk
; At end of function:
DebugLog("LaunchMissing: launched " . launched.Count . " apps")
```

**Verify:** Restore a layout with missing apps. Check they all start launching within ~1 second.

**Commit:** `git commit -m "feat: add launch count logging to LaunchMissingApps"`

---

### Task 11: Adaptive Retry Timing (#8)

Profile which apps are slow (browsers, IDEs) vs fast. Use shorter delays for fast apps, longer for slow.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — replace fixed `delays` array with adaptive logic

**Step 1: Replace fixed delays**

In `RestoreJob.__New()`, replace `this.delays` with:
```ahk
; Base delay schedule (ms). If only fast apps remain, use shorter delays.
this.fastDelays := [200, 200, 300, 300, 500, 500, 1000, 1000, 1500]
this.slowDelays := [500, 500, 1000, 1000, 2000, 2000, 3000, 4000, 5000]
this.maxAttempts := 13
```

Add a helper method:
```ahk
GetDelay() {
    ; Check if remaining apps are all "fast" (not browsers/IDEs)
    static slowExes := Map("msedge.exe", 1, "chrome.exe", 1, "firefox.exe", 1,
                           "brave.exe", 1, "cursor.exe", 1, "code.exe", 1,
                           "slack.exe", 1, "teams.exe", 1, "spotify.exe", 1)
    hasSlow := false
    for entry in this.remaining {
        if slowExes.Has(StrLower(entry["exe"])) {
            hasSlow := true
            break
        }
    }
    delays := hasSlow ? this.slowDelays : this.fastDelays
    idx := Min(this.attempt + 1, delays.Length)
    return delays[idx]
}
```

**Step 2: Use in Start() and Retry()**

Replace `SetTimer(this.bound, -this.delays[...])` with:
```ahk
SetTimer(this.bound, -this.GetDelay())
```

Replace `this.attempt >= this.delays.Length` with:
```ahk
this.attempt >= this.maxAttempts
```

**Verify:** Restore a layout with only Notepad windows — should resolve in <1s. Restore one with browsers — should wait longer.

**Commit:** `git commit -m "feat: adaptive retry timing based on app type (fast vs slow)"`

---

### Task 12: Batch WinMove with Minimal Sleep (#37)

Do all normal-state moves first (no sleep between them), then maximize passes.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — split `PlaceWindow` into two passes

**Step 1: Add batch placement function**

```ahk
; Place multiple windows efficiently by batching moves.
; normalMoves: Array of [hwnd, entry] for normal-state windows
; maxMoves: Array of [hwnd, entry] for maximized windows
; Minimizes Sleep calls by doing all normal moves first.
BatchPlaceWindows(placements) {
    ; Pass 1: Move to correct virtual desktop (all windows)
    for pair in placements {
        hwnd := pair[1]
        entry := pair[2]
        if entry.Has("desktopGuid") && entry["desktopGuid"] != "" {
            try {
                targetGuid := VD_StringToGuid(entry["desktopGuid"])
                if targetGuid {
                    VD_MoveToDesktop(hwnd, targetGuid)
                    try WinShow(hwnd)
                }
            }
        }
    }
    Sleep(80)  ; Single sleep for all VD moves

    ; Pass 2: Handle minimized windows
    for pair in placements {
        hwnd := pair[1]
        entry := pair[2]
        if entry["state"] == "minimized" {
            try WinMinimize(hwnd)
        }
    }

    ; Pass 3: Un-maximize and move normal windows (no sleep between moves)
    for pair in placements {
        hwnd := pair[1]
        entry := pair[2]
        if entry["state"] == "minimized"
            continue
        try {
            if WinGetMinMax(hwnd) != 0
                WinRestore(hwnd)
        }
        if entry["state"] == "normal" {
            clamped := ClampToMonitor(entry["x"], entry["y"], entry["w"], entry["h"])
            try WinMove(clamped["x"], clamped["y"], clamped["w"], clamped["h"], hwnd)
        }
    }

    ; Pass 4: Maximize windows (needs small delay after move)
    hasMax := false
    for pair in placements {
        if pair[2]["state"] == "maximized" {
            hasMax := true
            break
        }
    }
    if hasMax {
        Sleep(30)
        for pair in placements {
            hwnd := pair[1]
            entry := pair[2]
            if entry["state"] == "maximized" {
                clamped := ClampToMonitor(entry["x"], entry["y"], entry["w"], entry["h"])
                try {
                    WinMove(clamped["x"] + 50, clamped["y"] + 50, 400, 300, hwnd)
                    Sleep(20)
                    WinMaximize(hwnd)
                }
            }
        }
    }
}
```

**Step 2: Use in RestoreJob**

Collect placements in `Start()` and `Retry()` into an array, then call `BatchPlaceWindows()` once instead of `PlaceWindow()` per window.

**Verify:** Restore a 15-window layout. Should complete noticeably faster with less flicker.

**Commit:** `git commit -m "feat: batch window moves for faster restore with less flicker"`

---

### Task 13: Focus-Steal Suppression (#4)

Lock foreground focus during restore so windows don't fight for attention.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add focus lock in `RestoreJob`

**Step 1: Lock/unlock foreground**

In `RestoreJob.Start()`, at the top:
```ahk
; Prevent foreground focus stealing during restore
DllCall("LockSetForegroundWindow", "UInt", 1)  ; LSFW_LOCK
```

In `RestoreJob.Done()`, before the notification:
```ahk
DllCall("LockSetForegroundWindow", "UInt", 2)  ; LSFW_UNLOCK
```

**Verify:** Restore a large layout. Windows should not flash/steal focus during placement.

**Commit:** `git commit -m "feat: lock foreground focus during restore to prevent flicker"`

---

### Task 14: Restore Without Window Flash (#32)

Hide windows during move, then show them. Prevents visible jumping.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — add transparency trick to `BatchPlaceWindows`

**Step 1: Add fade support**

In `BatchPlaceWindows()`, before Pass 3 (the move pass), add:
```ahk
; Hide windows being moved (set transparent)
for pair in placements {
    hwnd := pair[1]
    entry := pair[2]
    if entry["state"] != "minimized" {
        try WinSetTransparent(0, hwnd)
    }
}
```

After all passes complete, at the end:
```ahk
; Reveal all windows
for pair in placements {
    hwnd := pair[1]
    entry := pair[2]
    if entry["state"] != "minimized" {
        try WinSetTransparent("Off", hwnd)
    }
}
```

**Verify:** Restore a layout. Windows should appear in their final position without visible jumping.

**Commit:** `git commit -m "feat: hide windows during move to prevent visual jumping"`

---

### Task 15: Better Window Matching (#36)

Use process creation time + exe + class as a more stable identifier.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — add process-time-based matching

**Step 1: Add process start time to capture**

In `CaptureWindowEntry()`, after `exePath := ProcessGetPath(pid)`:
```ahk
; Capture process creation time for more stable matching
procTime := ""
try {
    procTime := _GetProcessCreateTime(pid)
}
```

Add to entry:
```ahk
entry["processTime"] := procTime
```

**Step 2: Add helper**

```ahk
_GetProcessCreateTime(pid) {
    hProc := DllCall("OpenProcess", "UInt", 0x0400, "Int", 0, "UInt", pid, "Ptr")
    if !hProc
        return ""
    creation := Buffer(8)
    exit := Buffer(8)
    kernel := Buffer(8)
    user := Buffer(8)
    result := DllCall("GetProcessTimes", "Ptr", hProc,
        "Ptr", creation, "Ptr", exit, "Ptr", kernel, "Ptr", user)
    DllCall("CloseHandle", "Ptr", hProc)
    if !result
        return ""
    return NumGet(creation, 0, "Int64")
}
```

**Step 3: Use in matching**

In `FindMatchingWindow()`, after pass1 returns multiple candidates, add a pass1.5 that filters by process creation time if available.

**Verify:** Open 3 Cursor windows. Save layout. Close and reopen them. Restore — windows should match correctly even with different titles.

**Commit:** `git commit -m "feat: use process creation time for more stable window matching"`

---

### Task 16: Incremental Capture (#11)

Only re-capture windows whose position/title changed since last capture. Big speedup for auto-save.

**Files:**
- Modify: `autohotkey/lib/WindowMatch.ahk` — add `_LastCaptureState` cache
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — use incremental in `AutoSave()`

**Step 1: Add capture cache**

In `WindowMatch.ahk`:
```ahk
global _LastCaptureState := Map()  ; hwnd -> "exe|title|x|y|w|h|state"

; Build a state key for a window
_WindowStateKey(hwnd) {
    try {
        exe := WinGetProcessName(hwnd)
        title := WinGetTitle(hwnd)
        WinGetPos(&x, &y, &w, &h, hwnd)
        state := WinGetMinMax(hwnd)
        return exe . "|" . title . "|" . x . "|" . y . "|" . w . "|" . h . "|" . state
    } catch {
        return ""
    }
}

; Quick check: has anything changed since last full capture?
HasWindowsChanged() {
    global _LastCaptureState
    DetectHiddenWindows(true)
    hwnds := WinGetList()
    DetectHiddenWindows(false)

    ; Different number of windows = changed
    if hwnds.Length != _LastCaptureState.Count
        return true

    for hwnd in hwnds {
        key := _WindowStateKey(hwnd)
        if key == ""
            continue
        if !_LastCaptureState.Has(hwnd) || _LastCaptureState[hwnd] != key
            return true
    }
    return false
}
```

**Step 2: Update cache after capture**

At end of `CaptureAllWindows()`, before the return:
```ahk
; Update state cache for incremental detection
global _LastCaptureState
_LastCaptureState := Map()
for entry in entries {
    hwnd := entry["hwnd"]
    _LastCaptureState[hwnd] := entry["exe"] . "|" . entry["title"] . "|"
        . entry["x"] . "|" . entry["y"] . "|" . entry["w"] . "|" . entry["h"] . "|" . entry["state"]
}
```

**Step 3: Use in AutoSave()**

In `AutoSave()`, before `CaptureAllWindows()`:
```ahk
if !HasWindowsChanged() {
    DebugLog("AutoSave: no changes detected, skipping")
    return
}
```

**Verify:** Enable debug mode. Wait for auto-save. If nothing moved, log should show "no changes detected". Move a window, wait — full capture should occur.

**Commit:** `git commit -m "feat: incremental capture detection for efficient auto-save"`

---

## Phase 3: Monitor Intelligence

Auto-detect and respond to monitor topology changes.

---

### Task 17: WM_DISPLAYCHANGE Listener (#2)

React instantly when monitors connect/disconnect.

**Files:**
- Modify: `autohotkey/lib/Monitors.ahk` — add message handler
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — register handler, add callback

**Step 1: Register Windows message**

In `Initialize()`, after `SetupTray()`:
```ahk
OnMessage(0x007E, OnDisplayChange)  ; WM_DISPLAYCHANGE
```

**Step 2: Add handler**

In `WorkspaceLayoutManager.ahk`:
```ahk
; Debounce: display change fires multiple times
global _DisplayChangeTimer := 0

OnDisplayChange(wParam, lParam, msg, hwnd) {
    global _DisplayChangeTimer
    ; Debounce: wait 2 seconds for display to stabilize
    if _DisplayChangeTimer
        SetTimer(_DisplayChangeTimer, 0)
    _DisplayChangeTimer := ObjBindMethod({}, "Call")
    SetTimer(HandleDisplayChange, -2000)
}

HandleDisplayChange() {
    global _DisplayChangeTimer
    _DisplayChangeTimer := 0
    newFP := GetMonitorFingerprint()
    DebugLog("Display changed: " . newFP)
    ; (Phase 3 Task 18 will add auto-profile matching here)
}
```

**Verify:** Unplug/plug a monitor (or change resolution in Display Settings). Check debug.log shows "Display changed:" message.

**Commit:** `git commit -m "feat: listen for WM_DISPLAYCHANGE to detect monitor topology changes"`

---

### Task 18: Monitor Profile Auto-Switch (#1)

Automatically restore the right layout when monitor topology changes.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add profile storage, matching
- Modify: `autohotkey/lib/UI.ahk` — add profile association UI

**Step 1: Add profile storage**

Each layout stores the monitor fingerprint it was captured on.

In `SaveLayout()`, add to the layout Map:
```ahk
layout["monitorFingerprint"] := GetMonitorFingerprint()
```

**Step 2: Add profile matching in HandleDisplayChange()**

```ahk
HandleDisplayChange() {
    global _DisplayChangeTimer, Layouts, Settings, _ActiveRestoreJob
    _DisplayChangeTimer := 0
    if _ActiveRestoreJob
        return  ; Don't interrupt an active restore

    newFP := GetMonitorFingerprint()
    DebugLog("Display changed: " . newFP)

    ; Check settings for explicit profile mapping
    profiles := Settings.Has("monitorProfiles") ? Settings["monitorProfiles"] : Map()
    if profiles.Has(newFP) {
        layoutName := profiles[newFP]
        if Layouts.Has(layoutName) {
            DebugLog("Auto-switching to profile layout: " . layoutName)
            Notify("Monitors changed — restoring '" . layoutName . "'", "normal", 3000)
            Sleep(1000)  ; Let display stabilize
            RestoreLayout(layoutName)
            return
        }
    }

    ; Fallback: find any layout whose fingerprint matches
    for name, layout in Layouts {
        if layout.Has("monitorFingerprint") && layout["monitorFingerprint"] == newFP {
            DebugLog("Auto-switching to matching layout: " . name)
            Notify("Monitors changed — restoring '" . name . "'", "normal", 3000)
            Sleep(1000)
            RestoreLayout(name)
            return
        }
    }

    DebugLog("No layout matches current monitor config: " . newFP)
}
```

**Step 3: Add monitorProfiles to DefaultSettings()**
```ahk
s["monitorProfiles"] := Map()  ; fingerprint -> layoutName
```

**Verify:** Save a layout on your current monitor setup. Change monitor config (e.g., unplug external). Plug back in — layout should auto-restore.

**Commit:** `git commit -m "feat: auto-restore layout when monitor topology changes"`

---

### Task 19: Remember Last Layout Per Monitor Config (#6)

Automatically update the profile mapping when a layout is restored.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — update profile on restore

**Step 1: Save profile on restore**

In `RestoreJob.Done()`, after the success message, add:
```ahk
; Remember this layout for the current monitor config
fp := GetMonitorFingerprint()
global Settings
if !Settings.Has("monitorProfiles")
    Settings["monitorProfiles"] := Map()
Settings["monitorProfiles"][fp] := this.layout["name"]
SaveSettings()
DebugLog("Saved profile mapping: " . fp . " -> " . this.layout["name"])
```

**Verify:** Restore "Work" layout. Check settings.json has a `monitorProfiles` entry mapping your fingerprint to "Work".

**Commit:** `git commit -m "feat: auto-remember layout-to-monitor-config mapping on restore"`

---

### Task 20: Monitor-Disconnect Parking (#5)

When a monitor disappears, move orphaned windows to the primary monitor.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add parking logic to `HandleDisplayChange()`

**Step 1: Add parking function**

```ahk
; Park orphaned windows (on disconnected monitors) onto the primary monitor.
ParkOrphanedWindows() {
    count := MonitorGetCount()
    primary := MonitorGetPrimary()
    workArea := GetMonitorWorkArea(primary)

    DetectHiddenWindows(false)
    hwnds := WinGetList()

    parked := 0
    for hwnd in hwnds {
        if !IsValidWindow(hwnd)
            continue
        try {
            WinGetPos(&x, &y, &w, &h, hwnd)
            cx := x + w // 2
            cy := y + h // 2
            ; Check if center is on any current monitor
            onScreen := false
            Loop count {
                MonitorGet(A_Index, &ml, &mt, &mr, &mb)
                if cx >= ml && cx < mr && cy >= mt && cy < mb {
                    onScreen := true
                    break
                }
            }
            if !onScreen {
                ; Park on primary monitor
                newX := workArea["left"] + 50 + parked * 30
                newY := workArea["top"] + 50 + parked * 30
                try {
                    if WinGetMinMax(hwnd) != 0
                        WinRestore(hwnd)
                    WinMove(newX, newY, Min(w, workArea["w"] - 100), Min(h, workArea["h"] - 100), hwnd)
                }
                parked++
            }
        }
    }
    if parked > 0
        DebugLog("Parked " . parked . " orphaned windows on primary monitor")
    return parked
}
```

**Step 2: Call from HandleDisplayChange()**

In `HandleDisplayChange()`, before the profile matching, add:
```ahk
ParkOrphanedWindows()
```

**Verify:** Put a window on an external monitor. Unplug the monitor. The window should appear on the primary monitor.

**Commit:** `git commit -m "feat: park orphaned windows when monitor disconnects"`

---

### Task 21: DPI-Aware Coordinates (#34)

Normalize coordinates to DPI-independent values so layouts survive scaling changes.

**Files:**
- Modify: `autohotkey/lib/Monitors.ahk` — add DPI helpers
- Modify: `autohotkey/lib/WindowMatch.ahk` — normalize on capture, denormalize on restore

**Step 1: Add DPI functions to Monitors.ahk**

```ahk
; Get the DPI scale factor for a monitor (1.0 = 100%, 1.25 = 125%, etc.)
GetMonitorDPI(monitorIndex) {
    ; Get an HMONITOR for this index by checking a point at the monitor center
    MonitorGet(monitorIndex, &left, &top, &right, &bottom)
    cx := (left + right) // 2
    cy := (top + bottom) // 2
    hMon := DllCall("MonitorFromPoint", "Int64", cx | (cy << 32), "UInt", 0, "Ptr")
    if !hMon
        return 1.0
    dpiX := 0
    dpiY := 0
    hr := DllCall("Shcore\GetDpiForMonitor", "Ptr", hMon, "UInt", 0, "UInt*", &dpiX, "UInt*", &dpiY, "UInt")
    if hr != 0
        return 1.0
    return dpiX / 96.0
}
```

**Step 2: Store DPI with layout**

In `CaptureWindowEntry()`, add:
```ahk
entry["dpi"] := GetMonitorDPI(monIdx)
```

**Step 3: Apply DPI correction in PlaceWindow**

In `PlaceWindow()` (or `BatchPlaceWindows`), when calculating position:
```ahk
; DPI correction: if saved DPI differs from current monitor DPI
if entry.Has("dpi") && entry["dpi"] > 0 {
    currentDPI := GetMonitorDPI(GetMonitorForPoint(entry["x"], entry["y"]))
    if currentDPI > 0 && entry["dpi"] != currentDPI {
        scale := currentDPI / entry["dpi"]
        entry["x"] := Round(entry["x"] * scale)
        entry["y"] := Round(entry["y"] * scale)
        entry["w"] := Round(entry["w"] * scale)
        entry["h"] := Round(entry["h"] * scale)
    }
}
```

**Verify:** Save a layout at 100% DPI. Change display to 125%. Restore — windows should be proportionally scaled.

**Commit:** `git commit -m "feat: DPI-aware coordinate storage and restoration"`

---

## Phase 4: Productivity Features

New user-facing features for power users.

---

### Task 22: Layout Tags/Groups (#12)

Let users tag layouts (e.g., "coding", "meetings") and filter in restore dialog.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add `tags` to layout
- Modify: `autohotkey/lib/UI.ahk` — add tag filter to restore dialog, tag input to save dialog

**Step 1: Add tags to save**

In `ShowSaveDialog()`, after the name Edit, add:
```ahk
saveGui.Add("Text", , "Tags (comma-separated, optional):")
tagEdit := saveGui.Add("Edit", "w260 vTags", "")
```

In `SaveLayout()`, accept tags parameter:
```ahk
SaveLayout(name, tags := "") {
```

Add to layout Map:
```ahk
layout["tags"] := tags != "" ? StrSplit(tags, ",", " ") : []
```

**Step 2: Add filter to restore dialog**

In `ShowRestoreDialog()`, add a filter ComboBox at the top:
```ahk
; Collect all unique tags
allTags := ["All"]
for name in layoutNames {
    if Layouts.Has(name) && Layouts[name].Has("tags") {
        for tag in Layouts[name]["tags"] {
            tag := Trim(tag)
            if tag != "" {
                found := false
                for existing in allTags {
                    if StrLower(existing) == StrLower(tag) {
                        found := true
                        break
                    }
                }
                if !found
                    allTags.Push(tag)
            }
        }
    }
}

if allTags.Length > 1 {
    restGui.Add("Text", , "Filter by tag:")
    tagFilter := restGui.Add("DropDownList", "w200 vTagFilter", allTags)
    tagFilter.Choose(1)
    tagFilter.OnEvent("Change", FilterByTag)
}
```

**Verify:** Save layouts with tags "coding", "meetings". Open restore dialog — filter should show tag dropdown.

**Commit:** `git commit -m "feat: add tag/group support for layout organization"`

---

### Task 23: Quick-Switch Last Two (#14)

Single hotkey to toggle between the two most recently restored layouts.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — track last 2, add hotkey

**Step 1: Track restore history**

```ahk
global _RestoreHistory := []  ; Last 2 restored layout names

_TrackRestore(name) {
    global _RestoreHistory
    ; Don't add duplicates at the top
    if _RestoreHistory.Length > 0 && _RestoreHistory[_RestoreHistory.Length] == name
        return
    _RestoreHistory.Push(name)
    if _RestoreHistory.Length > 2
        _RestoreHistory.RemoveAt(1)
}
```

**Step 2: Call in RestoreLayout()**

After `job.Start()`:
```ahk
_TrackRestore(name)
```

**Step 3: Add hotkey**

```ahk
^!Tab:: QuickSwitchAction()  ; Ctrl+Alt+Tab

QuickSwitchAction() {
    global _RestoreHistory
    if _RestoreHistory.Length < 2 {
        Notify("Need at least 2 restored layouts to quick-switch.", "normal")
        return
    }
    ; Switch to the previous one
    target := _RestoreHistory[1]
    RestoreLayout(target)
}
```

**Verify:** Restore "Work", then restore "Gaming". Press `Ctrl+Alt+Tab` — should switch back to "Work".

**Commit:** `git commit -m "feat: Ctrl+Alt+Tab to quick-switch between last two layouts"`

---

### Task 24: Window Rules Engine (#13)

Define rules like "Slack always on monitor 2" that apply on top of any restore.

**Files:**
- Create: `autohotkey/lib/Rules.ahk`
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — include and apply rules

**Step 1: Create Rules.ahk**

```ahk
; =============================================================================
; Rules.ahk - Window placement rules engine
; Rules apply after restore, overriding layout positions for matched windows.
; =============================================================================

; Apply all rules to currently visible windows.
ApplyWindowRules(rules) {
    if rules.Length == 0
        return
    DetectHiddenWindows(false)
    hwnds := WinGetList()
    applied := 0
    for hwnd in hwnds {
        try {
            exe := StrLower(WinGetProcessName(hwnd))
            title := WinGetTitle(hwnd)
            cls := WinGetClass(hwnd)
            for rule in rules {
                if _RuleMatches(rule, exe, title, cls) {
                    _ApplyRule(hwnd, rule)
                    applied++
                    DebugLog("Rule applied: " . rule["name"] . " -> " . exe)
                    break  ; Only first matching rule per window
                }
            }
        }
    }
    if applied > 0
        DebugLog("Applied " . applied . " window rules")
}

_RuleMatches(rule, exe, title, cls) {
    if rule.Has("exe") && rule["exe"] != "" {
        if StrLower(rule["exe"]) != exe
            return false
    }
    if rule.Has("titleContains") && rule["titleContains"] != "" {
        if !InStr(title, rule["titleContains"])
            return false
    }
    return true
}

_ApplyRule(hwnd, rule) {
    if rule.Has("monitor") && rule["monitor"] > 0 {
        count := MonitorGetCount()
        if rule["monitor"] <= count {
            area := GetMonitorWorkArea(rule["monitor"])
            ; Position within the target monitor based on rule
            x := area["left"]
            y := area["top"]
            w := area["w"]
            h := area["h"]
            if rule.Has("position") {
                pos := rule["position"]
                if pos == "left-half" {
                    w := w // 2
                } else if pos == "right-half" {
                    x := x + w // 2
                    w := w // 2
                } else if pos == "top-half" {
                    h := h // 2
                } else if pos == "bottom-half" {
                    y := y + h // 2
                    h := h // 2
                } else if pos == "maximized" {
                    try WinMaximize(hwnd)
                    return
                } else if pos == "minimized" {
                    try WinMinimize(hwnd)
                    return
                }
            }
            try {
                if WinGetMinMax(hwnd) != 0
                    WinRestore(hwnd)
                WinMove(x, y, w, h, hwnd)
            }
        }
    }
    if rule.Has("state") {
        if rule["state"] == "maximized"
            try WinMaximize(hwnd)
        else if rule["state"] == "minimized"
            try WinMinimize(hwnd)
    }
}
```

**Step 2: Include and apply**

In `WorkspaceLayoutManager.ahk`:
```ahk
#Include lib\Rules.ahk
```

Add `windowRules` to `DefaultSettings()`:
```ahk
s["windowRules"] := []  ; Array of rule Maps
```

In `RestoreJob.Done()`, after placement:
```ahk
rules := Settings.Has("windowRules") ? Settings["windowRules"] : []
ApplyWindowRules(rules)
```

**Verify:** Manually add a rule to settings.json: `[{"name":"Slack right","exe":"slack.exe","monitor":2,"position":"right-half"}]`. Restore — Slack should move to monitor 2, right half.

**Commit:** `git commit -m "feat: window rules engine for persistent placement overrides"`

---

### Task 25: Layout Scheduling (#15)

Auto-restore layouts at specific times.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add schedule timer

**Step 1: Add schedule settings**

In `DefaultSettings()`:
```ahk
s["schedules"] := []  ; Array of {time: "HH:MM", days: "mon,tue,...", layout: "name"}
```

**Step 2: Add schedule checker**

```ahk
global _LastScheduleCheck := ""

CheckSchedules() {
    global Settings, Layouts, _ActiveRestoreJob, _LastScheduleCheck
    if _ActiveRestoreJob
        return
    schedules := Settings.Has("schedules") ? Settings["schedules"] : []
    if schedules.Length == 0
        return

    now := FormatTime(, "HH:mm")
    today := FormatTime(, "ddd")  ; Mon, Tue, etc.
    todayLower := StrLower(today)

    ; Prevent firing same schedule twice in the same minute
    if now == _LastScheduleCheck
        return

    for sched in schedules {
        if !sched.Has("time") || !sched.Has("layout")
            continue
        if sched["time"] != now
            continue
        ; Check day filter if present
        if sched.Has("days") && sched["days"] != "" {
            days := StrLower(sched["days"])
            if !InStr(days, todayLower)
                continue
        }
        if Layouts.Has(sched["layout"]) {
            _LastScheduleCheck := now
            DebugLog("Schedule triggered: " . sched["layout"] . " at " . now)
            Notify("Scheduled restore: " . sched["layout"], "normal")
            RestoreLayout(sched["layout"])
            return  ; Only one schedule per minute
        }
    }
}
```

**Step 3: Start schedule timer**

In `Initialize()`:
```ahk
SetTimer(CheckSchedules, 30000)  ; Check every 30 seconds
```

**Verify:** Add a schedule in settings.json for 1 minute from now. Wait — layout should auto-restore at the scheduled time.

**Commit:** `git commit -m "feat: time-based layout scheduling"`

---

### Task 26: Import/Export Layouts (#16)

Export a single layout to a standalone JSON file, import from file.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add Export/Import buttons to Manage dialog
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add Import/Export functions

**Step 1: Add functions**

```ahk
ExportLayout(name) {
    global Layouts, AppName
    if !Layouts.Has(name) {
        NotifyError("Layout '" . name . "' not found.")
        return
    }
    path := FileSelect("S16", name . ".json", "Export Layout", "JSON Files (*.json)")
    if path == ""
        return
    try {
        content := JSON.Stringify(Layouts[name])
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
        Notify("Exported '" . name . "' to " . path)
    } catch as e {
        NotifyError("Export failed: " . e.Message)
    }
}

ImportLayout() {
    global Layouts
    path := FileSelect(1, , "Import Layout", "JSON Files (*.json)")
    if path == ""
        return
    try {
        raw := FileRead(path, "UTF-8")
        layout := JSON.Parse(raw)
        if !layout.Has("name") || !layout.Has("windows") {
            NotifyError("Invalid layout file: missing 'name' or 'windows'.")
            return
        }
        name := layout["name"]
        if Layouts.Has(name) {
            if MsgBox("Layout '" . name . "' already exists. Overwrite?", "Import", "YesNo Icon?") == "No"
                return
        }
        Layouts[name] := layout
        SaveLayouts()
        Notify("Imported layout: " . name . " (" . layout["windows"].Length . " windows)")
    } catch as e {
        NotifyError("Import failed: " . e.Message)
    }
}
```

**Step 2: Add buttons to Manage dialog**

In `ShowManageDialog()`, add export/import buttons:
```ahk
btnExport := mgGui.Add("Button", "xm y+6 w110", "Export")
btnImport := mgGui.Add("Button", "x+6 w110", "Import")

OnExport(*) {
    name := GetSelectedName()
    if name == "" {
        MsgBox("Select a layout first.", "Export", "Icon!")
        return
    }
    ExportLayout(name)
}
OnImport(*) {
    ImportLayout()
    RefreshList()
}
btnExport.OnEvent("Click", OnExport)
btnImport.OnEvent("Click", OnImport)
```

**Verify:** Export a layout. Import it on the same (or different) machine. Layout should appear in the list.

**Commit:** `git commit -m "feat: import/export individual layouts as JSON files"`

---

### Task 27: Snapshot Diff View (#17)

Show differences between current window state and a saved layout.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add diff to restore dialog preview

**Step 1: Add diff function**

In `WindowMatch.ahk`:
```ahk
; Compare current windows to a saved layout.
; Returns Map with keys: matched, moved, new, missing
SnapshotDiff(savedWindows) {
    current := CaptureAllWindows()
    result := Map("matched", [], "moved", [], "new", [], "missing", [])

    ; Build lookup of current windows by exe+cleanTitle
    currentMap := Map()
    for w in current {
        key := StrLower(w["exe"]) . "|" . StrLower(w["cleanTitle"])
        currentMap[key] := w
    }

    ; Check each saved window
    for saved in savedWindows {
        key := StrLower(saved["exe"]) . "|" . StrLower(saved["cleanTitle"])
        if currentMap.Has(key) {
            cur := currentMap[key]
            tolerance := 10
            if Abs(cur["x"] - saved["x"]) <= tolerance
                && Abs(cur["y"] - saved["y"]) <= tolerance
                && Abs(cur["w"] - saved["w"]) <= tolerance
                && Abs(cur["h"] - saved["h"]) <= tolerance
                && cur["state"] == saved["state"] {
                result["matched"].Push(saved)
            } else {
                result["moved"].Push(saved)
            }
            currentMap.Delete(key)
        } else {
            result["missing"].Push(saved)
        }
    }

    ; Remaining current windows are "new"
    for key, w in currentMap
        result["new"].Push(w)

    return result
}
```

**Step 2: Add diff button to restore dialog**

In `ShowRestoreDialog()`, add a "Compare" button:
```ahk
btnDiff := restGui.Add("Button", "x+8 w100", "Compare")
OnDiff(*) {
    idx := lb.Value
    if idx == 0
        return
    name := layoutNames[idx]
    if !Layouts.Has(name)
        return
    diff := SnapshotDiff(Layouts[name]["windows"])
    lines := "=== Diff: " . name . " vs Current ===`r`n`r`n"
    lines .= "In place: " . diff["matched"].Length . "`r`n"
    lines .= "Moved: " . diff["moved"].Length . "`r`n"
    lines .= "Missing: " . diff["missing"].Length . "`r`n"
    lines .= "New windows: " . diff["new"].Length . "`r`n"
    if diff["moved"].Length > 0 {
        lines .= "`r`n-- Moved --`r`n"
        for w in diff["moved"]
            lines .= "  " . w["exe"] . " - " . w["cleanTitle"] . "`r`n"
    }
    if diff["missing"].Length > 0 {
        lines .= "`r`n-- Missing --`r`n"
        for w in diff["missing"]
            lines .= "  " . w["exe"] . " - " . w["cleanTitle"] . "`r`n"
    }
    preview.Value := lines
}
btnDiff.OnEvent("Click", OnDiff)
```

**Verify:** Save a layout. Move some windows. Open restore dialog, click Compare. Preview should show which windows moved or are missing.

**Commit:** `git commit -m "feat: snapshot diff view comparing current state to saved layout"`

---

### Task 28: CLI Mode (#18)

Support command-line arguments for automation.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — parse `A_Args` before `Initialize()`

**Step 1: Add CLI argument parsing**

Before `Initialize()` at the bottom of the file, replace `Initialize()` with:

```ahk
; CLI mode: support /save "name" and /restore "name"
if A_Args.Length > 0 {
    cmd := StrLower(A_Args[1])
    if cmd == "/save" || cmd == "--save" {
        name := A_Args.Length > 1 ? A_Args[2] : "QuickSave"
        ; Minimal init for CLI
        DirCreate(AppDir)
        VD_Init()
        Settings := LoadSettings()
        Layouts := LoadLayouts()
        DebugMode := Settings.Has("debugMode") && Settings["debugMode"]
        SaveLayout(name)
        ExitApp()
    }
    else if cmd == "/restore" || cmd == "--restore" {
        if A_Args.Length < 2 {
            MsgBox("Usage: script.ahk /restore <name>", "CLI Error")
            ExitApp()
        }
        name := A_Args[2]
        DirCreate(AppDir)
        VD_Init()
        Settings := LoadSettings()
        Layouts := LoadLayouts()
        DebugMode := Settings.Has("debugMode") && Settings["debugMode"]
        RestoreLayout(name)
        ; Keep running until restore completes
        return
    }
    else if cmd == "/list" || cmd == "--list" {
        DirCreate(AppDir)
        Settings := LoadSettings()
        Layouts := LoadLayouts()
        names := GetLayoutNames()
        list := ""
        for name in names
            list .= name . "`n"
        MsgBox(list != "" ? list : "(no layouts)", "Saved Layouts")
        ExitApp()
    }
}

; Normal GUI mode
Initialize()
```

**Verify:** Run from command line: `AutoHotkey.exe WorkspaceLayoutManager.ahk /save "Test"`. Check layout is saved. Run `/list` — should show all layouts.

**Commit:** `git commit -m "feat: CLI mode (/save, /restore, /list) for automation"`

---

### Task 29: Hotkey to Cycle Layouts (#41)

Cycle through layouts with a hotkey.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add cycle hotkey

**Step 1: Add cycle state and hotkey**

```ahk
global _CycleIndex := 0

^!n:: CycleLayoutAction()  ; Ctrl+Alt+N = Next layout

CycleLayoutAction() {
    global _CycleIndex
    names := GetLayoutNames()
    if names.Length == 0 {
        Notify("No layouts to cycle through.", "normal")
        return
    }
    _CycleIndex++
    if _CycleIndex > names.Length
        _CycleIndex := 1
    name := names[_CycleIndex]
    Notify("Cycling to: " . name . " (" . _CycleIndex . "/" . names.Length . ")", "verbose")
    RestoreLayout(name)
}
```

**Step 2: Add to tray menu**

In `SetupTray()`:
```ahk
tray.Add("Next Layout`tCtrl+Alt+N", _OnCycle)
```

With handler:
```ahk
_OnCycle(*) {
    CycleLayoutAction()
}
```

**Verify:** Save 3 layouts. Press `Ctrl+Alt+N` three times — should cycle through all three.

**Commit:** `git commit -m "feat: Ctrl+Alt+N to cycle through layouts"`

---

### Task 30: Browser URL Capture (#20)

Use the Accessibility API to get the URL from browser address bars. This is the most complex feature.

**Files:**
- Create: `autohotkey/lib/BrowserURL.ahk`
- Modify: `autohotkey/lib/WindowMatch.ahk` — integrate URL capture

**Step 1: Create BrowserURL.ahk**

```ahk
; =============================================================================
; BrowserURL.ahk - Extract URLs from browser windows via UI Automation
; =============================================================================

; Get the URL from a browser window's address bar using UI Automation.
; Works with Chrome, Edge, Firefox, Brave.
; Returns URL string or "" on failure.
GetBrowserURL(hwnd) {
    try {
        ; Create IUIAutomation instance
        static CLSID_CUIAutomation := "{ff48dba4-60ef-4201-aa87-54103eef594e}"
        static IID_IUIAutomation   := "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}"

        clsid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", CLSID_CUIAutomation, "Ptr", clsid)
        iid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", IID_IUIAutomation, "Ptr", iid)

        pAuto := 0
        hr := DllCall("ole32\CoCreateInstance", "Ptr", clsid, "Ptr", 0,
            "UInt", 1, "Ptr", iid, "Ptr*", &pAuto, "UInt")
        if hr != 0 || !pAuto
            return ""

        ; Get element from hwnd
        pElement := 0
        hr := ComCall(6, pAuto, "Ptr", hwnd, "Ptr*", &pElement)  ; ElementFromHandle
        if hr != 0 || !pElement {
            ObjRelease(pAuto)
            return ""
        }

        ; Create condition: ControlType == Edit (for address bar)
        ; UIA_EditControlTypeId = 50004
        pCondition := 0
        propVariant := Buffer(24, 0)
        NumPut("UShort", 3, propVariant, 0)   ; VT_I4
        NumPut("Int", 50004, propVariant, 8)   ; UIA_EditControlTypeId
        hr := ComCall(23, pAuto, "Int", 30003, "Ptr", propVariant, "Ptr*", &pCondition)

        if hr != 0 || !pCondition {
            ObjRelease(pElement)
            ObjRelease(pAuto)
            return ""
        }

        ; FindFirst with scope=Descendants (4)
        pFound := 0
        hr := ComCall(5, pElement, "Int", 4, "Ptr", pCondition, "Ptr*", &pFound)

        url := ""
        if hr == 0 && pFound {
            ; Get Value pattern
            pValue := 0
            hr := ComCall(16, pFound, "Int", 10002, "Ptr*", &pValue)  ; GetCurrentPattern, ValuePatternId
            if hr == 0 && pValue {
                pStr := 0
                hr := ComCall(3, pValue, "Ptr*", &pStr)  ; get_CurrentValue
                if hr == 0 && pStr {
                    url := StrGet(pStr, "UTF-16")
                    DllCall("OleAut32\SysFreeString", "Ptr", pStr)
                }
                ObjRelease(pValue)
            }
            ObjRelease(pFound)
        }

        ObjRelease(pCondition)
        ObjRelease(pElement)
        ObjRelease(pAuto)
        return url
    } catch {
        return ""
    }
}
```

**Step 2: Integrate in CaptureWindowEntry**

In `WindowMatch.ahk`, in `CaptureWindowEntry()`:
```ahk
; Browser URL capture
browserUrl := ""
static browserExes := Map("msedge.exe", 1, "chrome.exe", 1, "firefox.exe", 1, "brave.exe", 1)
if browserExes.Has(StrLower(exe)) {
    browserUrl := GetBrowserURL(hwnd)
}
entry["browserUrl"] := browserUrl
```

**Step 3: Use URL in LaunchMissingApps**

For browser windows with a URL, launch the browser with that URL:
```ahk
if entry.Has("browserUrl") && entry["browserUrl"] != "" {
    cmd := '"' . path . '" "' . entry["browserUrl"] . '"'
    DebugLog("LaunchMissing (URL): " . cmd)
    try Run(cmd)
}
```

**Verify:** Open Edge/Chrome with a specific URL. Save layout. Close browser. Restore — browser should open with that URL.

**Commit:** `git commit -m "feat: capture and restore browser URLs via UI Automation"`

---

## Phase 5: UI Overhaul

Make it look and feel like a polished app, not a script.

---

### Task 31: Smooth Toast Notifications (#23)

Replace ToolTip with a custom slide-in panel.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — replace `ShowToast` with custom Gui

**Step 1: Replace ShowToast**

```ahk
global _ToastGui := false
global _ToastTimer := 0

ShowToast(msg, durationMs := 3000) {
    global _ToastGui, _ToastTimer

    ; Destroy previous toast
    if _ToastGui {
        try _ToastGui.Destroy()
        _ToastGui := false
    }
    if _ToastTimer {
        SetTimer(_ToastTimer, 0)
        _ToastTimer := 0
    }

    ; Create borderless dark toast
    toast := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")  ; E0x20 = click-through
    toast.BackColor := "1A1A2E"
    toast.SetFont("s10 cFFFFFF", "Segoe UI")
    toast.MarginX := 16
    toast.MarginY := 10
    toast.Add("Text", "cFFFFFF", msg)

    ; Position at bottom-right of primary monitor
    workArea := GetMonitorWorkArea(MonitorGetPrimary())
    toast.Show("NoActivate Hide")
    toast.GetPos(, , &tw, &th)
    tx := workArea["right"] - tw - 16
    ty := workArea["bottom"] - th - 16
    toast.Show("NoActivate x" . tx . " y" . ty)

    ; Rounded corners (Windows 11)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", toast.Hwnd,
        "UInt", 33, "Int*", 2, "UInt", 4)  ; DWMWA_WINDOW_CORNER_PREFERENCE = round

    _ToastGui := toast

    ; Auto-dismiss
    dismissFn := DismissToast
    _ToastTimer := dismissFn
    SetTimer(dismissFn, -durationMs)
}

DismissToast() {
    global _ToastGui, _ToastTimer
    if _ToastGui {
        try _ToastGui.Destroy()
        _ToastGui := false
    }
    _ToastTimer := 0
}
```

**Verify:** Reload script. The startup toast should appear as a dark rounded pill in the bottom-right. Should auto-dismiss.

**Commit:** `git commit -m "feat: modern dark toast notifications replacing ToolTip"`

---

### Task 32: Custom Tray Icon States (#24)

Use different shell32 icons for different states.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add icon state functions

**Step 1: Add icon helpers**

```ahk
; Icon states: idle (default), working (spinning), error (red)
SetTrayIconState(state) {
    switch state {
        case "idle":
            try TraySetIcon("shell32.dll", 162)  ; Grid icon
        case "working":
            try TraySetIcon("shell32.dll", 239)  ; Sync/arrow icon
        case "error":
            try TraySetIcon("shell32.dll", 110)  ; Warning icon
        case "success":
            try TraySetIcon("shell32.dll", 297)  ; Checkmark icon
    }
}
```

**Step 2: Use throughout the app**

- `RestoreJob.Start()`: `SetTrayIconState("working")`
- `RestoreJob.Done()` success: `SetTrayIconState("success")` then `SetTimer(() => SetTrayIconState("idle"), -3000)`
- `RestoreJob.Done()` with missing: `SetTrayIconState("error")` then `SetTimer(() => SetTrayIconState("idle"), -5000)`
- `SaveLayout()`: briefly flash success icon
- `NotifyError()`: set error icon

**Verify:** Restore a layout. Tray icon should change to "working" during restore, then "success" briefly, then back to normal.

**Commit:** `git commit -m "feat: tray icon changes to reflect current state"`

---

### Task 33: Restore Progress Bar (#26)

Show a visual progress bar instead of text counter.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — replace `ShowProgress` with a progress GUI

**Step 1: Replace ShowProgress**

```ahk
global _ProgressGui := false
global _ProgressBar := false
global _ProgressText := false

ShowProgress(msg) {
    global _ProgressGui, _ProgressBar, _ProgressText
    ; Parse "X/Y placed" to get a percentage
    if _ProgressGui {
        try _ProgressText.Text := msg
        RegExMatch(msg, "(\d+)/(\d+)", &m)
        if m {
            pct := Round(m[1] / m[2] * 100)
            try _ProgressBar.Value := pct
        }
        return
    }

    pg := Gui("+AlwaysOnTop -Caption +ToolWindow")
    pg.BackColor := "1A1A2E"
    pg.SetFont("s9 cFFFFFF", "Segoe UI")
    pg.MarginX := 12
    pg.MarginY := 8
    _ProgressText := pg.Add("Text", "cFFFFFF w280", msg)
    _ProgressBar := pg.Add("Progress", "w280 h6 cGreen Background333333", 0)

    ; Position at bottom-right
    workArea := GetMonitorWorkArea(MonitorGetPrimary())
    pg.Show("NoActivate Hide")
    pg.GetPos(, , &pw, &ph)
    px := workArea["right"] - pw - 16
    py := workArea["bottom"] - ph - 60  ; Above toast position
    pg.Show("NoActivate x" . px . " y" . py)

    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", pg.Hwnd,
        "UInt", 33, "Int*", 2, "UInt", 4)

    _ProgressGui := pg
}

HideProgress() {
    global _ProgressGui, _ProgressBar, _ProgressText
    if _ProgressGui {
        try _ProgressGui.Destroy()
        _ProgressGui := false
        _ProgressBar := false
        _ProgressText := false
    }
}
```

**Verify:** Restore a large layout. A dark progress bar should appear at the bottom-right showing percentage.

**Commit:** `git commit -m "feat: visual progress bar during restore"`

---

### Task 34: Silent Startup (#29)

Option to show no notification on startup.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — gate startup toast

**Step 1: Gate the startup toast**

In `Initialize()`, replace the `ShowToast()` call:
```ahk
Notify("Workspace Layout Manager running  (Ctrl+Alt+S = Save, Ctrl+Alt+Q = Quick-save, Ctrl+Alt+R = Restore)", "verbose", 4000)
```

This uses the notification level system from Task 1. In "normal" mode, the startup toast is suppressed (it's "verbose" level). In "verbose" mode, it shows.

**Verify:** Set notification level to "normal". Reload — no startup toast. Set to "verbose" — toast appears.

**Commit:** `git commit -m "feat: silent startup (controlled by notification level)"`

---

### Task 35: Silent Auto-Restore (#31)

Only notify on auto-restore failure.

**Files:**
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — gate auto-restore toast

**Step 1: Make auto-restore quiet**

In `Initialize()`, change the auto-restore SetTimer:
```ahk
if Settings.Has("autoRestore") && Settings["autoRestore"]
    && Settings.Has("startupLayout") && Settings["startupLayout"] != "" {
    delay := Settings.Has("restoreDelay") ? Settings["restoreDelay"] * 1000 : 10000
    SetTimer(() => RestoreLayout(Settings["startupLayout"], true), -delay)
}
```

Update `RestoreLayout` to accept a `silent` parameter:
```ahk
RestoreLayout(name, silent := false) {
    global Layouts, Settings, _ActiveRestoreJob
    if !Layouts.Has(name) {
        if !silent
            NotifyError("Layout '" . name . "' not found.")
        return
    }
    DebugLog("=== Restoring layout: " . name . " ===")
    if !silent
        Notify("Restoring: " . name . "...")
    job := RestoreJob(Layouts[name], Settings, silent)
    global _ActiveRestoreJob := job
    job.Start()
}
```

Update `RestoreJob.__New` to accept `silent`:
```ahk
__New(layout, settings, silent := false) {
    this.silent := silent
    ; ... rest unchanged
}
```

In `RestoreJob.Done()`, gate notifications:
```ahk
if this.remaining.Length > 0 {
    ; Always notify about missing windows (even in silent mode)
    NotifyError(msg)
} else {
    if !this.silent
        Notify(msg, "normal", 4000)
}
```

**Verify:** Enable auto-restore. Reboot. Layout should restore silently (no popups). If windows are missing, error still shows.

**Commit:** `git commit -m "feat: silent auto-restore on login (notify only on failure)"`

---

### Task 36: Replace MsgBox With Log + Tray (#30)

Route all error MsgBox calls through `NotifyError` (already done in Task 1). Additionally, keep an error history viewable from tray.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add error history
- Modify: `autohotkey/lib/UI.ahk` — add "Error Log" tray menu item

**Step 1: Add error history**

```ahk
global _ErrorHistory := []

; Append to error history and show notification
LogError(msg, title := "Error") {
    global _ErrorHistory
    _ErrorHistory.Push(Map("time", FormatTime(, "HH:mm:ss"), "msg", msg, "title", title))
    if _ErrorHistory.Length > 50
        _ErrorHistory.RemoveAt(1)
    NotifyError(msg, title)
}
```

**Step 2: Add tray menu item**

In `SetupTray()`:
```ahk
_OnErrorLog(*) {
    ShowErrorLog()
}
tray.Add("Error Log", _OnErrorLog)
```

**Step 3: Add error log viewer**

```ahk
ShowErrorLog() {
    global _ErrorHistory
    logGui := Gui("+Resize +MinSize400x200", "Error Log")
    logGui.SetFont("s9", "Consolas")
    logGui.MarginX := 8
    logGui.MarginY := 8

    content := ""
    if _ErrorHistory.Length == 0 {
        content := "(no errors)"
    } else {
        for err in _ErrorHistory
            content .= "[" . err["time"] . "] " . err["title"] . ": " . err["msg"] . "`r`n`r`n"
    }

    logGui.Add("Edit", "w500 h300 ReadOnly -WantReturn", content)
    logGui.Add("Button", "Default w80", "Close").OnEvent("Click", (*) => logGui.Destroy())
    logGui.OnEvent("Close", (*) => logGui.Destroy())
    logGui.Show()
}
```

**Step 4: Replace remaining MsgBox error calls**

Search for all `MsgBox(..., "IconX")` or `MsgBox(..., "Icon!")` and replace with `LogError()`.

**Verify:** Trigger an error (e.g., corrupt layouts.json). Click "Error Log" in tray — should show the error.

**Commit:** `git commit -m "feat: error log viewer in tray menu, replacing modal MsgBox errors"`

---

### Task 37: Tabbed Settings Dialog (#25)

Split settings into tabs: General, Startup, Advanced.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — rewrite `ShowSettingsDialog()` with Tab3 control

**Step 1: Rewrite with tabs**

```ahk
ShowSettingsDialog() {
    global Settings, Layouts

    setGui := Gui("+AlwaysOnTop +Owner", "Settings - Workspace Layout Manager")
    setGui.SetFont("s10", "Segoe UI")
    setGui.MarginX := 14
    setGui.MarginY := 10

    tabs := setGui.Add("Tab3", "w380 h340", ["General", "Startup", "Advanced"])

    ; ---- Tab 1: General ----
    tabs.UseTab(1)
    cbLaunch := setGui.Add("Checkbox", "vLaunchMissing", "Launch missing apps when restoring")
    cbLaunch.Value := Settings.Has("launchMissing") ? Settings["launchMissing"] : 0

    setGui.Add("Text", "xp y+10", "Auto-save interval (minutes, 0 = disabled):")
    autoSaveEdit := setGui.Add("Edit", "w70 Number vAutoSaveMinutes",
        Settings.Has("autoSaveMinutes") ? Settings["autoSaveMinutes"] : 15)

    setGui.Add("Text", "xp y+10", "Notification level:")
    levels := ["verbose", "normal", "silent", "errors"]
    ddlNotif := setGui.Add("DropDownList", "w200 vNotificationLevel", levels)
    currentLevel := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    notifIdx := 2
    Loop levels.Length {
        if levels[A_Index] == currentLevel {
            notifIdx := A_Index
            break
        }
    }
    ddlNotif.Choose(notifIdx)

    ; ---- Tab 2: Startup ----
    tabs.UseTab(2)
    cbAuto := setGui.Add("Checkbox", "vAutoRestore", "Auto-restore layout on Windows login")
    cbAuto.Value := Settings.Has("autoRestore") ? Settings["autoRestore"] : 0

    setGui.Add("Text", "xp y+10", "Startup layout:")
    names := ["(none)"]
    for k, _ in Layouts
        names.Push(k)
    ddl := setGui.Add("DropDownList", "w250 vStartupLayout", names)
    startupVal := Settings.Has("startupLayout") ? Settings["startupLayout"] : ""
    choiceIdx := 1
    Loop names.Length {
        if names[A_Index] == startupVal {
            choiceIdx := A_Index
            break
        }
    }
    ddl.Choose(choiceIdx)

    setGui.Add("Text", "xp y+10", "Restore delay after login (seconds):")
    delayEdit := setGui.Add("Edit", "w70 Number vRestoreDelay",
        Settings.Has("restoreDelay") ? Settings["restoreDelay"] : 10)

    setGui.Add("GroupBox", "xp y+14 w350 h68", "Windows Startup Integration")
    OnAddStartup(*) {
        AddToStartup()
        Notify("Added to Windows startup.", "verbose")
    }
    OnRemoveStartup(*) {
        RemoveFromStartup()
        Notify("Removed from Windows startup.", "verbose")
    }
    setGui.Add("Button", "xp+10 yp+22 w155", "Add to Startup").OnEvent("Click", OnAddStartup)
    setGui.Add("Button", "x+8 w155", "Remove from Startup").OnEvent("Click", OnRemoveStartup)

    ; ---- Tab 3: Advanced ----
    tabs.UseTab(3)
    cbDebug := setGui.Add("Checkbox", "vDebugMode", "Debug mode (log to debug.log)")
    cbDebug.Value := Settings.Has("debugMode") ? Settings["debugMode"] : 0

    setGui.Add("Text", "xp y+10", "Max layout versions to keep:")
    setGui.Add("Edit", "w70 Number vMaxLayoutVersions",
        Settings.Has("maxLayoutVersions") ? Settings["maxLayoutVersions"] : 3)

    ; ---- Buttons (outside tabs) ----
    tabs.UseTab(0)
    setGui.Add("Button", "xm y+14 Default w100", "Save").OnEvent("Click", OnSave)
    setGui.Add("Button", "x+8 w90", "Cancel").OnEvent("Click", (*) => setGui.Destroy())

    OnSave(*) {
        saved := setGui.Submit(false)
        Settings["autoRestore"]       := saved.AutoRestore
        Settings["restoreDelay"]      := saved.RestoreDelay != "" ? Integer(saved.RestoreDelay) : 10
        Settings["launchMissing"]     := saved.LaunchMissing
        Settings["autoSaveMinutes"]   := saved.AutoSaveMinutes != "" ? Integer(saved.AutoSaveMinutes) : 15
        Settings["debugMode"]         := saved.DebugMode
        Settings["notificationLevel"] := ddlNotif.Text
        Settings["maxLayoutVersions"] := saved.MaxLayoutVersions != "" ? Integer(saved.MaxLayoutVersions) : 3

        chosen := ddl.Text
        Settings["startupLayout"] := (chosen == "(none)") ? "" : chosen

        global DebugMode
        DebugMode := Settings["debugMode"]

        autoMin := Settings["autoSaveMinutes"]
        if autoMin > 0 {
            SetTimer(AutoSave, autoMin * 60000)
        } else {
            SetTimer(AutoSave, 0)
        }

        SaveSettings()
        setGui.Destroy()
        Notify("Settings saved.", "verbose")
    }

    setGui.OnEvent("Close", (*) => setGui.Destroy())
    setGui.Show()
}
```

**Verify:** Open Settings. Three tabs should be visible. All settings should persist correctly.

**Commit:** `git commit -m "feat: tabbed settings dialog (General/Startup/Advanced)"`

---

### Task 38: Dark-Mode Modern GUIs (#22)

Apply dark theme to all dialogs.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add dark theme helper, apply to all Gui creation

**Step 1: Add dark theme function**

```ahk
; Apply dark mode to a Gui window
ApplyDarkTheme(guiObj) {
    guiObj.BackColor := "1E1E2E"  ; Dark background
    guiObj.SetFont("cE0E0E0")     ; Light text

    ; Enable dark title bar (Windows 10 1809+)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd,
        "UInt", 20, "Int*", 1, "UInt", 4)  ; DWMWA_USE_IMMERSIVE_DARK_MODE

    ; Rounded corners (Windows 11)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd,
        "UInt", 33, "Int*", 2, "UInt", 4)
}
```

**Step 2: Apply to all dialogs**

After each `guiObj.Show()` (or before), call `ApplyDarkTheme(guiObj)`. Apply to:
- Save dialog
- Restore dialog
- Manage dialog
- Settings dialog
- Error log dialog
- Status window

Note: AHK v2's built-in controls (Edit, ListBox, ListView, Button) have limited dark mode support. The title bar and background will be dark. Control colors require DllCall to `SetWindowTheme` or `uxtheme`:

```ahk
; Force dark theme on controls
static DarkThemeControls(guiObj) {
    for ctrl in guiObj {
        try DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
    }
}
```

Call after adding all controls.

**Verify:** Open any dialog. It should have a dark title bar and dark background.

**Commit:** `git commit -m "feat: dark mode for all GUI dialogs"`

---

### Task 39: Visual Layout Map (#21)

Show a miniature diagram of monitors with colored rectangles for windows.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — add layout map to restore dialog

**Step 1: Add map drawing**

This uses GDI+ to draw a miniature representation. In the restore dialog, add a Picture control:

```ahk
; Create a visual map of a layout on monitors.
; Returns an HBITMAP that can be used with a Picture control.
DrawLayoutMap(layout, mapW := 320, mapH := 180) {
    ; Get all monitor bounds
    monitors := GetAllMonitorInfo()
    if monitors.Length == 0
        return 0

    ; Find bounding box of all monitors
    minX := 99999
    minY := 99999
    maxX := -99999
    maxY := -99999
    for m in monitors {
        if m["left"] < minX
            minX := m["left"]
        if m["top"] < minY
            minY := m["top"]
        if m["right"] > maxX
            maxX := m["right"]
        if m["bottom"] > maxY
            maxY := m["bottom"]
    }

    totalW := maxX - minX
    totalH := maxY - minY
    scale := Min((mapW - 20) / totalW, (mapH - 20) / totalH)

    ; GDI+ init
    token := 0
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)

    ; Create bitmap
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", mapW, "Int", mapH,
        "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)

    ; Clear background
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", pGraphics, "UInt", 0xFF1E1E2E)

    ; Draw monitors as gray rectangles
    pBrushMon := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF333355, "Ptr*", &pBrushMon)
    for m in monitors {
        mx := Round((m["left"] - minX) * scale) + 10
        my := Round((m["top"] - minY) * scale) + 10
        mw := Round(m["w"] * scale)
        mh := Round(m["h"] * scale)
        DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBrushMon,
            "Int", mx, "Int", my, "Int", mw, "Int", mh)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushMon)

    ; Draw windows as colored rectangles
    if layout.Has("windows") {
        colors := [0xFF4EC9B0, 0xFF569CD6, 0xFFCE9178, 0xFFDCDCAA,
                   0xFFC586C0, 0xFF9CDCFE, 0xFF6A9955, 0xFFD7BA7D]
        pBrush := 0
        for i, w in layout["windows"] {
            colorIdx := Mod(i - 1, colors.Length) + 1
            DllCall("gdiplus\GdipCreateSolidFill", "UInt", colors[colorIdx], "Ptr*", &pBrush)
            wx := Round((w["x"] - minX) * scale) + 10
            wy := Round((w["y"] - minY) * scale) + 10
            ww := Max(Round(w["w"] * scale), 4)
            wh := Max(Round(w["h"] * scale), 4)
            DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBrush,
                "Int", wx, "Int", wy, "Int", ww, "Int", wh)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
        }
    }

    ; Convert to HBITMAP
    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap, "UInt", 0xFF1E1E2E)

    ; Cleanup
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", token)

    return hBitmap
}
```

**Step 2: Use in restore dialog**

In `ShowRestoreDialog()`, add a Picture control and update it in `UpdatePreview()`:
```ahk
layoutMap := restGui.Add("Picture", "x+10 yp w320 h180 +0xE")  ; SS_BITMAP

; In UpdatePreview():
hBitmap := DrawLayoutMap(layout)
if hBitmap {
    SendMessage(0x0172, 0, hBitmap, layoutMap.Hwnd)  ; STM_SETIMAGE
}
```

**Verify:** Open restore dialog. Select a layout — miniature colored rectangles should show window positions on monitors.

**Commit:** `git commit -m "feat: visual layout map preview in restore dialog"`

---

### Task 40: Manage Dialog With App Icons (#27)

Show app icons next to window entries in the manage/restore dialogs.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — extract icons from exe paths, use ImageList with ListView

**Step 1: Add icon extraction**

```ahk
; Build an ImageList from a list of exe paths.
; Returns ImageList ID for use with ListView.
BuildIconList(entries) {
    hIL := DllCall("comctl32\ImageList_Create", "Int", 16, "Int", 16, "UInt", 0x20, "Int", entries.Length, "Int", 10, "Ptr")
    for entry in entries {
        path := entry.Has("exePath") && entry["exePath"] != "" ? entry["exePath"] : entry["exe"]
        hIcon := 0
        DllCall("shell32\ExtractIconExW", "Str", path, "Int", 0, "Ptr", 0, "Ptr*", &hIcon, "UInt", 1)
        if hIcon {
            DllCall("comctl32\ImageList_AddIcon", "Ptr", hIL, "Ptr", hIcon)
            DllCall("DestroyIcon", "Ptr", hIcon)
        } else {
            ; Add blank placeholder
            DllCall("comctl32\ImageList_AddIcon", "Ptr", hIL, "Ptr", 0)
        }
    }
    return hIL
}
```

**Step 2: Apply to Manage dialog ListView**

In `ShowManageDialog()`, when creating the ListView, set up an ImageList with app icons from the layout's first few windows.

This is complex to integrate fully — the key concept is `LV.SetImageList(hIL, 1)` for small icons.

**Verify:** Open Manage Layouts. Each row should have the app's icon next to its name.

**Commit:** `git commit -m "feat: show app icons in manage and restore dialogs"`

---

### Task 41: System Tray Badge (#43)

Show the number of tracked windows as a badge overlay on the tray icon.

**Files:**
- Modify: `autohotkey/lib/UI.ahk` — create dynamic icon with GDI+

**Step 1: Add badge drawing**

```ahk
; Create a tray icon with a number badge overlay.
UpdateTrayBadge(number) {
    if number <= 0 {
        try TraySetIcon("shell32.dll", 162)
        return
    }

    ; Use GDI+ to draw number on icon
    token := 0
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)

    ; Create 32x32 bitmap
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", 32, "Int", 32,
        "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)

    ; Draw base icon (blue circle)
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF4488CC, "Ptr*", &pBrush)
    DllCall("gdiplus\GdipFillEllipseI", "Ptr", pGraphics, "Ptr", pBrush, "Int", 0, "Int", 0, "Int", 32, "Int", 32)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)

    ; Draw number text
    text := String(number)
    pFont := 0
    pFamily := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "Str", "Segoe UI", "Ptr", 0, "Ptr*", &pFamily)
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", 14.0, "Int", 1, "Int", 2, "Ptr*", &pFont)
    pBrush2 := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFFFFFFF, "Ptr*", &pBrush2)

    ; Center text
    pFormat := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &pFormat)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", pFormat, "Int", 1)      ; Center
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", pFormat, "Int", 1)  ; Center

    rect := Buffer(16)
    NumPut("Float", 0, rect, 0)
    NumPut("Float", 0, rect, 4)
    NumPut("Float", 32, rect, 8)
    NumPut("Float", 32, rect, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", pGraphics, "Str", text, "Int", -1,
        "Ptr", pFont, "Ptr", rect, "Ptr", pFormat, "Ptr", pBrush2)

    ; Convert to HICON and set as tray
    hIcon := 0
    DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", pBitmap, "Ptr*", &hIcon)

    if hIcon
        TraySetIcon("HICON:" . hIcon)

    ; Cleanup
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush2)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFont)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", pFamily)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", pFormat)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
}
```

**Step 2: Call after save/restore**

After `SaveLayout()` and `RestoreJob.Done()`:
```ahk
UpdateTrayBadge(windows.Length)
```

**Verify:** Save a layout with 12 windows. Tray icon should show "12" badge.

**Commit:** `git commit -m "feat: tray icon badge showing tracked window count"`

---

## Phase 6: Polish & Distribution

---

### Task 42: Compiled .exe With Embedded Icon (#38)

Create a build script to compile to standalone .exe.

**Files:**
- Create: `autohotkey/build.ahk` (or use Ahk2Exe command line)
- Create: `autohotkey/icon.ico` (will need to be created or sourced)

**Step 1: Create build script**

Create `build.bat`:
```batch
@echo off
echo Compiling WorkspaceLayoutManager...
"C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in "WorkspaceLayoutManager.ahk" /out "WorkspaceLayoutManager.exe" /icon "icon.ico" /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
echo Done.
pause
```

**Step 2: Source an icon**

For now, use a system icon. Later, create a custom .ico file. The user can replace `icon.ico` with their own.

Create a simple `icon.ico` extraction script or use an existing grid/layout icon.

**Verify:** Run `build.bat`. A `WorkspaceLayoutManager.exe` should be produced that runs independently.

**Commit:** `git commit -m "feat: build script for compiled .exe with custom icon"`

---

### Task 43: FancyZones-Style Snap Zones (#39)

Define custom grid zones per monitor. This is the largest feature.

**Files:**
- Create: `autohotkey/lib/Zones.ahk`
- Modify: `autohotkey/lib/UI.ahk` — add zone editor dialog
- Modify: `autohotkey/WorkspaceLayoutManager.ahk` — add zone hotkey, zone snap on restore

**Step 1: Create Zones.ahk**

```ahk
; =============================================================================
; Zones.ahk - FancyZones-style snap zone definitions and snapping
; =============================================================================

; Get zones for a monitor. Returns Array of Maps with x, y, w, h (absolute coords).
GetZonesForMonitor(monitorIndex, zoneConfig) {
    area := GetMonitorWorkArea(monitorIndex)
    zones := []

    if !zoneConfig.Has("type")
        return zones

    zoneType := zoneConfig["type"]

    if zoneType == "grid" {
        cols := zoneConfig.Has("cols") ? zoneConfig["cols"] : 2
        rows := zoneConfig.Has("rows") ? zoneConfig["rows"] : 1
        cellW := area["w"] // cols
        cellH := area["h"] // rows
        Loop rows {
            row := A_Index
            Loop cols {
                col := A_Index
                zones.Push(Map(
                    "x", area["left"] + (col - 1) * cellW,
                    "y", area["top"] + (row - 1) * cellH,
                    "w", cellW,
                    "h", cellH,
                    "label", "R" . row . "C" . col
                ))
            }
        }
    }
    else if zoneType == "columns" {
        ; Custom column widths as percentages: [50, 25, 25]
        widths := zoneConfig.Has("widths") ? zoneConfig["widths"] : [50, 50]
        xOffset := area["left"]
        for pct in widths {
            zw := Round(area["w"] * pct / 100)
            zones.Push(Map(
                "x", xOffset,
                "y", area["top"],
                "w", zw,
                "h", area["h"],
                "label", "Col" . A_Index
            ))
            xOffset += zw
        }
    }

    return zones
}

; Find which zone a point falls into.
FindZoneForPoint(x, y, zones) {
    for i, zone in zones {
        if x >= zone["x"] && x < zone["x"] + zone["w"]
            && y >= zone["y"] && y < zone["y"] + zone["h"]
            return i
    }
    return 0
}

; Snap a window to a specific zone.
SnapToZone(hwnd, zone) {
    try {
        if WinGetMinMax(hwnd) != 0
            WinRestore(hwnd)
        WinMove(zone["x"], zone["y"], zone["w"], zone["h"], hwnd)
    }
}
```

**Step 2: Add zone settings**

In `DefaultSettings()`:
```ahk
s["zones"] := Map()  ; monitorIndex -> zoneConfig
; Example: {"1": {"type": "grid", "cols": 3, "rows": 2}}
```

**Step 3: Add zone-aware restore**

When restoring, if zones are configured, snap windows to the nearest zone instead of pixel-perfect placement.

In `PlaceWindow()` or `BatchPlaceWindows()`:
```ahk
; If zones are configured, snap to nearest zone instead of exact position
zones := Settings.Has("zones") ? Settings["zones"] : Map()
monStr := String(entry["monitorIndex"])
if zones.Has(monStr) {
    monZones := GetZonesForMonitor(entry["monitorIndex"], zones[monStr])
    cx := entry["x"] + entry["w"] // 2
    cy := entry["y"] + entry["h"] // 2
    zoneIdx := FindZoneForPoint(cx, cy, monZones)
    if zoneIdx > 0 {
        SnapToZone(hwnd, monZones[zoneIdx])
        return
    }
}
```

**Step 4: Add zone hotkeys**

```ahk
; Ctrl+Win+Arrow to snap active window to zones
^#Left::  SnapActiveToZone("left")
^#Right:: SnapActiveToZone("right")

SnapActiveToZone(direction) {
    hwnd := WinGetID("A")
    if !hwnd
        return
    monIdx := GetMonitorForWindow(hwnd)
    zones := Settings.Has("zones") ? Settings["zones"] : Map()
    monStr := String(monIdx)
    if !zones.Has(monStr)
        return
    monZones := GetZonesForMonitor(monIdx, zones[monStr])
    if monZones.Length == 0
        return

    ; Find current zone
    WinGetPos(&x, &y, &w, &h, hwnd)
    cx := x + w // 2
    cy := y + h // 2
    currentZone := FindZoneForPoint(cx, cy, monZones)

    ; Move to next/prev zone
    if direction == "right"
        targetZone := currentZone < monZones.Length ? currentZone + 1 : 1
    else
        targetZone := currentZone > 1 ? currentZone - 1 : monZones.Length

    SnapToZone(hwnd, monZones[targetZone])
}
```

**Verify:** Set zones in settings.json: `"zones": {"1": {"type": "grid", "cols": 3, "rows": 2}}`. Use `Ctrl+Win+Left/Right` to snap the active window between zones.

**Commit:** `git commit -m "feat: FancyZones-style snap zones with grid/column layouts"`

---

## Summary

| Phase | Tasks | Features | Est. Effort |
|-------|-------|----------|-------------|
| 1 - Infrastructure | 1-7 | #28, #33, #19, #42, #35, #10, #40 | Small-Medium |
| 2 - Engine | 8-16 | #3, #9, #7, #8, #37, #4, #32, #36, #11 | Small-Medium |
| 3 - Monitor Intel | 17-21 | #2, #1, #6, #5, #34 | Medium |
| 4 - Productivity | 22-30 | #12, #14, #13, #15, #16, #17, #18, #41, #20 | Medium-Large |
| 5 - UI Overhaul | 31-41 | #23, #24, #26, #29, #31, #30, #25, #22, #21, #27, #43 | Medium |
| 6 - Polish | 42-43 | #38, #39 | Medium-Large |

**Total: 43 tasks across 6 phases.**

Each task should be committed independently so progress is incremental and reversible. Features in the same phase can often be implemented in parallel by separate agents since they modify different sections of different files.
