; =============================================================================
; WorkspaceLayoutManager.ahk
; A lightweight workspace layout capture/restore tool for Windows.
; Requires AutoHotkey v2.0+
;
; Hotkeys (configurable in the HOTKEYS section below):
;   Ctrl+Alt+S    = Save current layout (with name prompt)
;   Ctrl+Alt+Q    = Quick-save to "QuickSave" (no prompt)
;   Ctrl+Alt+R    = Quick-restore most recently saved layout (no prompt)
;   Ctrl+Alt+1    = Quick-restore 1st layout
;   Ctrl+Alt+2    = Quick-restore 2nd layout
;   Ctrl+Alt+3    = Quick-restore 3rd layout
;   Ctrl+Alt+L    = Toggle auto-restore on login
;   Ctrl+Alt+D    = Toggle debug logging
;   Ctrl+Alt+Tab  = Quick-switch between last two restored layouts
;   Ctrl+Alt+N    = Cycle through all layouts
; =============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; --- Library includes --------------------------------------------------------
#Include lib\Json.ahk
#Include lib\Monitors.ahk
#Include lib\VirtualDesktop.ahk
#Include lib\WindowMatch.ahk
#Include lib\Rules.ahk
#Include lib\Zones.ahk
#Include lib\UI.ahk

; =============================================================================
; PATHS & GLOBALS
; =============================================================================
global AppName     := "WorkspaceLayoutManager"
global AppDir      := A_AppData . "\" . AppName
global LayoutsFile := AppDir . "\layouts.json"
global SettingsFile := AppDir . "\settings.json"
global DebugFile   := AppDir . "\debug.log"

global Layouts     := Map()   ; name -> layout Map
global Settings    := Map()   ; app settings Map
global DebugMode   := false
global _ActiveRestoreJob := false   ; currently running RestoreJob, or false
global _SaveLayoutsPending := false  ; debounce flag for SaveLayouts
global _CurrentLayoutName := ""     ; name of the last restored layout
global _DisplayChangeTimer := 0     ; debounce timer for WM_DISPLAYCHANGE
global _RestoreHistory := []        ; last 2 restored layout names for quick-switch
global _CycleIndex := 0             ; current index for layout cycling
global _LastScheduleCheck := ""     ; prevents duplicate schedule triggers within same minute

; =============================================================================
; INITIALIZATION
; =============================================================================
Initialize() {
    global AppDir, Settings, Layouts, DebugMode
    DirCreate(AppDir)
    VD_Init()  ; Initialize virtual desktop COM interface
    Settings := LoadSettings()
    Layouts  := LoadLayouts()
    CleanOldAutoSaves()
    DebugMode := Settings.Has("debugMode") && Settings["debugMode"]
    SetupTray()

    ; Listen for monitor configuration changes (connect/disconnect/resolution)
    OnMessage(0x007E, OnDisplayChange)  ; WM_DISPLAYCHANGE

    ; Auto-restore after login if enabled
    if Settings.Has("autoRestore") && Settings["autoRestore"]
        && Settings.Has("startupLayout") && Settings["startupLayout"] != "" {
        delay := Settings.Has("restoreDelay") ? Settings["restoreDelay"] * 1000 : 10000
        SetTimer(() => RestoreLayout(Settings["startupLayout"]), -delay)
    }

    ; Auto-save every N minutes (default 15) if enabled
    autoSaveMin := Settings.Has("autoSaveMinutes") ? Settings["autoSaveMinutes"] : 15
    if autoSaveMin > 0
        SetTimer(AutoSave, autoSaveMin * 60000)

    ; Check for scheduled layout restores every 30 seconds
    SetTimer(CheckSchedules, 30000)

    Notify("Workspace Layout Manager running  (Ctrl+Alt+S = Save, Ctrl+Alt+Q = Quick-save, Ctrl+Alt+R = Restore)", "verbose", 4000)
}

