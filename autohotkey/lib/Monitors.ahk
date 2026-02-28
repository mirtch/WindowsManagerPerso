; =============================================================================
; Monitors.ahk - Monitor detection helpers for AutoHotkey v2
; =============================================================================

; Returns a Map with keys: left, top, right, bottom, w, h
; for the full bounds of the given monitor index (1-based).
GetMonitorBounds(idx) {
    MonitorGet(idx, &left, &top, &right, &bottom)
    return Map(
        "left",   left,
        "top",    top,
        "right",  right,
        "bottom", bottom,
        "w",      right - left,
        "h",      bottom - top
    )
}

; Returns the work area (excluding taskbar) for the given monitor index.
GetMonitorWorkArea(idx) {
    MonitorGetWorkArea(idx, &left, &top, &right, &bottom)
    return Map(
        "left",   left,
        "top",    top,
        "right",  right,
        "bottom", bottom,
        "w",      right - left,
        "h",      bottom - top
    )
}

; Returns the monitor index (1-based) that contains the point (x, y).
; Falls back to the primary monitor if the point is off-screen.
GetMonitorForPoint(x, y) {
    count := MonitorGetCount()
    Loop count {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        if (x >= left && x < right && y >= top && y < bottom)
            return A_Index
    }
    ; Point not on any monitor - find nearest
    bestIdx  := MonitorGetPrimary()
    bestDist := 99999999
    Loop count {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        cx := (left + right) // 2
        cy := (top + bottom) // 2
        dx := x - cx
        dy := y - cy
        dist := dx*dx + dy*dy
        if dist < bestDist {
            bestDist := dist
            bestIdx  := A_Index
        }
    }
    return bestIdx
}

; Returns the monitor index that the center of the given window falls on.
GetMonitorForWindow(hwnd) {
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
        return GetMonitorForPoint(x + w // 2, y + h // 2)
    } catch {
        return MonitorGetPrimary()
    }
}

; Returns an Array of Maps, one per monitor, each containing:
;   index, name, primary, left, top, right, bottom, w, h
GetAllMonitorInfo() {
    monitors := []
    count    := MonitorGetCount()
    primary  := MonitorGetPrimary()
    Loop count {
        info := GetMonitorBounds(A_Index)
        info["index"]   := A_Index
        info["primary"] := (A_Index == primary)
        try
            info["name"] := MonitorGetName(A_Index)
        catch Error {
            info["name"] := "Monitor " . A_Index
        }
        monitors.Push(info)
    }
    return monitors
}

; Clamp a window rect so it is visible on at least one monitor.
; Returns a Map with clamped x, y, w, h.
ClampToMonitor(x, y, w, h) {
    count := MonitorGetCount()
    ; Find the monitor whose center is closest to the window center
    cx := x + w // 2
    cy := y + h // 2
    idx := GetMonitorForPoint(cx, cy)

    try MonitorGetWorkArea(idx, &ml, &mt, &mr, &mb)
    catch {
        ml := 0
        mt := 0
        mr := A_ScreenWidth
        mb := A_ScreenHeight
    }

    ; Clamp position so at least 100px of the window is visible
    newX := Max(ml, Min(x, mr - 100))
    newY := Max(mt, Min(y, mb - 100))
    ; Cap size to monitor work area
    newW := Min(w, mr - ml)
    newH := Min(h, mb - mt)
    return Map("x", newX, "y", newY, "w", newW, "h", newH)
}

; ---------------------------------------------------------------------------
; Monitor configuration fingerprint.
; Returns a stable string describing the current monitor setup:
;   "N:WxH@X,Y|WxH@X,Y|..."
; Parts are sorted alphabetically for deterministic ordering regardless of
; which monitor index Windows assigns to each display.
; ---------------------------------------------------------------------------
GetMonitorFingerprint() {
    count := MonitorGetCount()
    parts := []
    Loop count {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        mw := right - left
        mh := bottom - top
        parts.Push(mw . "x" . mh . "@" . left . "," . top)
    }

    ; Bubble sort parts alphabetically for stable ordering
    Loop parts.Length - 1 {
        i := A_Index
        Loop parts.Length - i {
            j := A_Index + i
            if StrCompare(parts[j], parts[j - 1], false) < 0 {
                tmp          := parts[j]
                parts[j]     := parts[j - 1]
                parts[j - 1] := tmp
            }
        }
    }

    ; Join parts with "|"
    result := count . ":"
    for idx, part in parts {
        if idx > 1
            result .= "|"
        result .= part
    }
    return result
}

; ---------------------------------------------------------------------------
; Returns the DPI scale factor for the given monitor index.
; 1.0 = 96 DPI (100%), 1.25 = 120 DPI (125%), 1.5 = 144 DPI (150%), etc.
; Falls back to 1.0 if the DPI cannot be determined.
; ---------------------------------------------------------------------------
GetMonitorDPI(monitorIndex) {
    MonitorGet(monitorIndex, &left, &top, &right, &bottom)
    cx := (left + right) // 2
    cy := (top + bottom) // 2
    ; Pack point as Int64 for MonitorFromPoint
    pt := (cy << 32) | (cx & 0xFFFFFFFF)
    hMon := DllCall("MonitorFromPoint", "Int64", pt, "UInt", 0, "Ptr")
    if !hMon
        return 1.0
    dpiX := 0
    dpiY := 0
    hr := DllCall("Shcore\GetDpiForMonitor", "Ptr", hMon, "UInt", 0, "UInt*", &dpiX, "UInt*", &dpiY, "UInt")
    if hr != 0
        return 1.0
    return dpiX / 96.0
}
