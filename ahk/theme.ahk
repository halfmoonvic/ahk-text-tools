ReadWindowsAppTheme() {
    return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0 ? "dark" : "light"
}

ResolveTextToolTheme(mode) {
    global TextToolThemeReader
    if mode != "auto"
        return mode
    ; RegRead throws when the value is missing, which is the default on a fresh profile.
    try return TextToolThemeReader() = "dark" ? "dark" : "light"
    catch
        return "light"
}

TextToolPalette(theme) {
    return theme = "dark"
        ? {Background: "202020", Surface: "2B2B2B", Text: "F0F0F0", Muted: "B0B0B0", Error: "FF8080"}
        : {Background: "F3F3F3", Surface: "FFFFFF", Text: "202020", Muted: "666666", Error: "B00020"}
}

TextToolColorRef(rgb) {
    value := Integer("0x" rgb)
    return ((value & 255) << 16) | (value & 0xFF00) | ((value >> 16) & 255)
}

RegisterTextToolTheme(window) {
    global TextToolThemeWindows
    ApplyTextToolTheme(window, ResolveTextToolTheme(window.Ui.Theme))
    TextToolThemeWindows[window.Hwnd] := window
}

TextToolThemeChanged(*) {
    ; Coalesce the notifications sent to each top-level window.
    SetTimer(RefreshTextToolThemes, -50)
}

RefreshTextToolThemes() {
    global TextToolThemeWindows
    theme := ResolveTextToolTheme("auto")
    for hwnd, window in TextToolThemeWindows {
        if window.Ui.Theme = "auto" && window.AppliedTheme != theme
            ApplyTextToolTheme(window, theme)
    }
}

ApplyTextToolTheme(window, theme) {
    colors := TextToolPalette(theme)
    ApplyTextToolNativeTheme(window.Hwnd, theme)
    window.Gui.BackColor := colors.Background
    if window.HasOwnProp("StaticEdit") {
        ApplyTextToolNativeTheme(window.StaticEdit.Hwnd, theme, "CFD")
        window.StaticEdit.Opt("Background" colors.Surface " c" colors.Text)
    } else {
        ApplyTextToolNativeTheme(window.View.Hwnd, theme)
        window.View.BackColor := colors.Background
        if window.HasOwnProp("Search") {
            ApplyTextToolNativeTheme(window.Search.Hwnd, theme, "CFD")
            ApplyTextToolNativeTheme(window.Submit.Hwnd, theme)
            window.Search.Opt("Background" colors.Surface " c" colors.Text)
            window.SearchBackground.Opt("Background" colors.Surface)
            window.Hint.SetFont("c" colors.Muted)
        }
        for task in window.Tasks {
            ApplyTextToolNativeTheme(task.Copy.Hwnd, theme)
            task.Label.SetFont("c" colors.Text)
            task.Status.SetFont("c" colors.Muted)
            SetRichEditTheme(task.Edit, colors.Surface, colors.Text)
            SetRichEditTheme(task.ErrorEdit, colors.Surface, colors.Error)
        }
    }
    dark := Buffer(4, 0)
    NumPut("int", theme = "dark", dark)
    ; DWMWA_USE_IMMERSIVE_DARK_MODE (20); unsupported systems keep their title bar.
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", window.Hwnd, "uint", 20, "ptr", dark, "uint", 4)
    window.AppliedTheme := theme
    DllCall("RedrawWindow", "ptr", window.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x185)
}