; =============================================================================
; HOTKEYS  ← edit the left-hand side to rebind
; =============================================================================
^!s:: SaveLayoutAction()        ; Ctrl+Alt+S - Save (with name prompt)
^!q:: QuickSaveAction()         ; Ctrl+Alt+Q - Quick-save to "QuickSave"
^!r:: QuickRestoreLastAction()  ; Ctrl+Alt+R - Quick-restore most recently saved layout
^!1:: QuickRestore(1)           ; Ctrl+Alt+1
^!2:: QuickRestore(2)           ; Ctrl+Alt+2
^!3:: QuickRestore(3)           ; Ctrl+Alt+3
^!l:: ToggleAutoRestoreAction() ; Ctrl+Alt+L
^!d:: ToggleDebugAction()       ; Ctrl+Alt+D
^!Tab:: QuickSwitchAction()     ; Ctrl+Alt+Tab - Quick-switch last two layouts
^!n:: CycleLayoutAction()       ; Ctrl+Alt+N - Cycle through layouts
^#Left::  SnapActiveToZone("left")   ; Ctrl+Win+Left  - Snap to previous zone
^#Right:: SnapActiveToZone("right")  ; Ctrl+Win+Right - Snap to next zone

; =============================================================================
; SAVE LAYOUT
; =============================================================================
SaveLayoutAction() {
    ShowSaveDialog(SaveLayout)
}

QuickSaveAction() {
    SaveLayout("QuickSave")
}

; Restore the layout with the most recent timestamp — no prompt.
QuickRestoreLastAction() {
    global Layouts, Settings
    if !Layouts.Count {
        Notify("No saved layouts.", "normal")
        return
    }
    ; Use the saved monitor profile mapping — set by explicit named restores.
    ; This lets the user "pin" a layout to their screen setup via the menu,
    ; and Ctrl+Alt+R will always restore that layout without overwriting the pin.
    fp       := GetMonitorFingerprint()
    profiles := Settings.Has("monitorProfiles") ? Settings["monitorProfiles"] : Map()
    if profiles.Has(fp) && Layouts.Has(profiles[fp]) {
        name := profiles[fp]
        job := RestoreJob(Layouts[name], Settings, true)  ; noProfileUpdate=true
        global _ActiveRestoreJob := job
        job.Start()
        global _CurrentLayoutName := name
        Notify("Restoring: " . name . "…")
        return
    }
    ; Fall back: most recently saved non-AutoSave layout
    latest   := ""
    latestTs := ""
    for name, layout in Layouts {
        if SubStr(name, 1, 8) == "AutoSave"
            continue
        ts := layout.Has("timestamp") ? layout["timestamp"] : ""
        if StrCompare(ts, latestTs) > 0 {
            latestTs := ts
            latest   := name
        }
    }
    if latest == "" {
        Notify("No layout with a timestamp.", "normal")
        return
    }
    RestoreLayout(latest)
}

; Snapshot the current version of a layout before it is overwritten.
; Stores up to maxLayoutVersions snapshots in layout["_versions"].
_VersionLayout(name) {
    global Layouts, Settings
    if !Layouts.Has(name)
        return
    old := Layouts[name]
    maxVersions := Settings.Has("maxLayoutVersions") ? Settings["maxLayoutVersions"] : 3
    if maxVersions <= 0
        return

    snapshot := Map()
    snapshot["timestamp"] := old.Has("timestamp") ? old["timestamp"] : ""
    snapshot["windows"]   := old.Has("windows") ? old["windows"] : []

    if !old.Has("_versions")
        old["_versions"] := []
    old["_versions"].Push(snapshot)

    ; Trim to maxVersions (remove oldest entries from the front)
    while old["_versions"].Length > maxVersions
        old["_versions"].RemoveAt(1)
}

