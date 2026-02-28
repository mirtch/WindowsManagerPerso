; =============================================================================
; WindowMatch.ahk - Window capture and matching logic
; =============================================================================

; ---------------------------------------------------------------------------
; Classes/window titles to always skip during capture
; ---------------------------------------------------------------------------
; Per-exe snap ratio cache. Populated at runtime when snap compensation fires.
; Key = exe name (lowercase), Value = ratio (actual_h / target_h, e.g. 3.0).
global _SnapRatios := Map()

global _SkipClasses := [
    "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW",
    "DV2ControlHost", "MsgrIMEWindowClass", "SysShadow",
    "Button",                      ; Desktop "Show Desktop" button
    "Windows.UI.Core.CoreWindow",  ; Most UWP chrome (but not all)
    "ApplicationFrameWindow",      ; UWP frame — skipped (use inner CoreWindow instead)
]

global _SkipExes := [
    "SearchHost.exe", "StartMenuExperienceHost.exe", "ShellExperienceHost.exe",
    "LockApp.exe", "LogonUI.exe", "SystemSettings.exe",
]

; Cache for workspace folder URIs from storage.json (populated once per capture)
global _WorkspaceFolderCache := Map()   ; appName -> Array of folder URI strings

; ---------------------------------------------------------------------------
; Capture all valid visible windows and return an Array of window-entry Maps.
; ---------------------------------------------------------------------------
CaptureAllWindows() {
    global _WorkspaceFolderCache

    ; Pre-load workspace folder caches (read each storage.json once, not per window)
    _WorkspaceFolderCache := Map()
    _LoadWorkspaceFolders("Cursor")
    _LoadWorkspaceFolders("Code")

    ; Use DetectHiddenWindows(true) so WinGetList includes windows
    ; on other virtual desktops (they are cloaked but not truly hidden).
    DetectHiddenWindows(true)
    hwnds   := WinGetList()
    DetectHiddenWindows(false)

    DebugLog("CaptureAll: WinGetList returned " . hwnds.Length . " raw hwnds")

    ; Build virtual-desktop GUID→index map from all window handles
    vdMapData := VD_BuildDesktopMap(hwnds)

    entries := []
    skippedInvalid := 0
    skippedEntry   := 0
    for hwnd in hwnds {
        if !IsValidWindow(hwnd) {
            skippedInvalid++
            continue
        }
        entry := CaptureWindowEntry(hwnd, vdMapData)
        if entry {
            entries.Push(entry)
        } else {
            skippedEntry++
        }
    }

    ; Clear cache after capture
    _WorkspaceFolderCache := Map()

    DebugLog("CaptureAll: " . entries.Length . " valid, " . skippedInvalid . " filtered, " . skippedEntry . " failed")
    return entries
}

; Read storage.json once for an app and cache the folder URIs.
_LoadWorkspaceFolders(appName) {
    global _WorkspaceFolderCache
    wsFile := EnvGet("APPDATA") . "\" . appName . "\User\globalStorage\storage.json"
    if !FileExist(wsFile)
        return
    try {
        raw  := FileRead(wsFile, "UTF-8")
        data := JSON.Parse(raw)
        if !data.Has("windowsState")
            return
        wsState := data["windowsState"]
        folders := []
        if wsState.Has("lastActiveWindow") && wsState["lastActiveWindow"].Has("folder")
            folders.Push(wsState["lastActiveWindow"]["folder"])
        if wsState.Has("openedWindows") {
            for wEntry in wsState["openedWindows"] {
                if wEntry.Has("folder")
                    folders.Push(wEntry["folder"])
            }
        }
        _WorkspaceFolderCache[appName] := folders
        DebugLog("WorkspaceCache: loaded " . folders.Length . " folders for " . appName)
    } catch as e {
        DebugLog("WorkspaceCache: failed for " . appName . ": " . e.Message)
    }
}

