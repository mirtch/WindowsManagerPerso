; =============================================================================
; VirtualDesktop.ahk - Windows Virtual Desktop helpers via COM
; Uses the IVirtualDesktopManager interface (documented, stable across updates).
; =============================================================================

global _VDM_Ptr := 0          ; Pointer to IVirtualDesktopManager

; ---------------------------------------------------------------------------
; Initialize the IVirtualDesktopManager COM interface.
; Call once at startup. Safe to call multiple times.
; ---------------------------------------------------------------------------
VD_Init() {
    global _VDM_Ptr
    if _VDM_Ptr
        return true

    try {
        ; CLSID_VirtualDesktopManager = {aa509086-5ca9-4c25-8f95-589d3c07b48a}
        ; IID_IVirtualDesktopManager  = {a5cd92ff-29be-454c-8d04-d82879fb3f1b}
        CLSID := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{aa509086-5ca9-4c25-8f95-589d3c07b48a}", "Ptr", CLSID)

        IID := Buffer(16)
        DllCall("ole32\CLSIDFromString", "Str", "{a5cd92ff-29be-454c-8d04-d82879fb3f1b}", "Ptr", IID)

        pVDM := 0
        hr := DllCall("ole32\CoCreateInstance",
            "Ptr", CLSID,
            "Ptr", 0,
            "UInt", 1,       ; CLSCTX_INPROC_SERVER
            "Ptr", IID,
            "Ptr*", &pVDM,
            "UInt")

        if hr != 0 || !pVDM
            return false

        _VDM_Ptr := pVDM
        return true
    } catch Error {
        return false
    }
}

; ---------------------------------------------------------------------------
; Check if a window is on the current virtual desktop.
; Returns true/false. Falls back to true if COM fails.
; ---------------------------------------------------------------------------
VD_IsOnCurrentDesktop(hwnd) {
    global _VDM_Ptr
    if !_VDM_Ptr
        return true

    try {
        isOnCurrent := 0
        ; vtable index 3 = IsWindowOnCurrentVirtualDesktop(HWND, BOOL*)
        hr := ComCall(3, _VDM_Ptr, "Ptr", hwnd, "Int*", &isOnCurrent)
        if hr != 0
            return true
        return isOnCurrent
    } catch Error {
        return true
    }
}

; ---------------------------------------------------------------------------
; Get the virtual desktop GUID for a window.
; Returns a 16-byte Buffer, or 0 on failure.
; ---------------------------------------------------------------------------
VD_GetDesktopId(hwnd) {
    global _VDM_Ptr
    if !_VDM_Ptr
        return 0

    try {
        guid := Buffer(16, 0)
        ; vtable index 4 = GetWindowDesktopId(HWND, GUID*)
        hr := ComCall(4, _VDM_Ptr, "Ptr", hwnd, "Ptr", guid)
        if hr != 0
            return 0
        return guid
    } catch Error {
        return 0
    }
}

; ---------------------------------------------------------------------------
; Move a window to the virtual desktop identified by a GUID buffer.
; Returns true on success.
; ---------------------------------------------------------------------------
VD_MoveToDesktop(hwnd, guidBuffer) {
    global _VDM_Ptr
    if !_VDM_Ptr || !guidBuffer
        return false

    try {
        ; vtable index 5 = MoveWindowToDesktop(HWND, REFGUID)
        hr := ComCall(5, _VDM_Ptr, "Ptr", hwnd, "Ptr", guidBuffer)
        return hr == 0
    } catch Error {
        return false
    }
}

; ---------------------------------------------------------------------------
; Convert a 16-byte GUID buffer to a string like
; "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}"
; ---------------------------------------------------------------------------
VD_GuidToString(guidBuffer) {
    if !guidBuffer
        return ""
    out := Buffer(78)   ; 39 wide chars * 2 bytes
    DllCall("ole32\StringFromGUID2", "Ptr", guidBuffer, "Ptr", out, "Int", 39)
    return StrGet(out, "UTF-16")
}

; ---------------------------------------------------------------------------
; Convert a GUID string back to a 16-byte Buffer.
; ---------------------------------------------------------------------------
VD_StringToGuid(guidStr) {
    guid := Buffer(16, 0)
    hr := DllCall("ole32\CLSIDFromString", "Str", guidStr, "Ptr", guid)
    if hr != 0
        return 0
    return guid
}

; ---------------------------------------------------------------------------
; Build a map of desktop GUID strings -> sequential indices (1-based)
; by scanning all provided window HWNDs.
; Returns a Map: guidString -> index  (e.g. "{abc...}" -> 1)
; Also returns the list of unique GUIDs in order of first appearance.
; ---------------------------------------------------------------------------
VD_BuildDesktopMap(hwnds) {
    desktopMap := Map()    ; guidString -> index
    guidBuffers := Map()   ; guidString -> Buffer (for restore)
    nextIdx := 1

    for hwnd in hwnds {
        guidBuf := VD_GetDesktopId(hwnd)
        if !guidBuf
            continue
        guidStr := VD_GuidToString(guidBuf)
        if guidStr == ""
            continue
        if !desktopMap.Has(guidStr) {
            desktopMap[guidStr] := nextIdx
            guidBuffers[guidStr] := guidBuf
            nextIdx++
        }
    }
    return Map("indices", desktopMap, "guids", guidBuffers)
}

; ---------------------------------------------------------------------------
; Get the desktop index (1-based) for a specific window HWND.
; Uses the provided desktopMap from VD_BuildDesktopMap.
; Returns 0 if unknown.
; ---------------------------------------------------------------------------
VD_GetDesktopIndex(hwnd, desktopMapData) {
    guidBuf := VD_GetDesktopId(hwnd)
    if !guidBuf
        return 0
    guidStr := VD_GuidToString(guidBuf)
    indices := desktopMapData["indices"]
    if indices.Has(guidStr)
        return indices[guidStr]
    return 0
}