SaveLayout(name) {
    global Layouts
    ; Version the old layout before overwriting
    _VersionLayout(name)

    ; Debug log if overwriting an existing layout
    if Layouts.Has(name) {
        oldCount := Layouts[name].Has("windows") ? Layouts[name]["windows"].Length : 0
        DebugLog("Overwriting layout '" . name . "' (had " . oldCount . " windows)")
    }

    DebugLog("=== Capturing layout: " . name . " ===")
    windows := CaptureAllWindows()

    if windows.Length == 0 {
        Notify("Nothing captured — layout not saved. (No visible windows found?)", "errors")
        DebugLog("SaveLayout: aborted — 0 windows captured")
        return
    }

    DebugLog("Captured " . windows.Length . " windows")
    for entry in windows {
        deskLabel := entry["desktopIndex"] > 0 ? " D" . entry["desktopIndex"] : ""
        wsLabel   := entry["workspacePath"] != "" ? " ws=" . entry["workspacePath"] : ""
        DebugLog("  " . entry["exe"] . " | " . entry["class"] . " | '" . entry["title"] . "'"
                 . " [" . entry["x"] . "," . entry["y"] . " " . entry["w"] . "x" . entry["h"]
                 . " " . entry["state"] . " M" . entry["monitorIndex"] . deskLabel . "]" . wsLabel)
    }

    layout := Map()
    layout["name"]      := name
    layout["timestamp"] := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    layout["windows"]   := windows
    layout["monitorFingerprint"] := GetMonitorFingerprint()

    Layouts[name] := layout
    SaveLayouts()
    Notify("Saved layout: " . name . " (" . windows.Length . " windows)")
}

; Silent auto-save (no toast, no verbose log) — runs on a timer
AutoSave() {
    global Layouts, _ActiveRestoreJob
    ; Don't auto-save while a restore is running
    if _ActiveRestoreJob
        return
    windows := CaptureAllWindows()
    if windows.Length == 0
        return   ; Don't overwrite with empty captures
    layout := Map()
    layout["name"]      := "AutoSave"
    layout["timestamp"] := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    layout["windows"]   := windows
    Layouts["AutoSave"] := layout
    SaveLayouts()
    DebugLog("AutoSave: " . windows.Length . " windows")
}

; =============================================================================
; RESTORE LAYOUT
; =============================================================================
RestoreLayoutAction() {
    names := GetLayoutNames()
    ShowRestoreDialog(names, RestoreLayout)
}

RestoreLayout(name) {
    global Layouts, Settings, _ActiveRestoreJob
    if !Layouts.Has(name) {
        NotifyError("Layout '" . name . "' not found.", "Restore")
        return
    }
    DebugLog("=== Restoring layout: " . name . " ===")
    Notify("Restoring: " . name . "…")

    job := RestoreJob(Layouts[name], Settings)
    global _ActiveRestoreJob := job
    job.Start()
    global _CurrentLayoutName := name
    _TrackRestore(name)
}

_TrackRestore(name) {
    global _RestoreHistory
    if _RestoreHistory.Length > 0 && _RestoreHistory[_RestoreHistory.Length] == name
        return
    _RestoreHistory.Push(name)
    if _RestoreHistory.Length > 2
        _RestoreHistory.RemoveAt(1)
}

QuickRestore(index) {
    names := GetLayoutNames()
    if names.Length < index {
        ShowToast("No layout #" . index . " saved yet.")
        return
    }
    RestoreLayout(names[index])
}

QuickSwitchAction() {
    global _RestoreHistory
    if _RestoreHistory.Length < 2 {
        Notify("Need at least 2 restored layouts to quick-switch.", "normal")
        return
    }
    target := _RestoreHistory[1]
    RestoreLayout(target)
}

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

; =============================================================================
; SNAP TO ZONE
; =============================================================================
SnapActiveToZone(direction) {
    global Settings
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
    WinGetPos(&x, &y, &w, &h, hwnd)
    cx := x + w // 2
    cy := y + h // 2
    currentZone := FindZoneForPoint(cx, cy, monZones)
    if direction == "right"
        targetZone := currentZone < monZones.Length ? currentZone + 1 : 1
    else
        targetZone := currentZone > 1 ? currentZone - 1 : monZones.Length
    SnapToZone(hwnd, monZones[targetZone])
    DebugLog("Snapped to zone " . targetZone . " on monitor " . monIdx)
}

; =============================================================================
; RESTORE JOB  - async, timer-driven so UI stays responsive
; =============================================================================
class RestoreJob {
    __New(layout, settings, noProfileUpdate := false) {
        this.layout          := layout
        this.settings        := settings
        this.noProfileUpdate := noProfileUpdate
        this.total           := layout["windows"].Length
        this.placed          := 0
        this.remaining       := []
        this.attempt         := 0
        this.maxAttempts     := 13
        this.placedHwnds     := Map()
        this.bound           := ObjBindMethod(this, "Retry")
    }

