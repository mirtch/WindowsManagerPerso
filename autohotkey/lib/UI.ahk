; =============================================================================
; UI.ahk - Tray menu, GUIs, and notification helpers
; Nested function callbacks use (*) to accept and ignore the Gui control params.
; =============================================================================

; ---------------------------------------------------------------------------
; Tray icon and menu setup
; ---------------------------------------------------------------------------
SetupTray() {
    A_IconTip := "Workspace Layout Manager"
    ; Use a built-in shell icon (no external file needed)
    try TraySetIcon("shell32.dll", 162)

    tray := A_TrayMenu
    tray.Delete()   ; Remove AHK defaults

    ; Define handlers as proper nested functions (block syntax required for AHK v2)
    _OnSave(*) {
        SaveLayoutAction()
    }
    _OnQuickSave(*) {
        QuickSaveAction()
    }
    _OnRestore(*) {
        RestoreLayoutAction()
    }
    _OnManage(*) {
        ShowManageDialog()
    }
    _OnSettings(*) {
        ShowSettingsDialog()
    }
    _OnErrorLog(*) {
        ShowErrorLog()
    }
    _OnViewDebugLog(*) {
        global DebugFile
        if FileExist(DebugFile)
            Run("notepad.exe `"" . DebugFile . "`"")
        else
            MsgBox("No debug log yet.`n`nEnable debug mode first:`nSettings > Advanced > Debug mode", "Debug Log", "Icon!")
    }
    _OnCycle(*) {
        CycleLayoutAction()
    }
    _OnQuickSwitch(*) {
        QuickSwitchAction()
    }
    _OnReload(*) {
        Reload()
    }
    _OnExit(*) {
        ExitApp()
    }

    tray.Add("Save Layout`tCtrl+Alt+S",       _OnSave)
    tray.Add("Quick Save`tCtrl+Alt+Q",        _OnQuickSave)
    tray.Add("Restore Layout`tCtrl+Alt+R",    _OnRestore)
    tray.Add()
    tray.Add("Manage Layouts",                _OnManage)
    tray.Add("Next Layout`tCtrl+Alt+N",       _OnCycle)
    tray.Add("Quick Switch`tCtrl+Alt+Tab",    _OnQuickSwitch)
    tray.Add("Settings",                      _OnSettings)
    tray.Add("Error Log",                    _OnErrorLog)
    tray.Add("Debug Log",                    _OnViewDebugLog)
    tray.Add()
    tray.Add("Reload Script",                _OnReload)
    tray.Add("Exit",                         _OnExit)
}

; ---------------------------------------------------------------------------
; Tray icon state (changes the icon to reflect current app state)
; ---------------------------------------------------------------------------
SetTrayIconState(state) {
    switch state {
        case "idle":
            try TraySetIcon("shell32.dll", 162)
        case "working":
            try TraySetIcon("shell32.dll", 239)
        case "error":
            try TraySetIcon("shell32.dll", 110)
        case "success":
            try TraySetIcon("shell32.dll", 297)
    }
}

; ---------------------------------------------------------------------------
; Toast-style notification (custom dark GUI, auto-dismisses)
; ---------------------------------------------------------------------------
global _ToastGui := false

ShowToast(msg, durationMs := 3000) {
    global _ToastGui

    ; Destroy previous toast
    if _ToastGui {
        try _ToastGui.Destroy()
        _ToastGui := false
    }

    ; Create borderless dark toast
    toast := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
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
        "UInt", 33, "Int*", 2, "UInt", 4)

    _ToastGui := toast
    SetTimer(DismissToast, -durationMs)
}

DismissToast() {
    global _ToastGui
    if _ToastGui {
        try _ToastGui.Destroy()
        _ToastGui := false
    }
}

; ---------------------------------------------------------------------------
; Visual progress bar (dark GUI with progress control)
; ---------------------------------------------------------------------------
global _ProgressGui := false
global _ProgressBar := false
global _ProgressText := false

