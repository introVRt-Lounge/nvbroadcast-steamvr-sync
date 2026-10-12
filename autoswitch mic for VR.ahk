#Requires AutoHotkey v2.0

global CONFIG_FILE := A_ScriptDir "\autoswitch mic for VR.ini"
global APP_CONFIG := LoadConfig()
; Modes: "virtualdesktop" | "steamvr" | "desktop"
; Do NOT treat VirtualDesktop.Streamer.exe / Service.exe as "active" - Streamer often idles in the tray.
global CURRENT_MODE := ""
global BROADCAST_UI_PATH := "C:\Program Files\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast UI.exe"
global BROADCAST_VERSION_OK := true
global TRAY_STATUS_ITEM := "Status: Starting..."
global FIRST_RUN := !FileExist(CONFIG_FILE)
if FIRST_RUN {
    SaveConfig(APP_CONFIG)
}

CheckNvidiaBroadcastVersion()
InitializeTrayMenu()
if FIRST_RUN {
    SetTimer(ShowFirstRunOnboarding, -600)
}

ResolveDeviceId(partialName, direction := "Render", requireActive := false) {
    svvPath := A_ScriptDir "\SoundVolumeView.exe"
    if !FileExist(svvPath) {
        return ""
    }

    escapedTerm := StrReplace(partialName, "'", "''")
    escapedSvvPath := StrReplace(svvPath, "'", "''")
    csvPath := A_Temp "\svv-devices.csv"
    escapedCsvPath := StrReplace(csvPath, "'", "''")
    escapedDirection := StrReplace(direction, "'", "''")
    activeFilter := requireActive ? " -and $_.'Device State' -eq 'Active'" : ""
    psCommand := "$svv = '" escapedSvvPath "'; " .
        "$csv = '" escapedCsvPath "'; " .
        "& $svv /scomma $csv /Columns 'Name,Device Name,Command-Line Friendly ID,Direction,Type,Device State'; " .
        "$rows = Import-Csv -Path $csv -ErrorAction SilentlyContinue; " .
        "$term = '" escapedTerm "'; " .
        "$dir = '" escapedDirection "'; " .
        "$match = $rows | Where-Object { " .
        "$normName = ($_.'Name' -replace '^\d+\s*-\s*',''); " .
        "$normDeviceName = ($_.'Device Name' -replace '^\d+\s*-\s*',''); " .
        "$normId = ($_.'Command-Line Friendly ID' -replace '^\d+\s*-\s*',''); " .
        "$_.'Type' -eq 'Device' -and $_.'Direction' -eq $dir" activeFilter " -and (" .
        "$_.'Name' -like ('*' + $term + '*') -or " .
        "$_.'Device Name' -like ('*' + $term + '*') -or " .
        "$_.'Command-Line Friendly ID' -like ('*' + $term + '*') -or " .
        "$normName -like ('*' + $term + '*') -or " .
        "$normDeviceName -like ('*' + $term + '*') -or " .
        "$normId -like ('*' + $term + '*')" .
        ") } | Sort-Object @{Expression={ if($_.'Device State' -eq 'Active'){0}else{1} }}, Name | Select-Object -First 1; " .
        "if ($match) { $match.'Command-Line Friendly ID' }"
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(Format('{} /c powershell -NoProfile -Command "{}"', A_ComSpec, psCommand))
    deviceId := Trim(exec.StdOut.ReadAll(), "`r`n`t ")
    return deviceId
}

ResolveDeviceIdFromAliases(aliases, direction := "Render", requireActive := false) {
    for _, alias in aliases {
        id := ResolveDeviceId(alias, direction, requireActive)
        if (id != "") {
            return id
        }
    }
    return ""
}

IsDeviceActiveByAliases(aliases, direction := "Render") {
    return ResolveDeviceIdFromAliases(aliases, direction, true) != ""
}

LoadConfig() {
    cfg := {}
    cfg.CaptureAliases := ParseAliasList(IniRead(CONFIG_FILE, "Devices", "CaptureAliases", "NVIDIA Broadcast|Broadcast"))
    cfg.VrRenderAliases := ParseAliasList(IniRead(CONFIG_FILE, "Devices", "VrRenderAliases", "Beyond|YondBe|Strap"))
    cfg.VdRenderAliases := ParseAliasList(IniRead(CONFIG_FILE, "Devices", "VdRenderAliases", "Virtual Desktop Audio|Virtual Desktop"))
    cfg.DesktopRenderAliases := ParseAliasList(IniRead(CONFIG_FILE, "Devices", "DesktopRenderAliases", "SteelSeries Arctis 1 Wireless|Arctis 1 Wireless|SteelSeries"))
    cfg.BroadcastVrMicSource := IniRead(CONFIG_FILE, "Broadcast", "VrMicSourceContains", "Beyond")
    cfg.BroadcastVdMicSource := IniRead(CONFIG_FILE, "Broadcast", "VdMicSourceContains", "Virtual Desktop")
    cfg.BroadcastDesktopMicSource := IniRead(CONFIG_FILE, "Broadcast", "DesktopMicSourceContains", "Jabra")
    return cfg
}

