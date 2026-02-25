; =============================================================================
; Zones.ahk - FancyZones-style snap zone definitions and snapping
; =============================================================================

GetZonesForMonitor(monitorIndex, zoneConfig) {
    area := GetMonitorWorkArea(monitorIndex)
    zones := []
    if !IsObject(zoneConfig) || !zoneConfig.Has("type")
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

FindZoneForPoint(x, y, zones) {
    for i, zone in zones {
        if x >= zone["x"] && x < zone["x"] + zone["w"]
            && y >= zone["y"] && y < zone["y"] + zone["h"]
            return i
    }
    return 0
}

SnapToZone(hwnd, zone) {
    try {
        if WinGetMinMax(hwnd) != 0
            WinRestore(hwnd)
        WinMove(zone["x"], zone["y"], zone["w"], zone["h"], hwnd)
    }
}