; Build a single window-entry Map for the given hwnd.
; vdMapData is the result of VD_BuildDesktopMap (optional, 0 to skip).
; Returns false on any error.
CaptureWindowEntry(hwnd, vdMapData := 0) {
    global _SkipExes, _SkipClasses
    try {
        exe   := WinGetProcessName(hwnd)
        title := WinGetTitle(hwnd)
        cls   := WinGetClass(hwnd)

        ; Skip unwanted exes
        for skipExe in _SkipExes {
            if StrLower(exe) == StrLower(skipExe)
                return false
        }

        ; Skip unwanted classes (exact match)
        for skipCls in _SkipClasses {
            if cls == skipCls
                return false
        }

        WinGetPos(&x, &y, &w, &h, hwnd)
        minmax := WinGetMinMax(hwnd)

        state := "normal"
        if minmax == 1
            state := "maximized"
        else if minmax == -1
            state := "minimized"

        ; NOTE: local var must not share a case-insensitive name with CleanTitle()
        ; (AHK v2 is case-insensitive: "cleanTitle" == "CleanTitle" causes UnsetError)
        cTitle := CleanTitle(title, exe)

        ; Get process path and workspace for launch-missing support
        exePath       := ""
        workspacePath := ""
        try {
            pid     := WinGetPID(hwnd)
            exePath := ProcessGetPath(pid)
            ; For VS Code / Cursor: read workspace from Cursor's storage.json
            if (StrLower(exe) == "cursor.exe" || StrLower(exe) == "code.exe")
                workspacePath := GetVSCodeWorkspace(cTitle, exe)
        } catch {
            ; exePath/workspacePath stay empty on failure
        }

        monIdx := GetMonitorForWindow(hwnd)
        monDPI := GetMonitorDPI(monIdx)

        ; Virtual desktop info
        deskIdx  := 0
        deskGuid := ""
        if vdMapData {
            deskIdx := VD_GetDesktopIndex(hwnd, vdMapData)
            guidBuf := VD_GetDesktopId(hwnd)
            if guidBuf
                deskGuid := VD_GuidToString(guidBuf)
        }

        entry := Map()
        entry["exe"]           := exe
        entry["exePath"]       := exePath
        entry["workspacePath"] := workspacePath
        entry["title"]         := title
        entry["cleanTitle"]    := cTitle
        entry["hwnd"]          := hwnd
        entry["class"]         := cls
        entry["x"]             := x
        entry["y"]             := y
        entry["w"]             := w
        entry["h"]             := h
        entry["state"]         := state
        entry["monitorIndex"]  := monIdx
        entry["dpi"]           := monDPI
        entry["desktopIndex"]  := deskIdx
        entry["desktopGuid"]   := deskGuid
        return entry
    } catch as e {
        DebugLog("CaptureEntry FAIL hwnd=" . hwnd . " err=" . e.Message)
        return false
    }
}

; ---------------------------------------------------------------------------
; Decide whether a window should be included in a capture.
; ---------------------------------------------------------------------------
IsValidWindow(hwnd) {
    ; Check cloaked state FIRST (before visibility check).
    ; Windows on other virtual desktops are cloaked=2 but may not be "visible".
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute",
        "Ptr",  hwnd,
        "UInt", 14,      ; DWMWA_CLOAKED
        "UInt*", &cloaked,
        "UInt", 4)

    ; Value 2 (DWM_CLOAKED_SHELL) = window on another virtual desktop → keep it.
    ; Value 1 (DWM_CLOAKED_APP) = app explicitly cloaked (truly hidden UWP) → skip.
    ; Value 4 (DWM_CLOAKED_INHERITED) = inherited from parent — on Win11 24H2 this is
    ;   returned for normal visible windows too, so let IsWindowVisible decide below.
    if cloaked == 1
        return false

    ; Must be visible — use WS_VISIBLE style flag directly (DllCall IsWindowVisible
    ; was returning 0 for all windows on Win11 24H2 in some launch contexts).
    ; Skip this check for other-desktop windows which have cloaked=2.
    if cloaked != 2 {
        try {
            if !(WinGetStyle(hwnd) & 0x10000000)  ; WS_VISIBLE
                return false
        } catch {
            return false
        }
    }

    ; Must have a non-empty title
    try {
        if WinGetTitle(hwnd) == ""
            return false
    } catch {
        return false
    }

    ; Must have a process name
    try {
        if WinGetProcessName(hwnd) == ""
            return false
    } catch {
        return false
    }

    ; Must be reasonably sized
    try {
        WinGetPos(, , &w, &h, hwnd)
        if w < 50 || h < 50
            return false
    } catch {
        return false
    }

    ; Skip tool windows (WS_EX_TOOLWINDOW) - tiny floating helpers
    try {
        if WinGetExStyle(hwnd) & 0x80  ; WS_EX_TOOLWINDOW
            return false
    } catch {
        ; silently ignore - some windows don't support WinGetExStyle
    }

    return true
}