SaveConfig(cfg) {
    IniWrite(JoinAliasList(cfg.CaptureAliases), CONFIG_FILE, "Devices", "CaptureAliases")
    IniWrite(JoinAliasList(cfg.VrRenderAliases), CONFIG_FILE, "Devices", "VrRenderAliases")
    IniWrite(JoinAliasList(cfg.VdRenderAliases), CONFIG_FILE, "Devices", "VdRenderAliases")
    IniWrite(JoinAliasList(cfg.DesktopRenderAliases), CONFIG_FILE, "Devices", "DesktopRenderAliases")
    IniWrite(cfg.BroadcastVrMicSource, CONFIG_FILE, "Broadcast", "VrMicSourceContains")
    IniWrite(cfg.BroadcastVdMicSource, CONFIG_FILE, "Broadcast", "VdMicSourceContains")
    IniWrite(cfg.BroadcastDesktopMicSource, CONFIG_FILE, "Broadcast", "DesktopMicSourceContains")
}

ParseAliasList(value) {
    aliases := []
    for _, token in StrSplit(value, "|") {
        item := Trim(token)
        if (item != "") {
            aliases.Push(item)
        }
    }
    if (aliases.Length = 0) {
        aliases.Push(value)
    }
    return aliases
}

JoinAliasList(aliases) {
    output := ""
    for index, alias in aliases {
        if (index > 1) {
            output .= "|"
        }
        output .= alias
    }
    return output
}

BuildUniqueDeviceList(direction := "Render") {
    svvPath := A_ScriptDir "\SoundVolumeView.exe"
    if !FileExist(svvPath) {
        return []
    }
    csvPath := A_Temp "\svv-ui-devices.csv"
    try {
        RunWait(Format('"{}" /scomma "{}" /Columns "{}"', svvPath, csvPath, "Name,Device Name,Direction,Type"),, "Hide")
        rows := FileRead(csvPath)
    } catch Error as err {
        return []
    }
    devices := Map()
    for _, line in StrSplit(rows, "`n", "`r") {
        if (line = "" || InStr(line, "Name,Device Name,Direction,Type") = 1) {
            continue
        }
        cols := StrSplit(line, ",")
        if (cols.Length < 4) {
            continue
        }
        itemName := Trim(cols[1], '"')
        deviceName := Trim(cols[2], '"')
        itemDirection := Trim(cols[3], '"')
        itemType := Trim(cols[4], '"')
        if (itemType = "Device" && itemDirection = direction && deviceName != "") {
            devices[deviceName] := true
        } else if (itemType = "Device" && itemDirection = direction && itemName != "") {
            devices[itemName] := true
        }
    }
    list := []
    for name, _ in devices {
        list.Push(name)
    }
    return list
}

InitializeTrayMenu() {
    global TRAY_STATUS_ITEM
    A_TrayMenu.Add(TRAY_STATUS_ITEM, TrayStatusNoop)
    A_TrayMenu.Disable(TRAY_STATUS_ITEM)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Configure VR Audio Targets...", ShowConfigGui)
    A_TrayMenu.Add()
    UpdateTrayForMode(DetectAudioMode(), true)
}

TrayStatusNoop(*) {
    ; Intentionally empty: status line is informational only.
}

ShowFirstRunOnboarding() {
    global FIRST_RUN
    if !FIRST_RUN {
        return
    }
    ShowConfigGui()
}

; Active headset session, not "Streamer.exe exists".
; Primary signal: Virtual Desktop Audio Render endpoint is Active in SoundVolumeView.
; (Capture stays Active while Streamer idles; Render does not.)
; Fallback: Streamer has ESTABLISHED TCP to a private/LAN peer on VD ports (excludes cloud signaling).
IsVirtualDesktopSessionActive() {
    global APP_CONFIG
    svvPath := A_ScriptDir "\SoundVolumeView.exe"
    if FileExist(svvPath) {
        if IsDeviceActiveByAliases(APP_CONFIG.VdRenderAliases, "Render") {
            return true
        }
        ; If SVV is present, trust it over process/port heuristics when Render is inactive.
        return false
    }
    return HasVirtualDesktopLanSession()
}

