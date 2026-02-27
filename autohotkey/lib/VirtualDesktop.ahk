; =============================================================================
; VirtualDesktop.ahk - Windows Virtual Desktop helpers via COM
; Public API  : IVirtualDesktopManager (documented, stable)
; Internal API: IVirtualDesktopManagerInternal + IApplicationViewCollection
;               (undocumented, Windows 11 24H2/25H2 Build 26100+)
;               Required to move windows owned by other processes.
; =============================================================================

global _VDM_Ptr  := 0    ; IVirtualDesktopManager*        (public)
global _VDMI_Ptr := 0    ; IVirtualDesktopManagerInternal* (internal)
global _AVC_Ptr  := 0    ; IApplicationViewCollection*     (internal)

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
        DebugLog("VD_MoveToDesktop hr=0x" . Format("{:08X}", hr) . " hwnd=" . hwnd)
        return hr == 0
    } catch Error as e {
        ; ComCall throws on failure HRESULTs (negative values).
        ; e.Number contains the HRESULT; common codes:
        ;   0x80070057 = E_INVALIDARG  (bad hwnd or guid)
        ;   0x80004005 = E_FAIL        (generic — often means target desktop doesn't exist)
        ;   0x80070005 = E_ACCESSDENIED
        DebugLog("VD_MoveToDesktop FAILED hwnd=" . hwnd
            . " HRESULT=0x" . Format("{:08X}", e.Number & 0xFFFFFFFF)
            . " (" . e.Message . ")")
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

; ===========================================================================
; INTERNAL COM API — Windows 11 24H2 / 25H2 (Build 26100+)
; Uses IVirtualDesktopManagerInternal + IApplicationViewCollection obtained
; via IServiceProvider chain from the immersive shell.  This bypasses the
; E_ACCESSDENIED limitation of the public IVirtualDesktopManager API.
;
; GUIDs sourced from MScholtes/VirtualDesktop (VirtualDesktop11-24H2.cs).
; Vtable indices are absolute (0=QueryInterface, 1=AddRef, 2=Release, 3+).
; ===========================================================================

; ---------------------------------------------------------------------------
; Initialize the internal COM interfaces (lazy, called on first use).
; Returns true if both interfaces are available.
; ---------------------------------------------------------------------------
VD_Internal_Init() {
    global _VDMI_Ptr, _AVC_Ptr
    if _VDMI_Ptr && _AVC_Ptr
        return true

    try {
        ; ─── Step 1: IServiceProvider from ImmersiveShell ───
        ; CLSID_ImmersiveShell = {C2F03A33-21F5-47FA-B4BB-156362A2F239}
        ; IID_IServiceProvider  = {6D5140C1-7436-11CE-8034-00AA006009FA}
        CLSID_Shell := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{C2F03A33-21F5-47FA-B4BB-156362A2F239}", "Ptr", CLSID_Shell)
        IID_ISP := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{6D5140C1-7436-11CE-8034-00AA006009FA}", "Ptr", IID_ISP)

        pShell := 0
        ; Shell runs in explorer.exe → CLSCTX_LOCAL_SERVER (4)
        hr := DllCall("ole32\CoCreateInstance",
            "Ptr", CLSID_Shell, "Ptr", 0, "UInt", 4, "Ptr", IID_ISP,
            "Ptr*", &pShell, "UInt")
        if hr != 0 || !pShell {
            DebugLog("VD_Internal_Init: CoCreateInstance failed hr=0x" . Format("{:08X}", hr))
            return false
        }

        ; ─── Step 2: IVirtualDesktopManagerInternal ───
        ; Service CLSID: {C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B}
        ; IID (Win11 24H2/25H2): {53F5CA0B-158F-4124-900C-057158060B27}
        SVC_VDMI := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B}", "Ptr", SVC_VDMI)
        IID_VDMI := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{53F5CA0B-158F-4124-900C-057158060B27}", "Ptr", IID_VDMI)

        pVDMI := 0
        ; IServiceProvider::QueryService = vtable[3]
        hr := ComCall(3, pShell, "Ptr", SVC_VDMI, "Ptr", IID_VDMI, "Ptr*", &pVDMI, "UInt")
        if hr != 0 || !pVDMI {
            DebugLog("VD_Internal_Init: QueryService(VDMI) failed hr=0x" . Format("{:08X}", hr))
            return false
        }

        ; ─── Step 3: IApplicationViewCollection ───
        ; Service CLSID = IID = {1841C6D7-4F9D-42C0-AF41-8747538F10E5}
        SVC_AVC := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{1841C6D7-4F9D-42C0-AF41-8747538F10E5}", "Ptr", SVC_AVC)
        IID_AVC := Buffer(16)
        DllCall("ole32\CLSIDFromString",
            "Str", "{1841C6D7-4F9D-42C0-AF41-8747538F10E5}", "Ptr", IID_AVC)

        pAVC := 0
        hr := ComCall(3, pShell, "Ptr", SVC_AVC, "Ptr", IID_AVC, "Ptr*", &pAVC, "UInt")
        if hr != 0 || !pAVC {
            DebugLog("VD_Internal_Init: QueryService(AVC) failed hr=0x" . Format("{:08X}", hr))
            return false
        }

        _VDMI_Ptr := pVDMI
        _AVC_Ptr  := pAVC
        DebugLog("VD_Internal_Init: OK")
        return true
    } catch Error as e {
        DebugLog("VD_Internal_Init FAILED: " . e.Message)
        return false
    }
}

; ---------------------------------------------------------------------------
; Move any window to a virtual desktop using the undocumented internal API.
; Works for windows owned by other processes (Edge, Chrome, Explorer, etc.)
; unlike the public VD_MoveToDesktop which returns E_ACCESSDENIED.
; guidBuffer: 16-byte Buffer from VD_StringToGuid.
; Returns true on success.
; ---------------------------------------------------------------------------
VD_Internal_MoveToDesktop(hwnd, guidBuffer) {
    global _VDMI_Ptr, _AVC_Ptr
    if !_VDMI_Ptr || !_AVC_Ptr || !guidBuffer
        return false

    try {
        ; Get IApplicationView for the HWND
        ; IApplicationViewCollection::GetViewForHwnd = vtable[6]
        pView := 0
        hr := ComCall(6, _AVC_Ptr, "Ptr", hwnd, "Ptr*", &pView, "UInt")
        if hr != 0 || !pView {
            DebugLog("VD_Internal: GetViewForHwnd failed hr=0x" . Format("{:08X}", hr) . " hwnd=" . hwnd)
            return false
        }

        ; Find the target IVirtualDesktop by GUID
        ; IVirtualDesktopManagerInternal::FindDesktop = vtable[14]
        pDesktop := 0
        hr := ComCall(14, _VDMI_Ptr, "Ptr", guidBuffer, "Ptr*", &pDesktop, "UInt")
        if hr != 0 || !pDesktop {
            DebugLog("VD_Internal: FindDesktop failed hr=0x" . Format("{:08X}", hr))
            return false
        }

        ; Move the view to the desktop
        ; IVirtualDesktopManagerInternal::MoveViewToDesktop = vtable[4]
        hr := ComCall(4, _VDMI_Ptr, "Ptr", pView, "Ptr", pDesktop, "UInt")
        DebugLog("VD_Internal_MoveToDesktop hr=0x" . Format("{:08X}", hr) . " hwnd=" . hwnd)
        return hr == 0
    } catch Error as e {
        DebugLog("VD_Internal_MoveToDesktop FAILED hwnd=" . hwnd
            . " HRESULT=0x" . Format("{:08X}", e.Number & 0xFFFFFFFF)
            . " (" . e.Message . ")")
        return false
    }
}