; ---------------------------------------------------------------------------
; Strip dynamic suffixes from a window title.
;   "Inbox (42) - Gmail - Google Chrome" -> "Inbox - Gmail"
;   "project.py - Visual Studio Code"    -> "project.py"
; ---------------------------------------------------------------------------
CleanTitle(title, exe := "") {
    cleaned := title

    ; Remove notification count prefixes like "(42) " or "• "
    cleaned := RegExReplace(cleaned, "^\(\d+\)\s*")
    cleaned := RegExReplace(cleaned, "^[•●·]\s*")

    ; Remove common app-name suffixes (order matters: longest first)
    static AppSuffixes := [
        " - Visual Studio Code",
        " - Cursor",
        " - Google Chrome",
        " - Microsoft Edge",
        " - Mozilla Firefox",
        " – Mozilla Firefox",
        " - Brave",
        " - Spotify",
        " | Discord",
        " - Discord",
        " - Notepad++",
        " - Notepad",
        " - Windows Explorer",
        " - File Explorer",
        " - Microsoft Word",
        " - Microsoft Excel",
        " - Microsoft PowerPoint",
        " - Paint",
        " - Calculator",
    ]
    for suffix in AppSuffixes {
        pos := InStr(cleaned, suffix)
        if pos > 1
            cleaned := SubStr(cleaned, 1, pos - 1)
    }

    ; Remove trailing " - " leftover
    cleaned := RegExReplace(cleaned, "\s*[-–]\s*$")

    return Trim(cleaned)
}

; ---------------------------------------------------------------------------
; Find the best matching window from a list of candidate HWNDs for a saved entry.
;
; Matching strategy:
;   1. Primary match: process name (case-insensitive) + window class (exact)
;   2. If multiple candidates: score by title similarity, pick highest
;   3. Secondary fallback: process name only (class changed or app updated)
;
; Returns the best matching hwnd, or 0 if none found.
; ---------------------------------------------------------------------------
FindMatchingWindow(entry, candidateHwnds, debugCb := false) {
    targetExe   := StrLower(entry["exe"])
    targetClass := entry["class"]
    targetClean := entry["cleanTitle"]

    ; --- Pass 1: exact exe + class ---
    pass1 := []
    for hwnd in candidateHwnds {
        try {
            if StrLower(WinGetProcessName(hwnd)) == targetExe
                && WinGetClass(hwnd) == targetClass
                pass1.Push(hwnd)
        }
    }

    if pass1.Length == 1 {
        if debugCb
            try debugCb("Match (pass1 unique): " . entry["exe"] . " | " . WinGetTitle(pass1[1]))
        return pass1[1]
    }

    if pass1.Length > 1 {
        best := BestTitleMatch(targetClean, pass1, debugCb)
        if debugCb
            try debugCb("Match (pass1 best-title): " . entry["exe"] . " | " . (best ? WinGetTitle(best) : "no match"))
        return best
    }

    ; --- Pass 2: exe only (class may have changed) ---
    pass2 := []
    for hwnd in candidateHwnds {
        try {
            if StrLower(WinGetProcessName(hwnd)) == targetExe
                pass2.Push(hwnd)
        }
    }

    if pass2.Length == 0 {
        if debugCb
            debugCb("No match for: " . entry["exe"] . " [" . targetClass . "] '" . targetClean . "'")
        return 0
    }

    best := BestTitleMatch(targetClean, pass2, debugCb)
    if debugCb
        try debugCb("Match (pass2 exe-only): " . entry["exe"] . " | " . (best ? WinGetTitle(best) : "no match"))
    return best
}