    GetDelay() {
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
        if hasSlow {
            delays := [500, 500, 1000, 1000, 2000, 2000, 3000, 4000, 5000]
        } else {
            delays := [200, 200, 300, 300, 500, 500, 1000, 1000, 1500]
        }
        idx := Min(this.attempt + 1, delays.Length)
        return delays[idx]
    }

    Start() {
        ; Suppress focus stealing during restore
        DllCall("LockSetForegroundWindow", "UInt", 1)

        ; Include windows on other virtual desktops
        DetectHiddenWindows(true)
        candidates := WinGetList()
        DetectHiddenWindows(false)

        ; Filter out already-placed windows
        filtered := []
        for hwnd in candidates {
            if !this.placedHwnds.Has(hwnd)
                filtered.Push(hwnd)
        }

        for entry in this.layout["windows"] {
            ; Pass DebugLog directly as the match callback (it's a global function)
            hwnd := FindMatchingWindow(entry, filtered, DebugLog)
            if hwnd {
                ; Remove matched hwnd from filtered so subsequent entries can't claim it
                filteredNext := []
                for h in filtered {
                    if h != hwnd
                        filteredNext.Push(h)
                }
                filtered := filteredNext

                if IsAlreadyPlaced(hwnd, entry) {
                    this.placed++
                    this.placedHwnds[hwnd] := true
                    DebugLog("Already placed: " . entry["exe"] . " '" . entry["cleanTitle"] . "'")
                } else {
                    PlaceWindow(hwnd, entry)
                    this.placed++
                    this.placedHwnds[hwnd] := true
                    deskLabel := entry.Has("desktopIndex") && entry["desktopIndex"] > 0
                        ? " -> D" . entry["desktopIndex"] : ""
                    DebugLog("Placed: " . entry["exe"] . " '" . entry["cleanTitle"] . "' -> hwnd " . hwnd . deskLabel)
                }
            } else {
                this.remaining.Push(entry)
                DebugLog("Not found yet: " . entry["exe"] . " '" . entry["cleanTitle"] . "'")
            }
        }

        if this.remaining.Length == 0 {
            this.Done()
            return
        }

        ; Launch missing apps if configured
        if this.settings.Has("launchMissing") && this.settings["launchMissing"]
            LaunchMissingApps(this.remaining)

        ShowProgress("Restoring " . this.layout["name"] . ": "
                     . this.placed . "/" . this.total . " placed, "
                     . this.remaining.Length . " pending…")
        SetTimer(this.bound, -this.GetDelay())
    }

    Retry() {
        this.attempt++
        DetectHiddenWindows(true)
        candidates   := WinGetList()
        DetectHiddenWindows(false)

        ; Filter out already-placed windows
        filtered := []
        for hwnd in candidates {
            if !this.placedHwnds.Has(hwnd)
                filtered.Push(hwnd)
        }

        stillMissing := []

        for entry in this.remaining {
            hwnd := FindMatchingWindow(entry, filtered, DebugLog)
            if hwnd {
                ; Remove matched hwnd from filtered so subsequent entries can't claim it
                filteredNext := []
                for h in filtered {
                    if h != hwnd
                        filteredNext.Push(h)
                }
                filtered := filteredNext

                if IsAlreadyPlaced(hwnd, entry) {
                    this.placed++
                    this.placedHwnds[hwnd] := true
                    DebugLog("Already placed (retry " . this.attempt . "): " . entry["exe"] . " '" . entry["cleanTitle"] . "'")
                } else {
                    PlaceWindow(hwnd, entry)
                    this.placed++
                    this.placedHwnds[hwnd] := true
                    deskLabel := entry.Has("desktopIndex") && entry["desktopIndex"] > 0
                        ? " -> D" . entry["desktopIndex"] : ""
                    DebugLog("Placed (retry " . this.attempt . "): " . entry["exe"] . " '" . entry["cleanTitle"] . "'" . deskLabel)
                }
            } else {
                stillMissing.Push(entry)
            }
        }

        this.remaining := stillMissing

        if this.remaining.Length == 0 || this.attempt >= this.maxAttempts {
            this.Done()
            return
        }

        ShowProgress("Restoring " . this.layout["name"] . ": "
                     . this.placed . "/" . this.total . " placed, "
                     . this.remaining.Length . " still pending…")
        SetTimer(this.bound, -this.GetDelay())
    }

    Done() {
        ; Re-enable foreground window changes
        DllCall("LockSetForegroundWindow", "UInt", 2)
        HideProgress()
        global AppName
        msg := "Restore complete: " . this.placed . "/" . this.total . " windows placed."
        if this.remaining.Length > 0 {
            missing := ""
            for e in this.remaining {
                deskLabel := e.Has("desktopIndex") && e["desktopIndex"] > 0
                    ? " [D" . e["desktopIndex"] . "]" : ""
                missing .= "`n  • " . e["exe"] . " – " . e["cleanTitle"] . deskLabel
            }
            msg .= "`n`nNot found (" . this.remaining.Length . "):" . missing
            NotifyError(msg, "Restore")
            A_IconTip := "WLM - " . this.layout["name"] . " (partial)"
        } else {
            ShowToast(msg, 4000)
            A_IconTip := "WLM - " . this.layout["name"]
        }
        DebugLog(msg)

        ; Remember this layout for the current monitor config (skip for quick-restore)
        if !this.noProfileUpdate {
            fp := GetMonitorFingerprint()
            global Settings
            if !Settings.Has("monitorProfiles")
                Settings["monitorProfiles"] := Map()
            Settings["monitorProfiles"][fp] := this.layout["name"]
            SaveSettings()
            DebugLog("Saved profile mapping: " . fp . " -> " . this.layout["name"])
        }

        ; Apply window rules after restore completes
        rules := Settings.Has("windowRules") ? Settings["windowRules"] : []
        if IsObject(rules) && rules.Length > 0
            ApplyWindowRules(rules)

        global _ActiveRestoreJob := false
    }
}

; =============================================================================
; TOGGLE AUTO-RESTORE
; =============================================================================
ToggleAutoRestoreAction() {
    global Settings
    Settings["autoRestore"] := Settings.Has("autoRestore") ? !Settings["autoRestore"] : 1
    SaveSettings()
    state := Settings["autoRestore"] ? "ON" : "OFF"
    Notify("Auto-restore on login: " . state, "verbose")
    DebugLog("Auto-restore toggled: " . state)
}

; =============================================================================
; TOGGLE DEBUG
; =============================================================================
ToggleDebugAction() {
    global DebugMode, Settings, DebugFile
    DebugMode := !DebugMode
    Settings["debugMode"] := DebugMode ? 1 : 0
    SaveSettings()
    Notify("Debug logging: " . (DebugMode ? "ON  → " . DebugFile : "OFF"), "verbose")
}

; =============================================================================
; STARTUP INTEGRATION
; =============================================================================
AddToStartup() {
    global AppName
    ahkExe    := A_AhkPath
    scriptPath := A_ScriptFullPath
    ; Wrap in quotes so spaces in paths are handled correctly
    value := '"' . ahkExe . '" "' . scriptPath . '"'
    RegWrite(value, "REG_SZ",
             "HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
             AppName)
    DebugLog("Added to startup: " . value)
}

RemoveFromStartup() {
    global AppName
    try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", AppName)
    DebugLog("Removed from startup.")
}

IsInStartup() {
    global AppName
    try {
        val := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", AppName)
        return val != ""
    } catch Error {
        return false
    }
}

; =============================================================================
; PERSISTENCE - Load / Save layouts and settings
; =============================================================================
LoadLayouts() {
    global LayoutsFile, AppName
    if !FileExist(LayoutsFile)
        return Map()
    try {
        raw := FileRead(LayoutsFile, "UTF-8")
        if Trim(raw) == ""
            return Map()
        return JSON.Parse(raw)
    } catch as e {
        NotifyError("Could not read layouts file:`n" . e.Message
               . "`n`nStack:`n" . e.Stack
               . "`n`nStarting with empty layout list.", "Load Layouts")
        return Map()
    }
}

SaveLayouts() {
    global _SaveLayoutsPending
    if _SaveLayoutsPending
        return   ; already scheduled
    _SaveLayoutsPending := true
    SetTimer(_FlushLayouts, -200)
}

_FlushLayouts() {
    global _SaveLayoutsPending, AppDir, LayoutsFile, Layouts, AppName
    _SaveLayoutsPending := false
    DirCreate(AppDir)
    try {
        content := JSON.Stringify(Layouts)
        f := FileOpen(LayoutsFile, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        NotifyError("Could not save layouts:`n" . e.Message . "`n`n" . e.Stack, "Save Layouts")
    }
}

LoadSettings() {
    global SettingsFile
    defaults := DefaultSettings()
    if !FileExist(SettingsFile)
        return defaults
    try {
        raw := FileRead(SettingsFile, "UTF-8")
        if Trim(raw) == ""
            return defaults
        loaded := JSON.Parse(raw)
        ; Merge loaded over defaults so new keys always have a value
        for k, v in defaults {
            if !loaded.Has(k)
                loaded[k] := v
        }
        return loaded
    } catch Error {
        return defaults
    }
}

SaveSettings() {
    global AppDir, SettingsFile, Settings, AppName
    DirCreate(AppDir)
    try {
        content := JSON.Stringify(Settings)
        f := FileOpen(SettingsFile, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        NotifyError("Could not save settings:`n" . e.Message, "Save Settings")
    }
}

DefaultSettings() {
    s := Map()
    s["autoRestore"]      := 0
    s["startupLayout"]    := ""
    s["restoreDelay"]     := 10
    s["launchMissing"]    := 1
    s["debugMode"]        := 0
    s["autoSaveMinutes"]  := 15   ; 0 to disable
    s["notificationLevel"] := "normal"  ; verbose, normal, errors, silent
    s["maxLayoutVersions"] := 3        ; number of previous versions to keep per layout
    s["monitorProfiles"]  := Map()     ; fingerprint -> layout name mapping
    s["schedules"]        := []         ; array of {time, layout, days} Maps
    s["windowRules"]      := []         ; array of rule Maps (exe, titleContains, monitor, position, state)
    s["zones"]            := Map()      ; monitorIndex (string) -> zone config Map (type, cols, rows, widths)
    return s
}

; =============================================================================
; SCHEDULING
; =============================================================================
CheckSchedules() {
    global Settings, Layouts, _ActiveRestoreJob, _LastScheduleCheck
    if _ActiveRestoreJob
        return
    schedules := Settings.Has("schedules") ? Settings["schedules"] : []
    if !IsObject(schedules) || schedules.Length == 0
        return
    now := FormatTime(, "HH:mm")
    today := StrLower(FormatTime(, "ddd"))
    if now == _LastScheduleCheck
        return
    for sched in schedules {
        if !sched.Has("time") || !sched.Has("layout")
            continue
        if sched["time"] != now
            continue
        if sched.Has("days") && sched["days"] != "" {
            if !InStr(StrLower(sched["days"]), today)
                continue
        }
        if Layouts.Has(sched["layout"]) {
            _LastScheduleCheck := now
            DebugLog("Schedule triggered: " . sched["layout"] . " at " . now)
            Notify("Scheduled restore: " . sched["layout"])
            RestoreLayout(sched["layout"])
            return
        }
    }
}

; =============================================================================
; IMPORT / EXPORT
; =============================================================================
ExportLayout(name) {
    global Layouts
    if !Layouts.Has(name) {
        NotifyError("Layout '" . name . "' not found.", "Export")
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
        NotifyError("Export failed: " . e.Message, "Export")
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
            NotifyError("Invalid layout file: missing 'name' or 'windows'.", "Import")
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
        NotifyError("Import failed: " . e.Message, "Import")
    }
}

; =============================================================================
; HELPERS
; =============================================================================

; Return sorted array of layout names (most recently saved first).
GetLayoutNames() {
    global Layouts
    names := []
    for name, _ in Layouts
        names.Push(name)
    ; Simple alphabetical sort (stable enough for small lists)
    Loop names.Length - 1 {
        i := A_Index
        Loop names.Length - i {
            j := A_Index + i
            if StrCompare(names[j], names[j - 1], false) < 0 {
                tmp          := names[j]
                names[j]     := names[j - 1]
                names[j - 1] := tmp
            }
        }
    }
    return names
}

; Delete AutoSave entries older than 7 days.
CleanOldAutoSaves() {
    global Layouts
    deleted := 0
    toDelete := []
    for name, layout in Layouts {
        if SubStr(name, 1, 8) != "AutoSave"
            continue
        if !layout.Has("timestamp")
            continue
        ; Convert "yyyy-MM-dd HH:mm:ss" to "yyyyMMddHHmmss"
        ts := layout["timestamp"]
        ts := StrReplace(ts, "-", "")
        ts := StrReplace(ts, ":", "")
        ts := StrReplace(ts, " ", "")
        if DateDiff(A_Now, ts, "Days") > 7
            toDelete.Push(name)
    }
    for name in toDelete {
        Layouts.Delete(name)
        deleted++
    }
    if deleted > 0 {
        SaveLayouts()
        DebugLog("CleanOldAutoSaves: deleted " . deleted . " old auto-save(s)")
    }
}

; Write a timestamped line to the debug log file.
DebugLog(msg) {
    global DebugMode, DebugFile
    if !DebugMode
        return
    try {
        ts   := FormatTime(, "HH:mm:ss.") . SubStr(A_TickCount, -2)
        line := "[" . ts . "] " . msg . "`n"
        f    := FileOpen(DebugFile, "a", "UTF-8")
        f.Write(line)
        f.Close()
    }
}

; =============================================================================
; MONITOR INTELLIGENCE - display change detection and window parking
; =============================================================================

OnDisplayChange(wParam, lParam, msg, hwnd) {
    global _DisplayChangeTimer
    SetTimer(HandleDisplayChange, -2000)  ; 2s debounce
    return 0
}

HandleDisplayChange() {
    global Layouts, Settings, _ActiveRestoreJob
    if _ActiveRestoreJob
        return
    newFP := GetMonitorFingerprint()
    DebugLog("Display changed: " . newFP)

    ; Park orphaned windows first
    ParkOrphanedWindows()

    ; Check for profile mapping
    profiles := Settings.Has("monitorProfiles") ? Settings["monitorProfiles"] : Map()
    if profiles.Has(newFP) {
        layoutName := profiles[newFP]
        if Layouts.Has(layoutName) {
            DebugLog("Auto-switching to profile layout: " . layoutName)
            Notify("Monitors changed - restoring '" . layoutName . "'")
            Sleep(1000)
            RestoreLayout(layoutName)
            return
        }
    }
    ; Fallback: find any layout whose fingerprint matches
    for name, layout in Layouts {
        if layout.Has("monitorFingerprint") && layout["monitorFingerprint"] == newFP {
            DebugLog("Auto-switching to matching layout: " . name)
            Notify("Monitors changed - restoring '" . name . "'")
            Sleep(1000)
            RestoreLayout(name)
            return
        }
    }
    DebugLog("No layout matches current monitor config: " . newFP)
}

; Move windows that are off-screen (e.g. monitor disconnected) to the primary monitor.
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
            onScreen := false
            Loop count {
                MonitorGet(A_Index, &ml, &mt, &mr, &mb)
                if cx >= ml && cx < mr && cy >= mt && cy < mb {
                    onScreen := true
                    break
                }
            }
            if !onScreen {
                newX := workArea["left"] + 50 + Mod(parked, 10) * 30
                newY := workArea["top"] + 50 + Mod(parked, 10) * 30
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

; =============================================================================
; ENTRY POINT
; =============================================================================
if A_Args.Length > 0 {
    cmd := StrLower(A_Args[1])
    if cmd == "/save" || cmd == "--save" {
        name := A_Args.Length > 1 ? A_Args[2] : "QuickSave"
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
        return  ; Keep running for async restore
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
Initialize()