HasVirtualDesktopLanSession() {
    psCommand :=
    (
        "$p = Get-Process -Name 'VirtualDesktop.Streamer' -ErrorAction SilentlyContinue | Select-Object -First 1;"
        "if (-not $p) { '0'; exit };"
        "$hits = Get-NetTCPConnection -OwningProcess $p.Id -State Established -ErrorAction SilentlyContinue |"
        " Where-Object {"
        "  $_.LocalPort -in 38810,38820,38830,38840 -and"
        "  $_.RemoteAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|::1|fc|fd|fe80)'"
        " };"
        "if ($hits) { '1' } else { '0' }"
    )
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(Format('{} /c powershell -NoProfile -Command "{}"', A_ComSpec, psCommand))
    return Trim(exec.StdOut.ReadAll(), "`r`n`t ") = "1"
}

DetectAudioMode() {
    if IsVirtualDesktopSessionActive() {
        return "virtualdesktop"
    }
    if ProcessExist("vrmonitor.exe") {
        return "steamvr"
    }
    return "desktop"
}

UpdateTrayForMode(mode, force := false) {
    global CURRENT_MODE, TRAY_STATUS_ITEM, BROADCAST_VERSION_OK
    if (!force && mode = CURRENT_MODE) {
        return
    }
    oldLabel := TRAY_STATUS_ITEM
    if (!BROADCAST_VERSION_OK) {
        TRAY_STATUS_ITEM := "Status: Unsupported NVIDIA Broadcast version"
        A_IconTip := "VR Audio Auto-Switch - UNSUPPORTED: requires NVIDIA Broadcast 1.4.x"
    } else if (mode = "virtualdesktop") {
        TRAY_STATUS_ITEM := "Status: Virtual Desktop (active session)"
        A_IconTip := "VR Audio Auto-Switch - Virtual Desktop session active"
    } else if (mode = "steamvr") {
        TRAY_STATUS_ITEM := "Status: SteamVR (Beyond)"
        A_IconTip := "VR Audio Auto-Switch - SteamVR / Beyond"
    } else {
        TRAY_STATUS_ITEM := "Status: Desktop (Jabra)"
        A_IconTip := "VR Audio Auto-Switch - Desktop / Jabra"
    }
    try {
        A_TrayMenu.Rename(oldLabel, TRAY_STATUS_ITEM)
        A_TrayMenu.Disable(TRAY_STATUS_ITEM)
    }
    CURRENT_MODE := mode
}

CheckNvidiaBroadcastVersion() {
    global BROADCAST_UI_PATH, BROADCAST_VERSION_OK
    version := GetInstalledNvidiaBroadcastVersion()
    if (version = "") {
        version := GetBroadcastProductVersionFromFile(BROADCAST_UI_PATH)
    }
    if !FileExist(BROADCAST_UI_PATH) {
        BROADCAST_VERSION_OK := false
        MsgBox "NVIDIA Broadcast UI executable was not found at:`n" BROADCAST_UI_PATH "`n`nThis tool requires NVIDIA Broadcast 1.4.x.", "NVIDIA Broadcast Requirement"
        return false
    }

    if !IsBroadcastVersionSupported(version) {
        BROADCAST_VERSION_OK := false
        MsgBox "Detected NVIDIA Broadcast version: " version "`n`nThis V2 tool currently supports NVIDIA Broadcast 1.4.x only.`nIf you need 2.1.0+, you are out of luck - this technique does not work with it.", "Unsupported NVIDIA Broadcast Version"
        return false
    }

    BROADCAST_VERSION_OK := true
    return true
}

IsBroadcastVersionSupported(version) {
    return (SubStr(version, 1, 4) = "1.4.")
}

GetInstalledNvidiaBroadcastVersion() {
    psCommand := "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | " .
        "Where-Object { $_.DisplayName -like 'NVIDIA Broadcast *' -and $_.DisplayVersion } | " .
        "Sort-Object DisplayVersion -Descending | Select-Object -First 1 -ExpandProperty DisplayVersion)"
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(Format('{} /c powershell -NoProfile -Command "{}"', A_ComSpec, psCommand))
    return Trim(exec.StdOut.ReadAll(), "`r`n`t ")
}

GetBroadcastProductVersionFromFile(filePath) {
    if !FileExist(filePath) {
        return ""
    }
    escapedPath := StrReplace(filePath, "'", "''")
    psCommand := "$v=[System.Diagnostics.FileVersionInfo]::GetVersionInfo('" escapedPath "'); $v.ProductVersion"
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(Format('{} /c powershell -NoProfile -Command "{}"', A_ComSpec, psCommand))
    return Trim(exec.StdOut.ReadAll(), "`r`n`t ")
}