; Pick the hwnd from candidates whose cleaned title best matches targetClean.
; Returns 0 if no candidate scores above the minimum threshold (avoids false matches).
BestTitleMatch(targetClean, candidates, debugCb := false) {
    bestHwnd  := 0
    bestScore := -1
    target    := StrLower(Trim(targetClean))

    for hwnd in candidates {
        try {
            cand  := StrLower(Trim(CleanTitle(WinGetTitle(hwnd))))
            score := TitleSimilarity(target, cand)
            if score > bestScore {
                bestScore := score
                bestHwnd  := hwnd
            }
        }
    }
    ; Require at least a minimal match — score 0 means zero word overlap,
    ; which is a wrong match (e.g. picking a random Cursor window for "Dropbox").
    ; If only one candidate exists, always accept it (unique app instance).
    if bestScore <= 0 && candidates.Length > 1
        return 0
    return bestHwnd
}

; ---------------------------------------------------------------------------
; Simple title similarity score: 0-100.
; ---------------------------------------------------------------------------
TitleSimilarity(a, b) {
    if a == b
        return 100
    if a == "" || b == ""
        return 0

    ; Contains check (one is a substring of the other)
    if InStr(a, b) || InStr(b, a)
        return 80

    ; Word overlap ratio
    wordsA := StrSplit(a, " ")
    wordsB := StrSplit(b, " ")
    if wordsA.Length == 0 || wordsB.Length == 0
        return 0

    common := 0
    for wA in wordsA {
        if StrLen(wA) < 2
            continue
        for wB in wordsB {
            if wA == wB {
                common++
                break
            }
        }
    }
    maxLen := Max(wordsA.Length, wordsB.Length)
    return Round(common / maxLen * 60)
}

; ---------------------------------------------------------------------------
; Check whether a window is already at the saved position/state.
; Returns true if the window matches (within tolerance), false otherwise.
; ---------------------------------------------------------------------------
IsAlreadyPlaced(hwnd, entry) {
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
        minmax := WinGetMinMax(hwnd)
        state := "normal"
        if minmax == 1
            state := "maximized"
        else if minmax == -1
            state := "minimized"
        if state != entry["state"]
            return false
        if state != "normal"
            return true
        tolerance := 10
        if Abs(x - entry["x"]) > tolerance
            return false
        if Abs(y - entry["y"]) > tolerance
            return false
        if Abs(w - entry["w"]) > tolerance
            return false
        if Abs(h - entry["h"]) > tolerance
            return false
        ; Check virtual desktop — wrong desktop = needs PlaceWindow even if position matches
        if entry.Has("desktopGuid") && entry["desktopGuid"] != "" {
            guidBuf := VD_GetDesktopId(hwnd)
            curGuid := guidBuf ? VD_GuidToString(guidBuf) : "FAIL"
            DebugLog("IsAlreadyPlaced VD hwnd=" . hwnd . " cur=" . curGuid . " saved=" . entry["desktopGuid"])
            if guidBuf && curGuid != entry["desktopGuid"]
                return false
        }
        return true
    } catch {
        return false
    }
}

