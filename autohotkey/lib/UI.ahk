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
    tray.Add("Settings",                      _OnSettings)
    tray.Add()
    tray.Add("Reload Script",                _OnReload)
    tray.Add("Exit",                         _OnExit)
}

; ---------------------------------------------------------------------------
; Toast-style notification (ToolTip #1, auto-clears)
; ---------------------------------------------------------------------------
ShowToast(msg, durationMs := 3000) {
    ToolTip(msg)
    SetTimer(ClearToast, -durationMs)
}

ClearToast() {
    ToolTip()
}

; Progress notification uses ToolTip #2 so it doesn't stomp on toasts.
ShowProgress(msg) {
    ToolTip(msg, , , 2)
}

HideProgress() {
    ToolTip(, , , 2)
}

; ---------------------------------------------------------------------------
; Save Layout Dialog
;   Shows an input box asking for a layout name.
;   Calls callback(name) when the user confirms.
; ---------------------------------------------------------------------------
ShowSaveDialog(callback) {
    saveGui := Gui("+AlwaysOnTop +Owner", "Save Layout")
    saveGui.SetFont("s10", "Segoe UI")
    saveGui.MarginX := 14
    saveGui.MarginY := 10

    saveGui.Add("Text", , "Layout name (leave blank for 'Last'):")
    nameEdit := saveGui.Add("Edit", "w260 vLayoutName", "Last")

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
    restGui.SetFont("s10", "Segoe UI")
    restGui.MarginX := 14
    restGui.MarginY := 10

    restGui.Add("Text", , "Select a layout to restore:")
    lb := restGui.Add("ListBox", "w200 r12 vSelection")

    ; Preview panel on the right
    preview := restGui.Add("Edit", "x+10 yp w320 r12 ReadOnly -WantReturn")

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
    mgGui.SetFont("s10", "Segoe UI")
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

    mgGui.Show()
}

; ---------------------------------------------------------------------------
; Settings Dialog
; ---------------------------------------------------------------------------
ShowSettingsDialog() {
    global Settings, Layouts

    setGui := Gui("+AlwaysOnTop +Owner", "Settings - Workspace Layout Manager")
    setGui.SetFont("s10", "Segoe UI")
    setGui.MarginX := 14
    setGui.MarginY := 10

    ; -- Auto-restore --
    cbAuto := setGui.Add("Checkbox", "vAutoRestore", "Auto-restore layout on Windows login")
    cbAuto.Value := Settings.Has("autoRestore") ? Settings["autoRestore"] : 0

    ; -- Startup layout dropdown --
    setGui.Add("Text", "xm y+8", "Startup layout:")
    names := ["(none)"]
    for k, _ in Layouts
        names.Push(k)
    ddl := setGui.Add("DropDownList", "xm w250 vStartupLayout", names)
    startupVal := Settings.Has("startupLayout") ? Settings["startupLayout"] : ""
    choiceIdx := 1
    Loop names.Length {
        if names[A_Index] == startupVal {
            choiceIdx := A_Index
            break
        }
    }
    ddl.Choose(choiceIdx)

    ; -- Restore delay --
    setGui.Add("Text", "xm y+8", "Restore delay after login (seconds):")
    delayEdit := setGui.Add("Edit", "xm w70 Number vRestoreDelay",
                            Settings.Has("restoreDelay") ? Settings["restoreDelay"] : 10)

    ; -- Launch missing --
    cbLaunch := setGui.Add("Checkbox", "xm y+8 vLaunchMissing", "Launch missing apps when restoring")
    cbLaunch.Value := Settings.Has("launchMissing") ? Settings["launchMissing"] : 0

    ; -- Auto-save interval --
    setGui.Add("Text", "xm y+8", "Auto-save interval (minutes, 0 = disabled):")
    autoSaveEdit := setGui.Add("Edit", "xm w70 Number vAutoSaveMinutes",
                               Settings.Has("autoSaveMinutes") ? Settings["autoSaveMinutes"] : 15)

    ; -- Debug mode --
    cbDebug := setGui.Add("Checkbox", "xm y+4 vDebugMode", "Debug mode (log to debug.log)")
    cbDebug.Value := Settings.Has("debugMode") ? Settings["debugMode"] : 0

    ; -- Startup integration --
    setGui.Add("GroupBox", "xm y+12 w350 h68", "Windows Startup Integration")

    OnAddStartup(*) {
        AddToStartup()
        ShowToast("Added to Windows startup.")
    }
    OnRemoveStartup(*) {
        RemoveFromStartup()
        ShowToast("Removed from Windows startup.")
    }

    setGui.Add("Button", "xp+10 yp+22 w155", "Add to Startup").OnEvent("Click", OnAddStartup)
    setGui.Add("Button", "x+8 w155", "Remove from Startup").OnEvent("Click", OnRemoveStartup)

    ; -- Buttons --
    setGui.Add("Button", "xm y+14 Default w100", "Save").OnEvent("Click", OnSave)
    setGui.Add("Button", "x+8 w90", "Cancel").OnEvent("Click", (*) => setGui.Destroy())

    OnSave(*) {
        saved := setGui.Submit(false)
        Settings["autoRestore"]     := saved.AutoRestore
        Settings["restoreDelay"]    := saved.RestoreDelay != "" ? Integer(saved.RestoreDelay) : 10
        Settings["launchMissing"]   := saved.LaunchMissing
        Settings["autoSaveMinutes"] := saved.AutoSaveMinutes != "" ? Integer(saved.AutoSaveMinutes) : 15
        Settings["debugMode"]       := saved.DebugMode

        ; Resolve chosen startup layout
        chosen := ddl.Text
        Settings["startupLayout"] := (chosen == "(none)") ? "" : chosen

        ; Sync debug mode globally
        global DebugMode
        DebugMode := Settings["debugMode"]

        ; Update auto-save timer
        autoMin := Settings["autoSaveMinutes"]
        if autoMin > 0 {
            SetTimer(AutoSave, autoMin * 60000)
        } else {
            SetTimer(AutoSave, 0)
        }

        SaveSettings()
        setGui.Destroy()
        ShowToast("Settings saved.")
    }

    setGui.OnEvent("Close", (*) => setGui.Destroy())
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