ShowConfigGui(*) {
    global APP_CONFIG, BROADCAST_VERSION_OK, FIRST_RUN
    renderDevices := BuildUniqueDeviceList("Render")
    captureDevices := BuildUniqueDeviceList("Capture")
    showOnboarding := FIRST_RUN
    if showOnboarding {
        FIRST_RUN := false
    }

    cfgGui := Gui("+AlwaysOnTop", "VR Audio Config")
    cfgGui.SetFont("s10", "Segoe UI")
    cfgGui.AddText("w1180", "Three profiles: SteamVR/Beyond, active Virtual Desktop session, and desktop. Advanced alias tuning is behind 'Advanced...'.")
    if showOnboarding {
        cfgGui.SetFont("s10 cBlue Bold", "Segoe UI")
        cfgGui.AddText("w1180 y+8", "First run setup: choose SteamVR / Virtual Desktop / Desktop targets, then click Save.")
        cfgGui.SetFont("s10 cDefault Norm", "Segoe UI")
    }
    if !BROADCAST_VERSION_OK {
        cfgGui.SetFont("s10 cRed Bold", "Segoe UI")
        cfgGui.AddText("w1180 y+8", "NOT ACTIVE: This tool requires NVIDIA Broadcast 1.4.x. If you need 2.1.0+, this technique will not work.")
        cfgGui.SetFont("s10 cDefault Norm", "Segoe UI")
    }
    if IsVirtualDesktopSessionActive() {
        cfgGui.SetFont("s10 cGreen Bold", "Segoe UI")
        cfgGui.AddText("w1180 y+8", "Virtual Desktop session is ACTIVE right now - Broadcast will use the Virtual Desktop mic profile.")
        cfgGui.SetFont("s10 cDefault Norm", "Segoe UI")
    }

    colW := 370
    gap := 20
    leftX := 20
    midX := leftX + colW + gap
    rightX := midX + colW + gap
    topY := 44
    groupY := topY + 40
    groupH := 210

    cfgGui.SetFont("s16", "Segoe UI Emoji")
    cfgGui.AddText(Format("x{} y{} w{} Center", leftX, topY, colW), "🥽 SteamVR / Beyond")
    cfgGui.AddText(Format("x{} y{} w{} Center", midX, topY, colW), "🖥️ Virtual Desktop")
    cfgGui.AddText(Format("x{} y{} w{} Center", rightX, topY, colW), "🎧 Desktop")

    cfgGui.SetFont("s10", "Segoe UI")
    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", leftX, groupY, colW, groupH), "")
    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", midX, groupY, colW, groupH), "")
    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", rightX, groupY, colW, groupH), "")

    cfgGui.AddText(Format("x{} y{} w{}", leftX + 14, groupY + 28, colW - 28), "Input (mic source in NVIDIA Broadcast)")
    vrInputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", leftX + 14, groupY + 50, colW - 28), captureDevices)
    cfgGui.AddText(Format("x{} y{} w{}", leftX + 14, groupY + 92, colW - 28), "Output (Windows default + comms)")
    vrOutputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", leftX + 14, groupY + 114, colW - 28), renderDevices)

    cfgGui.AddText(Format("x{} y{} w{}", midX + 14, groupY + 28, colW - 28), "Input (mic source in NVIDIA Broadcast)")
    vdInputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", midX + 14, groupY + 50, colW - 28), captureDevices)
    cfgGui.AddText(Format("x{} y{} w{}", midX + 14, groupY + 92, colW - 28), "Output (Windows default + comms)")
    vdOutputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", midX + 14, groupY + 114, colW - 28), renderDevices)

    cfgGui.AddText(Format("x{} y{} w{}", rightX + 14, groupY + 28, colW - 28), "Input (mic source in NVIDIA Broadcast)")
    desktopInputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", rightX + 14, groupY + 50, colW - 28), captureDevices)
    cfgGui.AddText(Format("x{} y{} w{}", rightX + 14, groupY + 92, colW - 28), "Output (Windows default + comms)")
    desktopOutputPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", rightX + 14, groupY + 114, colW - 28), renderDevices)

    SetDropDownSelectionByContains(vrInputPick, captureDevices, APP_CONFIG.BroadcastVrMicSource)
    SetDropDownSelectionByAliases(vrOutputPick, renderDevices, APP_CONFIG.VrRenderAliases)
    SetDropDownSelectionByContains(vdInputPick, captureDevices, APP_CONFIG.BroadcastVdMicSource)
    SetDropDownSelectionByAliases(vdOutputPick, renderDevices, APP_CONFIG.VdRenderAliases)
    SetDropDownSelectionByContains(desktopInputPick, captureDevices, APP_CONFIG.BroadcastDesktopMicSource)
    SetDropDownSelectionByAliases(desktopOutputPick, renderDevices, APP_CONFIG.DesktopRenderAliases)

    buttonY := groupY + groupH + 14
    saveBtn := cfgGui.AddButton(Format("x{} y{} w120 h32", leftX, buttonY), "Save")
    advancedBtn := cfgGui.AddButton(Format("x{} y{} w140 h32", leftX + 132, buttonY), "Advanced...")
    cancelBtn := cfgGui.AddButton(Format("x{} y{} w120 h32", leftX + 284, buttonY), "Cancel")

    saveBtn.OnEvent("Click", (*) => SaveSimpleConfigFromGui(cfgGui, vrInputPick, vrOutputPick, vdInputPick, vdOutputPick, desktopInputPick, desktopOutputPick))
    advancedBtn.OnEvent("Click", (*) => ShowAdvancedConfigGui())
    cancelBtn.OnEvent("Click", (*) => cfgGui.Destroy())
    cfgGui.Show("AutoSize Center")
}