; ---------------------------------------------------------------------------
; Move, resize, and set state for a window according to a saved entry.
; Handles the maximized-on-correct-monitor case.
; ---------------------------------------------------------------------------
PlaceWindow(hwnd, entry) {
    global _SnapRatios
    state := entry["state"]

    ; --- Minimized: just minimize, then move to correct desktop ---
    if state == "minimized" {
        try WinMinimize(hwnd)
        _MoveToSavedDesktop(hwnd, entry)
        return
    }

    ; --- Un-maximize/minimize if needed so we can move freely ---
    try {
        currentMinMax := WinGetMinMax(hwnd)
        if currentMinMax != 0
            WinRestore(hwnd)
    }

    ; --- Clamp destination to a valid monitor area ---
    clamped := ClampToMonitor(entry["x"], entry["y"], entry["w"], entry["h"])

    ; --- Set position/size ---
    ; WinShow is called before WinMove to ensure the window is in a visible,
    ; active state.  Chromium apps (Edge, Chrome) defer resize processing
    ; when cloaked (DWM_CLOAKED_SHELL, i.e. on another virtual desktop).
    ; Without WinShow, WinMove appears to succeed but Edge snaps back to the
    ; monitor height the moment the user switches to that desktop.
    ; NOTE: WinShow brings the window to the current desktop as a side effect.
    ; VD restore (moving back to the saved desktop) is handled separately in
    ; _MoveToSavedDesktop below and requires the internal COM API.
    DetectHiddenWindows(true)
    try WinShow(hwnd)
    DetectHiddenWindows(false)
    Sleep(30)

    try {
        if state == "maximized" {
            DetectHiddenWindows(true)
            WinMove(clamped["x"] + 50, clamped["y"] + 50, 400, 300, hwnd)
            DetectHiddenWindows(false)
            Sleep(30)
            WinMaximize(hwnd)
        } else {
            ; Disable Windows Snap so WinMove is not intercepted by snap zones.
            ; WinMove handles DPI correctly (raw DllCall("SetWindowPos") caused 3x
            ; size inflation on this monitor).
            static SPI_SETWINARRANGING := 0x0083

            ; Pre-compensate if this exe has a known snap ratio from a previous restore.
            _exe := ""
            try _exe := StrLower(WinGetProcessName(hwnd))
            _initH := clamped["h"]
            _initW := clamped["w"]
            if _exe != "" && _SnapRatios.Has(_exe) {
                _ratio := _SnapRatios[_exe]
                _initH := Round(clamped["h"] / _ratio)
                ; Width does not snap — keep target width as-is
            }

            DllCall("SystemParametersInfo", "UInt", SPI_SETWINARRANGING, "UInt", 0, "Ptr", 0, "UInt", 0)
            try {
                DetectHiddenWindows(true)
                WinMove(clamped["x"], clamped["y"], _initW, _initH, hwnd)
                Sleep(50)
                WinMove(clamped["x"], clamped["y"], _initW, _initH, hwnd)
                DetectHiddenWindows(false)
            } finally {
                DllCall("SystemParametersInfo", "UInt", SPI_SETWINARRANGING, "UInt", 1, "Ptr", 0, "UInt", 0)
            }
            Sleep(100)
            WinGetPos(&_ax, &_ay, &_aw, &_ah, hwnd)
            ; Safety net: if snap still occurs (e.g. window was already visible),
            ; compensate. Threshold 1.3x catches real snaps (e.g. 1392→2180 = 1.566x)
            ; while tolerating normal border/padding differences (<5%, well under 1.3x).
            if (_ah > clamped["h"] * 1.3 && clamped["h"] > 0) {
                _ratio := _ah / clamped["h"]
                if _exe != ""
                    _SnapRatios[_exe] := _ratio
                _newH := Round(clamped["h"] / _ratio)
                _newW := (_aw > clamped["w"] * 1.5) ? Round(clamped["w"] / _ratio) : clamped["w"]
                DllCall("SystemParametersInfo", "UInt", SPI_SETWINARRANGING, "UInt", 0, "Ptr", 0, "UInt", 0)
                try {
                    DetectHiddenWindows(true)
                    WinMove(clamped["x"], clamped["y"], _newW, _newH, hwnd)
                    Sleep(50)
                    WinMove(clamped["x"], clamped["y"], _newW, _newH, hwnd)
                    DetectHiddenWindows(false)
                } finally {
                    DllCall("SystemParametersInfo", "UInt", SPI_SETWINARRANGING, "UInt", 1, "Ptr", 0, "UInt", 0)
                }
                Sleep(100)
                WinGetPos(&_ax, &_ay, &_aw, &_ah, hwnd)
            }
            DebugLog("PlaceWindow verify hwnd=" . hwnd . " actual=[" . _ax . "," . _ay . " " . _aw . "x" . _ah . "] target=[" . clamped["x"] . "," . clamped["y"] . " " . clamped["w"] . "x" . clamped["h"] . "]")
        }
    } catch as e {
        DebugLog("PlaceWindow position failed for hwnd " . hwnd . ": " . e.Message)
    }

    ; --- Move to correct virtual desktop AFTER positioning ---
    ; Do NOT call WinShow after VD_MoveToDesktop — it promotes the window to the
    ; current desktop, undoing the VD move.
    _MoveToSavedDesktop(hwnd, entry)
}