ShowProgress(msg) {
    global _ProgressGui, _ProgressBar, _ProgressText
    if _ProgressGui {
        try _ProgressText.Text := msg
        RegExMatch(msg, "(\d+)/(\d+)", &m)
        if m {
            pct := Round(Integer(m[1]) / Integer(m[2]) * 100)
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
    _ProgressBar := pg.Add("Progress", "w280 h6 c4EC9B0 Background333333", 0)
    workArea := GetMonitorWorkArea(MonitorGetPrimary())
    pg.Show("NoActivate Hide")
    pg.GetPos(, , &pw, &ph)
    px := workArea["right"] - pw - 16
    py := workArea["bottom"] - ph - 60
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

; ---------------------------------------------------------------------------
; Notification level helpers
;   Levels (from most to least verbose): verbose > normal > errors > silent
;   A message is shown when its level meets or exceeds the configured level.
; ---------------------------------------------------------------------------

; Returns true if a message at msgLevel should be shown given the current setting.
ShouldNotify(msgLevel) {
    global Settings
    levelRank := Map("verbose", 1, "normal", 2, "errors", 3, "silent", 4)
    setting := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    if !levelRank.Has(setting)
        setting := "normal"
    if !levelRank.Has(msgLevel)
        msgLevel := "normal"
    return levelRank[msgLevel] >= levelRank[setting]
}

; Show a toast notification only if the notification level allows it.
Notify(msg, level := "normal", durationMs := 3000) {
    if ShouldNotify(level)
        ShowToast(msg, durationMs)
}

; Show an error notification. Uses MsgBox unless level is "silent".
NotifyError(msg, title := "Error") {
    global Settings, AppName
    setting := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    if setting == "silent"
        return
    if setting == "errors" || setting == "normal" || setting == "verbose"
        MsgBox(msg, AppName . " - " . title, "IconX")
}

; ---------------------------------------------------------------------------
; Error log - keeps a rolling history of errors for review
; ---------------------------------------------------------------------------
global _ErrorHistory := []

LogError(msg, title := "Error") {
    global _ErrorHistory
    _ErrorHistory.Push(Map("time", FormatTime(, "HH:mm:ss"), "msg", msg, "title", title))
    if _ErrorHistory.Length > 50
        _ErrorHistory.RemoveAt(1)
    NotifyError(msg, title)
}

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
    logGui.Add("Edit", "w500 h300 ReadOnly -WantReturn Background2A2A3E", content)
    logGui.Add("Button", "Default w80", "Close").OnEvent("Click", (*) => logGui.Destroy())
    logGui.OnEvent("Close", (*) => logGui.Destroy())
    ApplyDarkTheme(logGui)
    logGui.Show()
}

; ---------------------------------------------------------------------------
; Dark theme helper - applies dark background and title bar to any Gui
; ---------------------------------------------------------------------------
ApplyDarkTheme(guiObj) {
    guiObj.BackColor := "1E1E2E"
    ; Dark title bar (Windows 10 1809+)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd,
        "UInt", 20, "Int*", 1, "UInt", 4)
    ; Rounded corners (Windows 11)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd,
        "UInt", 33, "Int*", 2, "UInt", 4)
}

; ---------------------------------------------------------------------------
; Save Layout Dialog
;   Shows an input box asking for a layout name.
;   Calls callback(name) when the user confirms.
; ---------------------------------------------------------------------------
ShowSaveDialog(callback) {
    saveGui := Gui("+AlwaysOnTop +Owner", "Save Layout")
    saveGui.SetFont("s10 cFFFFFF", "Segoe UI")
    saveGui.MarginX := 14
    saveGui.MarginY := 10

    saveGui.Add("Text", , "Layout name (leave blank for 'Last'):")
    nameEdit := saveGui.Add("Edit", "w260 Background2A2A3E vLayoutName", "Last")

    btnRow := saveGui.Add("Button", "Default w120", "Save")
    btnRow.OnEvent("Click", OnSave)
    btnCancel := saveGui.Add("Button", "x+8 w90", "Cancel")
    btnCancel.OnEvent("Click", OnCancel)

    OnSave(*) {
        name := Trim(nameEdit.Value)
        if name == ""
            name := "Last"
        saveGui.Destroy()
        callback(name)
    }
    OnCancel(*) {
        saveGui.Destroy()
    }

    saveGui.OnEvent("Close", OnCancel)
    nameEdit.Focus()
    ApplyDarkTheme(saveGui)
    saveGui.Show()
}