ShowAdvancedConfigGui(*) {
    global APP_CONFIG, BROADCAST_VERSION_OK
    renderDevices := BuildUniqueDeviceList("Render")
    captureDevices := BuildUniqueDeviceList("Capture")
    broadcastCaptureDevices := FilterDeviceList(captureDevices, "Broadcast")
    if (broadcastCaptureDevices.Length = 0) {
        broadcastCaptureDevices := ["NVIDIA Broadcast"]
    }
    vdActive := IsVirtualDesktopSessionActive()

    cfgGui := Gui("+AlwaysOnTop", "VR Audio Config - Advanced")
    cfgGui.SetFont("s10", "Segoe UI")
    cfgGui.AddText("w780", "Power-user mode. Keep fallback aliases with |. Profiles: SteamVR, active Virtual Desktop, Desktop.")
    if !BROADCAST_VERSION_OK {
        cfgGui.SetFont("s10 cRed Bold", "Segoe UI")
        cfgGui.AddText("w780 y+8", "NOT ACTIVE: This tool requires NVIDIA Broadcast 1.4.x. If you need 2.1.0+, this technique will not work.")
        cfgGui.SetFont("s10 cDefault Norm", "Segoe UI")
    }
    if (vdActive) {
        cfgGui.SetFont("s10 cGreen Bold", "Segoe UI")
        cfgGui.AddText("w780 y+8", "Virtual Desktop session is ACTIVE - Render endpoint 'Virtual Desktop Audio' is present.")
        cfgGui.SetFont("s10 cDefault Norm", "Segoe UI")
    }
    x := 18, w := 780
    contentOffset := vdActive ? 30 : 0
    sharedY := 58 + contentOffset
    sharedH := 132
    vrY := sharedY + sharedH + 10
    vrH := 184
    vdY := vrY + vrH + 10
    vdH := 184
    desktopY := vdY + vdH + 10
    desktopH := 184
    buttonY := desktopY + desktopH + 12

    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", x, sharedY, w, sharedH), "Shared Input - NVIDIA Broadcast")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, sharedY + 24, w - 24), "To ensure this tool works with NVIDIA Broadcast as expected, leave this as NVIDIA Broadcast.")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, sharedY + 46, w - 24), "Windows microphone aliases:")
    captureEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, sharedY + 68, w - 24), JoinAliasList(APP_CONFIG.CaptureAliases))
    capturePick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, sharedY + 96, 580), broadcastCaptureDevices)
    captureUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, sharedY + 96, 166), "Use Picked Broadcast")

    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", x, vrY, w, vrH), "SteamVR / Beyond")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, vrY + 24, w - 24), "Output aliases:")
    vrRenderEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, vrY + 46, w - 24), JoinAliasList(APP_CONFIG.VrRenderAliases))
    vrRenderPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, vrY + 74, 580), renderDevices)
    vrRenderUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, vrY + 74, 166), "Use Picked Device")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, vrY + 108, w - 24), "Input while in SteamVR (NVIDIA Broadcast mic source):")
    vrMicSourceEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, vrY + 130, w - 24), APP_CONFIG.BroadcastVrMicSource)
    vrMicSourcePick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, vrY + 158, 580), captureDevices)
    vrMicSourceUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, vrY + 158, 166), "Use Picked Device")

    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", x, vdY, w, vdH), "Virtual Desktop (active session)")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, vdY + 24, w - 24), "Output aliases (also used to detect an active VD session when Active):")
    vdRenderEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, vdY + 46, w - 24), JoinAliasList(APP_CONFIG.VdRenderAliases))
    vdRenderPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, vdY + 74, 580), renderDevices)
    vdRenderUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, vdY + 74, 166), "Use Picked Device")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, vdY + 108, w - 24), "Input while VD session is active (NVIDIA Broadcast mic source):")
    vdMicSourceEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, vdY + 130, w - 24), APP_CONFIG.BroadcastVdMicSource)
    vdMicSourcePick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, vdY + 158, 580), captureDevices)
    vdMicSourceUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, vdY + 158, 166), "Use Picked Device")

    cfgGui.AddGroupBox(Format("x{} y{} w{} h{}", x, desktopY, w, desktopH), "On Desktop")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, desktopY + 24, w - 24), "Output aliases:")
    desktopRenderEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, desktopY + 46, w - 24), JoinAliasList(APP_CONFIG.DesktopRenderAliases))
    desktopRenderPick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, desktopY + 74, 580), renderDevices)
    desktopRenderUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, desktopY + 74, 166), "Use Picked Device")
    cfgGui.AddText(Format("x{} y{} w{}", x + 12, desktopY + 108, w - 24), "Input on desktop (NVIDIA Broadcast mic source, default Jabra):")
    desktopMicSourceEdit := cfgGui.AddEdit(Format("x{} y{} w{}", x + 12, desktopY + 130, w - 24), APP_CONFIG.BroadcastDesktopMicSource)
    desktopMicSourcePick := cfgGui.AddDropDownList(Format("x{} y{} w{}", x + 12, desktopY + 158, 580), captureDevices)
    desktopMicSourceUseBtn := cfgGui.AddButton(Format("x{} y{} w{}", x + 602, desktopY + 158, 166), "Use Picked Device")

    SetDropDownSelectionByAliases(capturePick, broadcastCaptureDevices, APP_CONFIG.CaptureAliases)
    SetDropDownSelectionByAliases(vrRenderPick, renderDevices, APP_CONFIG.VrRenderAliases)
    SetDropDownSelectionByContains(vrMicSourcePick, captureDevices, APP_CONFIG.BroadcastVrMicSource)
    SetDropDownSelectionByAliases(vdRenderPick, renderDevices, APP_CONFIG.VdRenderAliases)
    SetDropDownSelectionByContains(vdMicSourcePick, captureDevices, APP_CONFIG.BroadcastVdMicSource)
    SetDropDownSelectionByAliases(desktopRenderPick, renderDevices, APP_CONFIG.DesktopRenderAliases)
    SetDropDownSelectionByContains(desktopMicSourcePick, captureDevices, APP_CONFIG.BroadcastDesktopMicSource)

    saveBtn := cfgGui.AddButton(Format("x{} y{} w120 h32", x, buttonY), "Save")
    cancelBtn := cfgGui.AddButton(Format("x{} y{} w120 h32", x + 132, buttonY), "Cancel")

    captureUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(captureEdit, capturePick))
    vrRenderUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(vrRenderEdit, vrRenderPick))
    vdRenderUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(vdRenderEdit, vdRenderPick))
    desktopRenderUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(desktopRenderEdit, desktopRenderPick))
    vrMicSourceUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(vrMicSourceEdit, vrMicSourcePick))
    vdMicSourceUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(vdMicSourceEdit, vdMicSourcePick))
    desktopMicSourceUseBtn.OnEvent("Click", (*) => ApplyDropdownSelection(desktopMicSourceEdit, desktopMicSourcePick))
    saveBtn.OnEvent("Click", (*) => SaveConfigFromGui(cfgGui, captureEdit, vrRenderEdit, vdRenderEdit, desktopRenderEdit, vrMicSourceEdit, vdMicSourceEdit, desktopMicSourceEdit))
    cancelBtn.OnEvent("Click", (*) => cfgGui.Destroy())
    cfgGui.Show("AutoSize Center")
}