_MoveToSavedDesktop(hwnd, entry) {
    if !entry.Has("desktopGuid") || entry["desktopGuid"] == ""
        return
    savedGuid := entry["desktopGuid"]
    curBuf := VD_GetDesktopId(hwnd)
    curGuid := curBuf ? VD_GuidToString(curBuf) : "unknown"
    if curGuid == savedGuid
        return
    try {
        targetGuid := VD_StringToGuid(savedGuid)
        if !targetGuid
            return

        ; Try the internal API first — works for windows owned by other processes
        ; (Edge, Chrome, Explorer, etc.) where the public API returns E_ACCESSDENIED.
        ; Skipped when vdApiMode="public-only" (set by system scan on Win10 / pre-24H2).
        ok := false
        vdMode := Settings.Has("vdApiMode") ? Settings["vdApiMode"] : "auto"
        if vdMode != "public-only" && VD_Internal_Init()
            ok := VD_Internal_MoveToDesktop(hwnd, targetGuid)

        ; Fall back to the public API (works only for AHK-owned windows)
        if !ok
            ok := VD_MoveToDesktop(hwnd, targetGuid)

        Sleep(30)
        afterBuf := VD_GetDesktopId(hwnd)
        afterGuid := afterBuf ? VD_GuidToString(afterBuf) : "?"
        DebugLog("VD move hwnd=" . hwnd . " ok=" . ok . " after=" . afterGuid . " wanted=" . savedGuid)
    } catch as e {
        DebugLog("VD move exception hwnd=" . hwnd . ": " . e.Message)
    }
}

; ---------------------------------------------------------------------------
; Attempt to launch missing apps from a list of window entries.
; Deduplicates by exe name to avoid launching the same app multiple times.
; ---------------------------------------------------------------------------
LaunchMissingApps(entries) {
    launched := Map()
    for entry in entries {
        exe           := StrLower(entry["exe"])
        workspace     := entry.Has("workspacePath") ? entry["workspacePath"] : ""
        ; Deduplicate by exe + workspace so multiple Cursor projects all launch
        launchKey     := exe . "|" . workspace
        if launched.Has(launchKey)
            continue
        launched[launchKey] := true
        path := entry["exePath"]
        if path != "" && FileExist(path) {
            if workspace != "" {
                ; Use --new-window for Cursor/Code so each project opens its own window
                if (exe == "cursor.exe" || exe == "code.exe") {
                    cmd := '"' . path . '" --new-window "' . workspace . '"'
                } else {
                    cmd := '"' . path . '" "' . workspace . '"'
                }
                DebugLog("LaunchMissing: " . cmd)
                try Run(cmd)
            } else {
                DebugLog("LaunchMissing: " . '"' . path . '"')
                try Run('"' . path . '"')
            }
        } else {
            DebugLog("LaunchMissing (by name): " . entry["exe"])
            try Run(entry["exe"])
        }
    }
    DebugLog("LaunchMissing: launched " . launched.Count . " apps")
}

