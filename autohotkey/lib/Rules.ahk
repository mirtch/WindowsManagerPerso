; =============================================================================
; Rules.ahk - Window placement rules engine
; Rules apply after restore, overriding layout positions for matched windows.
; =============================================================================

ApplyWindowRules(rules) {
    if !IsObject(rules) || rules.Length == 0
        return
    DetectHiddenWindows(false)
    hwnds := WinGetList()
    applied := 0
    for hwnd in hwnds {
        try {
            exe := StrLower(WinGetProcessName(hwnd))
            title := WinGetTitle(hwnd)
            for rule in rules {
                if _RuleMatches(rule, exe, title) {
                    _ApplyRule(hwnd, rule)
                    applied++
                    ruleName := rule.Has("name") ? rule["name"] : exe
                    DebugLog("Rule applied: " . ruleName . " -> " . exe)
                    break
                }
            }
        }
    }
    if applied > 0
        DebugLog("Applied " . applied . " window rules")
}

_RuleMatches(rule, exe, title) {
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
    ; Resolve the target monitor work area (falls back to current monitor if none specified)
    if rule.Has("monitor") && rule["monitor"] > 0 && rule["monitor"] <= MonitorGetCount() {
        area := GetMonitorWorkArea(rule["monitor"])
    } else {
        area := GetMonitorWorkArea(GetMonitorForWindow(hwnd))
    }

    if rule.Has("position") {
        x := area["left"]
        y := area["top"]
        w := area["w"]
        h := area["h"]
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
        try {
            if WinGetMinMax(hwnd) != 0
                WinRestore(hwnd)
            WinMove(x, y, w, h, hwnd)
        }
    }

    if rule.Has("state") {
        if rule["state"] == "maximized" {
            try WinMaximize(hwnd)
        } else if rule["state"] == "minimized" {
            try WinMinimize(hwnd)
        }
    }
}
