; =============================================================================
; WorkspaceLayoutManager.ahk
; A lightweight workspace layout capture/restore tool for Windows.
; Requires AutoHotkey v2.0+
;
; Hotkeys (configurable in the HOTKEYS section below):
;   Ctrl+Alt+S  = Save current layout (with name prompt)
;   Ctrl+Alt+Q  = Quick-save to "QuickSave" (no prompt)
;   Ctrl+Alt+R  = Restore layout (from list)
;   Ctrl+Alt+1  = Quick-restore 1st layout
;   Ctrl+Alt+2  = Quick-restore 2nd layout
;   Ctrl+Alt+3  = Quick-restore 3rd layout
;   Ctrl+Alt+L  = Toggle auto-restore on login
;   Ctrl+Alt+D  = Toggle debug logging
; =============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; --- Library includes --------------------------------------------------------
#Include lib\Json.ahk
#Include lib\Monitors.ahk
#Include lib\VirtualDesktop.ahk
#Include lib\WindowMatch.ahk
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

; =============================================================================
; INITIALIZATION
; =============================================================================
Initialize() {
    global AppDir, Settings, Layouts, DebugMode
    DirCreate(AppDir)
    VD_Init()  ; Initialize virtual desktop COM interface
    Settings := LoadSettings()
    Layouts  := LoadLayouts()
    DebugMode := Settings.Has("debugMode") && Settings["debugMode"]
    SetupTray()

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

    ShowToast("Workspace Layout Manager running  (Ctrl+Alt+S = Save, Ctrl+Alt+Q = Quick-save, Ctrl+Alt+R = Restore)", 4000)
}

; =============================================================================
; HOTKEYS  ← edit the left-hand side to rebind
; =============================================================================
^!s:: SaveLayoutAction()        ; Ctrl+Alt+S - Save (with name prompt)
^!q:: QuickSaveAction()         ; Ctrl+Alt+Q - Quick-save to "QuickSave"
^!r:: RestoreLayoutAction()     ; Ctrl+Alt+R - Restore (pick from list)
^!1:: QuickRestore(1)           ; Ctrl+Alt+1
^!2:: QuickRestore(2)           ; Ctrl+Alt+2
^!3:: QuickRestore(3)           ; Ctrl+Alt+3
^!l:: ToggleAutoRestoreAction() ; Ctrl+Alt+L
^!d:: ToggleDebugAction()       ; Ctrl+Alt+D

; =============================================================================
; SAVE LAYOUT
; =============================================================================
SaveLayoutAction() {
    ShowSaveDialog(SaveLayout)
}

QuickSaveAction() {
    SaveLayout("QuickSave")
}

SaveLayout(name) {
    global Layouts
    DebugLog("=== Capturing layout: " . name . " ===")
    windows := CaptureAllWindows()

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

    Layouts[name] := layout
    SaveLayouts()
    ShowToast("Saved layout: " . name . " (" . windows.Length . " windows)")
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
        MsgBox("Layout '" . name . "' not found.", "Restore", "IconX")
        return
    }
    DebugLog("=== Restoring layout: " . name . " ===")
    ShowToast("Restoring: " . name . "…")

    job := RestoreJob(Layouts[name], Settings)
    global _ActiveRestoreJob := job
    job.Start()
}

QuickRestore(index) {
    names := GetLayoutNames()
    if names.Length < index {
        ShowToast("No layout #" . index . " saved yet.")
        return
    }
    RestoreLayout(names[index])
}

; =============================================================================
; RESTORE JOB  - async, timer-driven so UI stays responsive
; =============================================================================
class RestoreJob {
    __New(layout, settings) {
        this.layout   := layout
        this.settings := settings
        this.total    := layout["windows"].Length
        this.placed   := 0
        this.remaining := []
        this.attempt  := 0
        ; Backoff delays in ms: fast at first, slower as we wait longer
        this.delays   := [300, 300, 500, 500, 1000, 1000, 2000, 2000, 3000, 3000, 4000, 4000, 5000]
        this.bound    := ObjBindMethod(this, "Retry")
    }

    Start() {
        ; Include windows on other virtual desktops
        DetectHiddenWindows(true)
        candidates := WinGetList()
        DetectHiddenWindows(false)

        for entry in this.layout["windows"] {
            ; Pass DebugLog directly as the match callback (it's a global function)
            hwnd := FindMatchingWindow(entry, candidates, DebugLog)
            if hwnd {
                PlaceWindow(hwnd, entry)
                this.placed++
                deskLabel := entry.Has("desktopIndex") && entry["desktopIndex"] > 0
                    ? " -> D" . entry["desktopIndex"] : ""
                DebugLog("Placed: " . entry["exe"] . " '" . entry["cleanTitle"] . "' -> hwnd " . hwnd . deskLabel)
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
        SetTimer(this.bound, -this.delays[1])
    }

    Retry() {
        this.attempt++
        DetectHiddenWindows(true)
        candidates   := WinGetList()
        DetectHiddenWindows(false)
        stillMissing := []

        for entry in this.remaining {
            hwnd := FindMatchingWindow(entry, candidates, DebugLog)
            if hwnd {
                PlaceWindow(hwnd, entry)
                this.placed++
                deskLabel := entry.Has("desktopIndex") && entry["desktopIndex"] > 0
                    ? " -> D" . entry["desktopIndex"] : ""
                DebugLog("Placed (retry " . this.attempt . "): " . entry["exe"] . " '" . entry["cleanTitle"] . "'" . deskLabel)
            } else {
                stillMissing.Push(entry)
            }
        }

        this.remaining := stillMissing

        if this.remaining.Length == 0 || this.attempt >= this.delays.Length {
            this.Done()
            return
        }

        ShowProgress("Restoring " . this.layout["name"] . ": "
                     . this.placed . "/" . this.total . " placed, "
                     . this.remaining.Length . " still pending…")
        SetTimer(this.bound, -this.delays[this.attempt + 1])
    }

    Done() {
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
            MsgBox(msg, AppName . " – Restore", "Icon!")
        } else {
            ShowToast(msg, 4000)
        }
        DebugLog(msg)
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
    ShowToast("Auto-restore on login: " . state)
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
    ShowToast("Debug logging: " . (DebugMode ? "ON  → " . DebugFile : "OFF"))
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
        MsgBox("Could not read layouts file:`n" . e.Message
               . "`n`nStack:`n" . e.Stack
               . "`n`nStarting with empty layout list.", AppName, "Icon!")
        return Map()
    }
}

SaveLayouts() {
    global AppDir, LayoutsFile, Layouts, AppName
    DirCreate(AppDir)
    try {
        content := JSON.Stringify(Layouts)
        f := FileOpen(LayoutsFile, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        MsgBox("Could not save layouts:`n" . e.Message . "`n`n" . e.Stack, AppName, "IconX")
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
        MsgBox("Could not save settings:`n" . e.Message, AppName, "IconX")
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
    return s
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
; ENTRY POINT
; =============================================================================
Initialize()