; ---------------------------------------------------------------------------
; Find the workspace folder for a VS Code / Cursor window by matching the
; window's cleanTitle against the folder base names in Cursor's storage.json.
; Returns the decoded Windows path (e.g. "C:\path\to\project"), or "".
; ---------------------------------------------------------------------------
GetVSCodeWorkspace(cleanTitle, exe) {
    global _WorkspaceFolderCache
    appName := (StrLower(exe) == "cursor.exe") ? "Cursor" : "Code"

    ; Use pre-loaded cache if available; fall back to reading file directly
    folders := []
    if _WorkspaceFolderCache.Has(appName) {
        folders := _WorkspaceFolderCache[appName]
    } else {
        ; Fallback: read storage.json on demand (e.g. called outside CaptureAllWindows)
        wsFile := EnvGet("APPDATA") . "\" . appName . "\User\globalStorage\storage.json"
        if !FileExist(wsFile)
            return ""
        try {
            raw     := FileRead(wsFile, "UTF-8")
            data    := JSON.Parse(raw)
            if !data.Has("windowsState")
                return ""
            wsState := data["windowsState"]
            if wsState.Has("lastActiveWindow") && wsState["lastActiveWindow"].Has("folder")
                folders.Push(wsState["lastActiveWindow"]["folder"])
            if wsState.Has("openedWindows") {
                for wEntry in wsState["openedWindows"] {
                    if wEntry.Has("folder")
                        folders.Push(wEntry["folder"])
                }
            }
        } catch as e {
            DebugLog("GetVSCodeWorkspace failed: " . e.Message)
            return ""
        }
    }

    if folders.Length == 0
        return ""

    ; Extract target folder name from cleanTitle:
    ;   "SomeFile - ProjectFolder" → "ProjectFolder"
    ;   "ProjectFolder"            → "ProjectFolder"
    targetFolder := cleanTitle
    dashPos := InStr(cleanTitle, " - ", , -1)
    if dashPos > 0
        targetFolder := SubStr(cleanTitle, dashPos + 3)

    ; Match folder base name against targetFolder (case-insensitive)
    for folderUri in folders {
        if !folderUri || SubStr(folderUri, 1, 8) != "file:///"
            continue
        decoded   := _UriDecode(SubStr(folderUri, 9))   ; strip "file:///"
        lastSlash := InStr(decoded, "/", , -1)
        baseName  := (lastSlash > 0) ? SubStr(decoded, lastSlash + 1) : decoded
        if StrLower(Trim(baseName)) == StrLower(Trim(targetFolder)) {
            return StrReplace(decoded, "/", "\")
        }
    }
    return ""
}

; Decode percent-encoded characters in a URI path segment.
_UriDecode(str) {
    result := str
    loop {
        pos := RegExMatch(result, "%([0-9A-Fa-f]{2})", &m)
        if !pos
            break
        result := StrReplace(result, m[0], Chr(("0x" . m[1]) + 0))
    }
    return result
}

; ---------------------------------------------------------------------------
; Compare saved windows against the current desktop state.
; Returns a Map with keys: "matched", "moved", "new", "missing"
;   matched = windows at same position/state
;   moved   = windows found but position/state changed
;   new     = windows on desktop not in saved layout
;   missing = saved windows not found on desktop
; ---------------------------------------------------------------------------
SnapshotDiff(savedWindows) {
    current := CaptureAllWindows()
    result := Map("matched", [], "moved", [], "new", [], "missing", [])
    currentMap := Map()
    for w in current {
        key := StrLower(w["exe"]) . "|" . StrLower(w["cleanTitle"])
        currentMap[key] := w
    }
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
    for key, w in currentMap
        result["new"].Push(w)
    return result
}