DrawTextToolButton(wParam, lParam, *) {
    global TextToolBatches
    if NumGet(lParam, A_PtrSize * 2, "int") != -12 ; NM_CUSTOMDRAW
        return
    headerSize := A_PtrSize = 8 ? 24 : 12
    if NumGet(lParam, headerSize, "uint") != 1 ; CDDS_PREPAINT
        return
    hwnd := NumGet(lParam, 0, "ptr")
    root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
    if !TextToolBatches.Has(root)
        return
    window := TextToolBatches[root]
    control := 0
    if window.HasOwnProp("Submit") && window.Submit.Hwnd = hwnd
        control := window.Submit
    else {
        for task in window.Tasks {
            if task.Copy.Hwnd = hwnd {
                control := task.Copy
                break
            }
        }
    }
    if !control || !window.HasOwnProp("AppliedTheme")
        return
    dark := window.AppliedTheme = "dark"
    colors := TextToolPalette(window.AppliedTheme)
    dc := NumGet(lParam, headerSize + A_PtrSize, "ptr")
    rect := lParam + headerSize + 2 * A_PtrSize
    state := NumGet(lParam, headerSize + 3 * A_PtrSize + 16, "uint")
    background := state & 1 ? (dark ? "484848" : "D0D0D0")
        : state & 0x50 ? (dark ? "404040" : "E0E0E0") ; hot or keyboard focus
        : (dark ? "303030" : "EAEAEA")
    brush := DllCall("CreateSolidBrush", "uint", TextToolColorRef(background), "ptr")
    saved := DllCall("SaveDC", "ptr", dc, "int")
    try {
        DllCall("FillRect", "ptr", dc, "ptr", rect, "ptr", brush)
        font := SendMessage(0x31, 0, 0, hwnd)
        if font
            DllCall("SelectObject", "ptr", dc, "ptr", font, "ptr")
        DllCall("SetBkMode", "ptr", dc, "int", 1)
        DllCall("SetTextColor", "ptr", dc, "uint", TextToolColorRef(state & 4 ? colors.Muted : colors.Text))
        DllCall("DrawTextW", "ptr", dc, "str", control.Text, "int", -1,
            "ptr", rect, "uint", 0x825) ; centered, single line, no mnemonic prefix
    } finally {
        DllCall("RestoreDC", "ptr", dc, "int", saved)
        DllCall("DeleteObject", "ptr", brush)
    }
    return 4 ; CDRF_SKIPDEFAULT: keep native interaction, replace only painting
}

ApplyTextToolNativeTheme(hwnd, theme, className := "Explorer") {
    static uxTheme := DllCall("LoadLibraryW", "str", "uxtheme.dll", "ptr")
    static allowWindow := 0, initialized := false
    if !initialized {
        initialized := true
        ; Ordinal 135 changed signature in Windows 10 1903. Never call it on
        ; older builds. These private APIs/theme classes may change in Windows.
        version := Buffer(284, 0)
        NumPut("uint", version.Size, version)
        if DllCall("ntdll\RtlGetVersion", "ptr", version) = 0 && NumGet(version, 12, "uint") >= 18362 {
            allowWindow := DllCall("GetProcAddress", "ptr", uxTheme, "ptr", 133, "ptr")
            preferredMode := DllCall("GetProcAddress", "ptr", uxTheme, "ptr", 135, "ptr")
            if preferredMode
                DllCall(preferredMode, "int", 1, "int") ; AllowDark, not process-wide ForceDark
        }
    }
    if allowWindow
        DllCall(allowWindow, "ptr", hwnd, "int", theme = "dark", "int")
    ; Explicit classes let fixed light and dark windows coexist in one process.
    try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd,
        "str", (theme = "dark" ? "DarkMode_" : "") className, "ptr", 0)
}

SetRichEditTheme(hwnd, background, foreground) {
    selection := Buffer(8), scroll := Buffer(8)
    SendMessage(0x434, 0, selection.Ptr, hwnd) ; EM_EXGETSEL
    SendMessage(0x4DD, 0, scroll.Ptr, hwnd) ; EM_GETSCROLLPOS
    cf := Buffer(116, 0)
    NumPut("uint", 116, cf, 0)
    NumPut("uint", 0x40000000, cf, 4) ; CFM_COLOR
    NumPut("uint", TextToolColorRef(foreground), cf, 20)
    SendMessage(0x443, 0, TextToolColorRef(background), hwnd)
    SendMessage(0x444, 4, cf.Ptr, hwnd) ; SCF_ALL: existing text
    SendMessage(0x444, 0, cf.Ptr, hwnd) ; default format: subsequent text
    SendMessage(0x437, 0, selection.Ptr, hwnd) ; EM_EXSETSEL
    SendMessage(0x4DE, 0, scroll.Ptr, hwnd) ; EM_SETSCROLLPOS
}
