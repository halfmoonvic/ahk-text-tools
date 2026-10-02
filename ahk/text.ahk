#Requires AutoHotkey v2.0
#SingleInstance Force
#Include json.ahk
#Include process.ahk
#Include settings.ahk
#Include theme.ahk
#Include richedit.ahk
#Include popup.ahk
#Include runner.ahk

TextToolBatches := Map()
TextToolRuns := Map()
TextToolViews := Map()
TextToolInputs := Map()
TextToolThemeWindows := Map()
TextToolThemeReader := ReadWindowsAppTheme
TextToolRoot := RegExReplace(A_LineFile, "\\ahk\\[^\\]+$", "")
OnMessage(0x115, ScrollTextTools)
OnMessage(0x20A, WheelTextTools)
OnMessage(0x100, TextToolInputKey)
OnMessage(0x1A, TextToolThemeChanged)
OnMessage(0x31A, TextToolThemeChanged)
OnMessage(0x4E, DrawTextToolButton) ; WM_NOTIFY / NM_CUSTOMDRAW
OnMessage(0x20, TextToolSearchCursor) ; WM_SETCURSOR
OnExit(ExitTextTools)

; Order matters: an earlier action keeps a contested hotkey.
TextToolActions := [
    {Id: "translate", Default: "#!a", Title: "Translate"},
    {Id: "kana", Default: "#!s", Title: "Japanese Kana"}
]
; Without this the script exits when every hotkey is disabled or fails to register.
Persistent()
RegisterTextToolHotkeys()

RegisterTextToolHotkeys() {
    problems := []
    config := Map()
    try config := ReadTextToolConfig()
    catch as err
        problems.Push("settings.json could not be read (" err.Message "); default hotkeys are in use")
    resolved := ResolveTextToolHotkeys(config)
    for problem in resolved.Problems
        problems.Push(problem)
    for binding in resolved.Bindings {
        try Hotkey(binding.Key, CreateTextToolHotkeyCallback(binding.Action), "On")
        catch as err
            problems.Push("settings.json: hotkeys." binding.Action.Id ': invalid hotkey "' binding.Key '" (' err.Message ")")
    }
    if problems.Length {
        message := ""
        for problem in problems
            message .= problem "`n"
        ShowStaticPopup("Text tools hotkeys", message "`nFix settings.json, then reload the script.")
    }
}

; An explicit setting that is wrong disables its action rather than falling
; back to the default, which may be the very key the user wanted to free.
ResolveTextToolHotkeys(config) {
    global TextToolActions
    result := {Bindings: [], Problems: []}
    hotkeys := Map()
    if config.Has("hotkeys") {
        if config["hotkeys"] is Map
            hotkeys := config["hotkeys"]
        else
            result.Problems.Push("settings.json: hotkeys must be an object; default hotkeys are in use")
    }
    used := Map()
    for action in TextToolActions {
        key := action.Default
        if hotkeys.Has(action.Id) {
            value := hotkeys[action.Id]
            if IsObject(value) && value.HasOwnProp("JsonLiteral") && value.JsonLiteral = "null"
                continue
            if Type(value) != "String" {
                result.Problems.Push("settings.json: hotkeys." action.Id ": must be a string or null")
                continue
            }
            key := Trim(value, " `t`r`n")
            if key = ""
                continue
        }
        normalized := NormalizeTextToolHotkey(key)
        if used.Has(normalized) {
            result.Problems.Push("settings.json: hotkeys." action.Id ': "' key '" is already used by hotkeys.' used[normalized])
            continue
        }
        used[normalized] := action.Id
        result.Bindings.Push({Action: action, Key: key})
    }
    expected := ""
    for action in TextToolActions
        expected .= (A_Index > 1 ? " or " : "") action.Id
    for name in hotkeys {
        known := false
        for action in TextToolActions
            known := known || action.Id == name
        if !known
            result.Problems.Push("settings.json: hotkeys." name ": unknown action (expected " expected ")")
    }
    return result
}

; Hotkey() matches an existing hotkey ignoring case, modifier order, ~ and $,
; then silently replaces its callback. * makes a separate hotkey, so it stays.
NormalizeTextToolHotkey(key) {
    key := StrLower(key)
    if InStr(key, " & ")
        return RegExReplace(key, "^~")
    units := ""
    while StrLen(key) > 1 && RegExMatch(key, "^(?:[<>]?[\^!+#]|[*~$])", &match) {
        if match[0] != "~" && match[0] != "$"
            units .= match[0] "`n"
        key := SubStr(key, match.Len + 1)
    }
    return StrReplace(Sort(units), "`n") "|" key
}

; A closure written in the caller's loop would capture its shared loop
; variable, and Bind would pass the hotkey name as an extra argument.
CreateTextToolHotkeyCallback(action) {
    return (*) => RunSelectedTextTool(action)
}

RunSelectedTextTool(action) {
    try {
        config := ReadTextToolConfig()
        engines := GetTextToolEngines(config, action.Id)
    } catch as err {
        ShowStaticPopup(action.Title, err.Message)
        return
    }
    oldClipboard := ClipboardAll()
    text := ""
    try {
        A_Clipboard := ""
        Send "^c"
        if ClipWait(0.5)
            text := A_Clipboard
    } finally {
        A_Clipboard := oldClipboard
    }
    StartTextToolBatch(action, engines, text, config)
}

ExitTextTools(*) {
    global TextToolBatches, TextToolRuns, TextToolThemeWindows
    batches := []
    for hwnd, batch in TextToolBatches
        batches.Push(batch)
    for batch in batches
        CloseTextToolBatch(batch)
    popups := []
    for hwnd, window in TextToolThemeWindows
        popups.Push(window.Gui)
    for popup in popups
        CloseStaticTextPopup(popup)
    deadline := A_TickCount + 5000
    while TextToolRuns.Count && A_TickCount < deadline {
        pending := []
        for directory, run in TextToolRuns
            pending.Push(run)
        for run in pending
            PollTextToolBatch(run)
        Sleep(20)
    }
}