; ---------------------------------------------------------------------------
; Restore Layout Dialog
;   Shows a list of available layout names.
;   Calls callback(name) when the user picks one and clicks Restore.
; ---------------------------------------------------------------------------
ShowRestoreDialog(layoutNames, callback) {
    global Layouts
    if layoutNames.Length == 0 {
        MsgBox("No layouts saved yet.`n`nPress Ctrl+Alt+S to capture your first layout.",
               "Restore Layout", "Icon!")
        return
    }

    restGui := Gui("+AlwaysOnTop +Owner", "Restore Layout")
    restGui.SetFont("s10 cFFFFFF", "Segoe UI")
    restGui.MarginX := 14
    restGui.MarginY := 10

    restGui.Add("Text", , "Select a layout to restore:")
    lb := restGui.Add("ListBox", "w200 r12 vSelection")

    ; Preview panel on the right
    preview := restGui.Add("Edit", "x+10 yp w320 r12 ReadOnly -WantReturn Background2A2A3E")

    ; Populate list with window counts
    for name in layoutNames {
        winCount := 0
        if Layouts.Has(name) && Layouts[name].Has("windows")
            winCount := Layouts[name]["windows"].Length
        lb.Add([name . " (" . winCount . ")"])
    }
    if layoutNames.Length > 0
        lb.Choose(1)

    ; Update preview when selection changes
    UpdatePreview(*) {
        idx := lb.Value
        if idx == 0 || idx > layoutNames.Length {
            preview.Value := ""
            return
        }
        name := layoutNames[idx]
        if !Layouts.Has(name) {
            preview.Value := "(no data)"
            return
        }
        layout := Layouts[name]
        lines := "Layout: " . name . "`r`n"
        if layout.Has("timestamp")
            lines .= "Saved: " . layout["timestamp"] . "`r`n"
        if !layout.Has("windows") || layout["windows"].Length == 0 {
            lines .= "`r`n(empty layout)"
            preview.Value := lines
            return
        }
        lines .= "Windows: " . layout["windows"].Length . "`r`n`r`n"
        for w in layout["windows"] {
            deskLabel := w.Has("desktopIndex") && w["desktopIndex"] > 0
                ? " [D" . w["desktopIndex"] . "]" : ""
            lines .= w["exe"] . " – " . w["cleanTitle"] . deskLabel . "`r`n"
        }
        preview.Value := lines
    }

    lb.OnEvent("Change", UpdatePreview)
    UpdatePreview()   ; show first item immediately

    ; Double-click to restore immediately
    lb.OnEvent("DoubleClick", OnRestore)

    btnRow := restGui.Add("Button", "xm Default w120", "Restore")
    btnRow.OnEvent("Click", OnRestore)
    btnCancel := restGui.Add("Button", "x+8 w90", "Cancel")
    btnCancel.OnEvent("Click", OnCancel)
    btnDiff := restGui.Add("Button", "x+8 w100", "Compare")
    OnDiff(*) {
        idx := lb.Value
        if idx == 0 || idx > layoutNames.Length
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

    OnRestore(*) {
        idx := lb.Value
        if idx == 0 {
            MsgBox("Please select a layout.", "Restore Layout", "Icon!")
            return
        }
        name := layoutNames[idx]
        restGui.Destroy()
        callback(name)
    }
    OnCancel(*) {
        restGui.Destroy()
    }

    restGui.OnEvent("Close", OnCancel)
    ApplyDarkTheme(restGui)
    restGui.Show()
}

; ---------------------------------------------------------------------------
; Manage Layouts Dialog
;   Lists all layouts with window count and timestamp.
;   Supports rename, delete, and set-as-default.
; ---------------------------------------------------------------------------
ShowManageDialog() {
    global Layouts, Settings

    mgGui := Gui("+Resize +MinSize420x300", "Manage Layouts")
    mgGui.SetFont("s10 cFFFFFF", "Segoe UI")
    mgGui.MarginX := 14
    mgGui.MarginY := 10

    mgGui.Add("Text", , "Saved layouts:")
    lv := mgGui.Add("ListView", "w460 h260 -Multi Grid", ["Layout Name", "Windows", "Saved At"])

    ; Nested helpers — closures over lv, mgGui, Layouts, Settings
    RefreshList() {
        lv.Delete()
        for name, layout in Layouts {
            winCount    := layout.Has("windows")   ? layout["windows"].Length : 0
            timestamp   := layout.Has("timestamp") ? layout["timestamp"] : ""
            isDefault   := Settings.Has("startupLayout") && Settings["startupLayout"] == name
            displayName := isDefault ? name . " ★" : name
            lv.Add(, displayName, winCount, timestamp)
        }
        lv.ModifyCol(1, 180)
        lv.ModifyCol(2, 70, "Center")
        lv.ModifyCol(3, 185)
    }

    GetSelectedName() {
        row := lv.GetNext(0)
        if !row
            return ""
        raw := lv.GetText(row, 1)
        return Trim(StrReplace(raw, " ★", ""))
    }

    RefreshList()

    ; -- Button row --
    btnRename  := mgGui.Add("Button", "w110", "Rename")
    btnDelete  := mgGui.Add("Button", "x+6 w110", "Delete")
    btnDefault := mgGui.Add("Button", "x+6 w140", "Set as Default ★")
    btnClose   := mgGui.Add("Button", "x+6 w80 Default", "Close")

    ; Proper nested function syntax (no inline lambda blocks in AHK v2)
    OnRename(*) {
        name := GetSelectedName()
        if name == "" {
            MsgBox("Select a layout first.", "Rename", "Icon!")
            return
        }
        ib := InputBox("New name:", "Rename Layout", "w300 h120", name)
        if ib.Result == "Cancel" || Trim(ib.Value) == ""
            return
        newName := Trim(ib.Value)
        if Layouts.Has(newName) {
            MsgBox("A layout named '" . newName . "' already exists.", "Rename", "IconX")
            return
        }
        Layouts[newName] := Layouts[name]
        Layouts[newName]["name"] := newName
        Layouts.Delete(name)
        if Settings["startupLayout"] == name
            Settings["startupLayout"] := newName
        SaveLayouts()
        SaveSettings()
        RefreshList()
    }

    OnDelete(*) {
        name := GetSelectedName()
        if name == "" {
            MsgBox("Select a layout first.", "Delete", "Icon!")
            return
        }
        if MsgBox("Delete layout '" . name . "'?", "Confirm Delete", "YesNo Icon?") == "No"
            return
        Layouts.Delete(name)
        if Settings["startupLayout"] == name
            Settings["startupLayout"] := ""
        SaveLayouts()
        SaveSettings()
        RefreshList()
    }

    OnSetDefault(*) {
        name := GetSelectedName()
        if name == "" {
            MsgBox("Select a layout first.", "Set Default", "Icon!")
            return
        }
        Settings["startupLayout"] := name
        SaveSettings()
        RefreshList()
        ShowToast("Default startup layout set to: " . name)
    }

    OnMgClose(*) {
        mgGui.Destroy()
    }

    btnRename.OnEvent("Click",  OnRename)
    btnDelete.OnEvent("Click",  OnDelete)
    btnDefault.OnEvent("Click", OnSetDefault)
    btnClose.OnEvent("Click",   OnMgClose)
    mgGui.OnEvent("Close",      OnMgClose)

    ; -- Export / Import row --
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

    ApplyDarkTheme(mgGui)
    mgGui.Show()
}

; ---------------------------------------------------------------------------
; Settings Dialog (tabbed: General, Startup, Advanced)
; ---------------------------------------------------------------------------
ShowSettingsDialog() {
    global Settings, Layouts

    setGui := Gui("+AlwaysOnTop +Owner", "Settings - Workspace Layout Manager")
    setGui.SetFont("s10 cFFFFFF", "Segoe UI")
    setGui.MarginX := 16
    setGui.MarginY := 12

    ; Tab3 dimensions stored so buttons can be placed precisely below.
    ; "y+N" after UseTab(0) is relative to the last in-tab control, which
    ; can land inside the Tab3's visual area — use explicit Y instead.
    tabH := 260
    tabs := setGui.Add("Tab3", "w420 h" . tabH, ["General", "Startup", "Advanced"])

    ; ── Tab 1: General ──────────────────────────────────────────────────────
    tabs.UseTab(1)
    cbLaunch := setGui.Add("Checkbox", "vLaunchMissing", "Launch missing apps when restoring")
    cbLaunch.Value := Settings.Has("launchMissing") ? Settings["launchMissing"] : 0

    setGui.Add("Text", "xp y+16", "Auto-save interval (minutes, 0 = off):")
    autoSaveEdit := setGui.Add("Edit", "xp y+4 w70 Number Background2A2A3E vAutoSaveMinutes",
        Settings.Has("autoSaveMinutes") ? Settings["autoSaveMinutes"] : 15)

    setGui.Add("Text", "xp y+16", "Notification level:")
    notifLevels := ["verbose", "normal", "errors", "silent"]
    ddlNotif := setGui.Add("DropDownList", "xp y+4 w200 vNotificationLevel", notifLevels)
    currentNotif := Settings.Has("notificationLevel") ? Settings["notificationLevel"] : "normal"
    notifIdx := 2
    Loop notifLevels.Length {
        if notifLevels[A_Index] == currentNotif {
            notifIdx := A_Index
            break
        }
    }
    ddlNotif.Choose(notifIdx)

    ; ── Tab 2: Startup ──────────────────────────────────────────────────────
    tabs.UseTab(2)
    cbAuto := setGui.Add("Checkbox", "vAutoRestore", "Auto-restore layout on login")
    cbAuto.Value := Settings.Has("autoRestore") ? Settings["autoRestore"] : 0

    setGui.Add("Text", "xp y+16", "Startup layout:")
    names := ["(none)"]
    for k, _ in Layouts
        names.Push(k)
    ddl := setGui.Add("DropDownList", "xp y+4 w280 vStartupLayout", names)
    startupVal := Settings.Has("startupLayout") ? Settings["startupLayout"] : ""
    choiceIdx := 1
    Loop names.Length {
        if names[A_Index] == startupVal {
            choiceIdx := A_Index
            break
        }
    }
    ddl.Choose(choiceIdx)

    setGui.Add("Text", "xp y+16", "Restore delay after login (seconds):")
    delayEdit := setGui.Add("Edit", "xp y+4 w70 Number Background2A2A3E vRestoreDelay",
        Settings.Has("restoreDelay") ? Settings["restoreDelay"] : 10)

    setGui.Add("Text", "xp y+20", "Windows Startup:")
    OnAddStartup(*) {
        AddToStartup()
        ShowToast("Added to Windows startup.")
    }
    OnRemoveStartup(*) {
        RemoveFromStartup()
        ShowToast("Removed from Windows startup.")
    }
    setGui.Add("Button", "xp y+6 w150", "Add to Startup").OnEvent("Click", OnAddStartup)
    setGui.Add("Button", "x+8 w170", "Remove from Startup").OnEvent("Click", OnRemoveStartup)

    ; ── Tab 3: Advanced ─────────────────────────────────────────────────────
    tabs.UseTab(3)
    cbDebug := setGui.Add("Checkbox", "vDebugMode", "Debug mode (log to debug.log)")
    cbDebug.Value := Settings.Has("debugMode") ? Settings["debugMode"] : 0

    setGui.Add("Text", "xp y+16", "Max layout versions to keep:")
    setGui.Add("Edit", "xp y+4 w70 Number Background2A2A3E vMaxLayoutVersions",
        Settings.Has("maxLayoutVersions") ? Settings["maxLayoutVersions"] : 3)

    ; ── Buttons below tabs ──────────────────────────────────────────────────
    tabs.UseTab(0)
    ; Explicit Y below Tab3: MarginY(12) + tabH(260) + gap(10) = 282
    btnY := 12 + tabH + 10
    setGui.Add("Button", "xm y" . btnY . " Default w100", "Save").OnEvent("Click", OnSave)
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
        Notify("Settings saved.")
    }

    setGui.OnEvent("Close", (*) => setGui.Destroy())
    ApplyDarkTheme(setGui)
    setGui.Show()
}

; ---------------------------------------------------------------------------
; Small always-on-top status window used during long restores.
; ---------------------------------------------------------------------------
global _StatusWin := false
global _StatusLbl := false

ShowStatusWindow(msg) {
    global _StatusWin, _StatusLbl
    if _StatusWin {
        try _StatusLbl.Text := msg
        return
    }
    sw := Gui("+AlwaysOnTop -Caption +ToolWindow", "WLM Status")
    sw.SetFont("s10", "Segoe UI")
    sw.BackColor := "1A1A2E"
    _StatusLbl := sw.Add("Text", "cWhite w300 Center", msg)
    _StatusWin := sw
    sw.Show("NoActivate")
}

CloseStatusWindow() {
    global _StatusWin, _StatusLbl
    if _StatusWin {
        try _StatusWin.Destroy()
        _StatusWin := false
        _StatusLbl := false
    }
}