FilterDeviceList(items, containsText) {
    filtered := []
    for _, item in items {
        if InStr(item, containsText) {
            filtered.Push(item)
        }
    }
    return filtered
}

NormalizeDeviceLabel(name) {
    trimmed := Trim(name)
    if (trimmed = "") {
        return trimmed
    }
    return RegExReplace(trimmed, "^\d+\s*-\s*")
}

SetDropDownSelectionByContains(dropdown, items, needle) {
    match := Trim(needle)
    if (match = "") {
        return
    }
    for _, item in items {
        if InStr(item, match) {
            dropdown.Text := item
            return
        }
    }
}

SetDropDownSelectionByAliases(dropdown, items, aliases) {
    for _, alias in aliases {
        for _, item in items {
            if InStr(item, alias) {
                dropdown.Text := item
                return
            }
        }
    }
}

SaveSimpleConfigFromGui(cfgGui, vrInputPick, vrOutputPick, vdInputPick, vdOutputPick, desktopInputPick, desktopOutputPick) {
    global APP_CONFIG
    vrInput := NormalizeDeviceLabel(vrInputPick.Text)
    vrOutput := NormalizeDeviceLabel(vrOutputPick.Text)
    vdInput := NormalizeDeviceLabel(vdInputPick.Text)
    vdOutput := NormalizeDeviceLabel(vdOutputPick.Text)
    desktopInput := NormalizeDeviceLabel(desktopInputPick.Text)
    desktopOutput := NormalizeDeviceLabel(desktopOutputPick.Text)

    if (vrInput = "" || vrOutput = "" || vdInput = "" || vdOutput = "" || desktopInput = "" || desktopOutput = "") {
        MsgBox "Please select all six devices before saving."
        return
    }

    APP_CONFIG.BroadcastVrMicSource := vrInput
    APP_CONFIG.VrRenderAliases := [vrOutput]
    APP_CONFIG.BroadcastVdMicSource := vdInput
    APP_CONFIG.VdRenderAliases := [vdOutput]
    APP_CONFIG.BroadcastDesktopMicSource := desktopInput
    APP_CONFIG.DesktopRenderAliases := [desktopOutput]

    SaveConfig(APP_CONFIG)
    cfgGui.Destroy()
    MsgBox "Saved simple config to:`n" CONFIG_FILE
}

ApplyDropdownSelection(targetEdit, sourceDropdown) {
    selected := Trim(sourceDropdown.Text)
    if (selected != "") {
        targetEdit.Value := selected
    }
}

SaveConfigFromGui(cfgGui, captureEdit, vrRenderEdit, vdRenderEdit, desktopRenderEdit, vrMicSourceEdit, vdMicSourceEdit, desktopMicSourceEdit) {
    global APP_CONFIG
    APP_CONFIG.CaptureAliases := ParseAliasList(captureEdit.Value)
    APP_CONFIG.VrRenderAliases := ParseAliasList(vrRenderEdit.Value)
    APP_CONFIG.VdRenderAliases := ParseAliasList(vdRenderEdit.Value)
    APP_CONFIG.DesktopRenderAliases := ParseAliasList(desktopRenderEdit.Value)
    APP_CONFIG.BroadcastVrMicSource := Trim(vrMicSourceEdit.Value)
    APP_CONFIG.BroadcastVdMicSource := Trim(vdMicSourceEdit.Value)
    APP_CONFIG.BroadcastDesktopMicSource := Trim(desktopMicSourceEdit.Value)
    SaveConfig(APP_CONFIG)
    cfgGui.Destroy()
    MsgBox "Saved config to:`n" CONFIG_FILE
}

ResolveAudioDeviceName(partialName) {
    escaped := StrReplace(partialName, "'", "''")
    psCommand := "$term = '" escaped "'; " .
        "(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render' -ErrorAction SilentlyContinue | " .
        "ForEach-Object { " .
        "$props = Get-ItemProperty -Path ($_.PSPath + '\Properties') -ErrorAction SilentlyContinue; " .
        "$name = $props.'{b3f8fa53-0004-438e-9003-51a46e139bfc},14'; " .
        "if (-not $name) { $name = $props.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' }; " .
        "if (-not $name) { $name = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' }; " .
        "$name " .
        "}) | Where-Object { $_ -and $_ -like ('*' + $term + '*') } | Sort-Object -Unique | Select-Object -First 1"
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(Format('{} /c powershell -NoProfile -Command "{}"', A_ComSpec, psCommand))
    deviceName := Trim(exec.StdOut.ReadAll(), "`r`n`t ")
    return deviceName
}

ResolveAudioDeviceNameFromAliases(aliases) {
    for _, alias in aliases {
        name := ResolveAudioDeviceName(alias)
        if (name != "") {
            return name
        }
    }
    return ""
}

SetDefaultAudioDeviceBySoundVolumeView(deviceId, setAsComms := false) {
    svvPath := A_ScriptDir "\SoundVolumeView.exe"
    if !FileExist(svvPath) {
        return false
    }
    try {
        RunWait(Format('"{}" /SetDefault "{}" 1', svvPath, deviceId),, "Hide")
        Sleep(300)
        if (setAsComms) {
            RunWait(Format('"{}" /SetDefault "{}" 2', svvPath, deviceId),, "Hide")
            Sleep(300)
        }
        return true
    } catch Error as err {
        return false
    }
}

; Function to set both default playback and communications devices
SetDefaultAudioDevice(deviceNameOrPartial, setAsComms := false, usePartialMatch := false, direction := "Render") {
    svvPath := A_ScriptDir "\SoundVolumeView.exe"
    nircmdPath := A_ScriptDir "\nircmd.exe"

    if !FileExist(svvPath) && !FileExist(nircmdPath) {
        MsgBox "No supported audio tool found. Expected SoundVolumeView.exe or nircmd.exe in: " A_ScriptDir
        return
    }

    deviceName := deviceNameOrPartial
    deviceId := ""
    if (usePartialMatch) {
        isArray := (Type(deviceNameOrPartial) = "Array")
        if (FileExist(svvPath)) {
            if (isArray) {
                deviceId := ResolveDeviceIdFromAliases(deviceNameOrPartial, direction)
            } else {
                deviceId := ResolveDeviceId(deviceNameOrPartial, direction)
            }
        }
        if (isArray) {
            resolvedName := ResolveAudioDeviceNameFromAliases(deviceNameOrPartial)
            missingName := ""
            for index, alias in deviceNameOrPartial {
                if (index > 1) {
                    missingName .= ", "
                }
                missingName .= alias
            }
        } else {
            resolvedName := ResolveAudioDeviceName(deviceNameOrPartial)
            missingName := deviceNameOrPartial
        }
        if (deviceId = "" && resolvedName = "") {
            ; Soft-fail for mode switches (device may be unplugged / session ended).
            return
        }
        deviceName := resolvedName
    }

    if (deviceId != "") {
        if SetDefaultAudioDeviceBySoundVolumeView(deviceId, setAsComms) {
            return
        }
    }

    try {
        if !FileExist(nircmdPath) {
            return
        }
        RunWait(Format('"{}" setdefaultsounddevice "{}" 1', nircmdPath, deviceName),, "Hide")
        Sleep(500)

        if (setAsComms) {
            RunWait(Format('"{}" setdefaultsounddevice "{}" 1 2', nircmdPath, deviceName),, "Hide")
            Sleep(500)
        }
    } catch Error as err {
    }
}

SetBroadcastMicSource(partialText) {
    if (Trim(partialText) = "") {
        return false
    }
    if !WinExist("ahk_class RTXVoiceWindowClass") {
        return false
    }
    WinActivate("ahk_class RTXVoiceWindowClass")
    ControlClick("Button4", "ahk_class RTXVoiceWindowClass") ; Microphone tab
    Sleep(500)
    ControlFocus("ComboBox6", "ahk_class RTXVoiceWindowClass")
    ControlClick("ComboBox6", "ahk_class RTXVoiceWindowClass")
    Sleep(150)
    ok := SelectComboItemContains("ComboBox6", "ahk_class RTXVoiceWindowClass", partialText)
    CloseNvidiaBroadcastWindow()
    return ok
}

ApplyAudioProfile(mode) {
    global APP_CONFIG, BROADCAST_VERSION_OK
    if !BROADCAST_VERSION_OK {
        return
    }

    ; Keep Windows default capture on NVIDIA Broadcast in every mode.
    SetDefaultAudioDevice(APP_CONFIG.CaptureAliases, true, true, "Capture")
    Sleep(500)

    if (mode = "virtualdesktop") {
        SetDefaultAudioDevice(APP_CONFIG.VdRenderAliases, true, true, "Render")
        Sleep(1000)
        SetBroadcastMicSource(APP_CONFIG.BroadcastVdMicSource)
        return
    }

    if (mode = "steamvr") {
        SetDefaultAudioDevice(APP_CONFIG.VrRenderAliases, true, true, "Render")
        Sleep(1000)
        SetBroadcastMicSource(APP_CONFIG.BroadcastVrMicSource)
        return
    }

    ; Desktop / default
    SetBroadcastMicSource(APP_CONFIG.BroadcastDesktopMicSource)
    Sleep(1000)
    SetDefaultAudioDevice(APP_CONFIG.DesktopRenderAliases, true, true, "Render")
}

RestartNvidiaBroadcast() {
    ; Disabled by request: do not kill/restart NVIDIA Broadcast automatically.
}

CloseNvidiaBroadcastWindow() {
    if WinExist("ahk_class RTXVoiceWindowClass") {
        WinActivate("ahk_class RTXVoiceWindowClass")
        Sleep(500)
        WinClose("ahk_class RTXVoiceWindowClass")
        Sleep(1000)
        if WinExist("ahk_class RTXVoiceWindowClass") {
            WinClose("ahk_class RTXVoiceWindowClass")
        }
    }
}

SelectComboItemContains(controlName, windowTitle, partialText) {
    try {
        items := ControlGetItems(controlName, windowTitle)
        for index, item in items {
            if InStr(item, partialText) {
                ControlChooseIndex(index, controlName, windowTitle)
                return true
            }
        }
    } catch Error as err {
    }
    return false
}

SetTitleMatchMode(2)
DetectHiddenWindows(true)

; Poll for active Virtual Desktop session and/or SteamVR; apply the matching audio profile.
MonitorAudioModes() {
    static lastMode := ""
    Loop {
        mode := DetectAudioMode()
        if (mode != lastMode) {
            ; Brief settle when leaving VR so devices finish disconnecting.
            if (lastMode = "steamvr" || lastMode = "virtualdesktop") {
                Sleep(1500)
                mode := DetectAudioMode()
            }
            ApplyAudioProfile(mode)
            UpdateTrayForMode(mode, true)
            lastMode := mode
        } else {
            UpdateTrayForMode(mode)
        }
        Sleep(1000)
    }
}

MonitorAudioModes()
