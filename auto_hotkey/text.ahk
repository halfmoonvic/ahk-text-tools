#Requires AutoHotkey v2.0
#SingleInstance Force
#Include json.ahk
#Include proc.ahk

TextToolBatches := Map()
TextToolRuns := Map()
TextToolViews := Map()
TextToolInputs := Map()
TextToolThemeWindows := Map()
TextToolThemeReader := ReadWindowsAppTheme
TextToolRoot := RegExReplace(A_LineFile, "\\auto_hotkey\\[^\\]+$", "")
OnMessage(0x115, ScrollTextTools)
OnMessage(0x20A, WheelTextTools)
OnMessage(0x100, TextToolInputKey)
OnMessage(0x1A, TextToolThemeChanged)
OnMessage(0x31A, TextToolThemeChanged)
OnMessage(0x4E, DrawTextToolButton) ; WM_NOTIFY / NM_CUSTOMDRAW
OnMessage(0x20, TextToolSearchCursor) ; WM_SETCURSOR
OnExit(ExitTextTools)

^#a::RunSelectedTextTool("Translate", "translate.ps1", true)
^#s::RunSelectedTextTool("Japanese Kana", "kana.ps1")

RunSelectedTextTool(title, scriptName, multiEngine := false) {
    try {
        config := ReadToolConfig(multiEngine)
        engines := multiEngine ? GetTranslateEngines(config) : [title]
    } catch as err {
        ShowStaticPopup(title, err.Message)
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
    StartTextToolBatch(title, scriptName, engines, text, config)
}

ReadTextToolConfig(path := "") {
    if path = ""
        path := GetConfigRoot() "\ahk\settings.json"
    config := Json.Parse(FileRead(path, "UTF-8"))
    if !(config is Map)
        throw Error("Text tools configuration must be a JSON object.")
    return config
}

ReadToolConfig(multiEngine) {
    ; Only an engine list is required up front; every other tool validates its
    ; own options and falls back to defaults when the file is missing.
    if multiEngine
        return ReadTextToolConfig()
    try return ReadTextToolConfig()
    catch
        return Map()
}

GetTranslateEngines(config) {
    if !config.Has("translate") || !(config["translate"] is Array) || !config["translate"].Length
        throw Error("settings.json: translate must be a nonempty array of engines.")
    for engine in config["translate"] {
        if Type(engine) != "String" || (engine != "google" && !RegExMatch(engine, "^[^/\s]+/[^\s]+$"))
            throw Error("Each translate entry must be google or a full provider/model identifier.")
    }
    return config["translate"]
}

GetPopupUiConfig(config := 0) {
    result := {FontSize: 16, FontName: "Microsoft YaHei UI", Width: 760, MinHeight: 300, MaxHeight: 760, LineHeight: 1.0, Padding: 12, Theme: "auto", AlwaysOnTop: false}
    if !(config is Map) {
        try config := ReadTextToolConfig()
        catch
            return result
    }
    if config.Has("ui") && config["ui"] is Map {
        ui := config["ui"]
        if ui.Has("theme") && Type(ui["theme"]) = "String" && RegExMatch(ui["theme"], "^(light|dark|auto)$")
            result.Theme := ui["theme"]
        if ui.Has("alwaysOnTop")
            result.AlwaysOnTop := ParseTextToolBoolean(ui["alwaysOnTop"], result.AlwaysOnTop)
        if ui.Has("fontSize") && IsNumber(ui["fontSize"]) && ui["fontSize"] >= 1 && ui["fontSize"] <= 72
            result.FontSize := ui["fontSize"]
        if ui.Has("fontName") && Type(ui["fontName"]) = "String" && ui["fontName"] != ""
            result.FontName := ui["fontName"]
        ; Bounds only reject typos; A_ScreenHeight still clamps the real height.
        if ui.Has("width") && IsNumber(ui["width"]) && ui["width"] >= 200 && ui["width"] <= 10000
            result.Width := ui["width"]
        if ui.Has("minHeight") && IsNumber(ui["minHeight"]) && ui["minHeight"] >= 150 && ui["minHeight"] <= 10000
            result.MinHeight := ui["minHeight"]
        if ui.Has("maxHeight") && IsNumber(ui["maxHeight"]) && ui["maxHeight"] >= 150 && ui["maxHeight"] <= 10000
            result.MaxHeight := ui["maxHeight"]
        ; A multiple of the natural line height; 1.0 leaves the text as the font sets it.
        if ui.Has("lineHeight") && IsNumber(ui["lineHeight"]) && ui["lineHeight"] >= 0.8 && ui["lineHeight"] <= 4
            result.LineHeight := ui["lineHeight"]
        ; Inner breathing room in the text boxes, in unscaled pixels.
        if ui.Has("padding") && IsNumber(ui["padding"]) && ui["padding"] >= 0 && ui["padding"] <= 48
            result.Padding := ui["padding"]
    }
    return result
}

ParseTextToolBoolean(value, fallback) {
    ; json.ahk keeps JSON literals as {JsonLiteral: "true"|"false"}.
    if IsObject(value) && value.HasOwnProp("JsonLiteral") {
        if value.JsonLiteral = "true"
            return true
        if value.JsonLiteral = "false"
            return false
    }
    return fallback
}

StartTextToolBatch(title, scriptName, engines, text, config) {
    Critical "On"
    ; Created here, not by CreateTextToolWindow, so a window that fails partway
    ; through construction can still be closed.
    batch := {Tasks: [], Open: true}
    try {
        CreateTextToolWindow(batch, title, scriptName, engines, config)
        CreateTextToolRows(batch, engines)
        popupWidth := Round(batch.Ui.Width * batch.Scale)
        popupHeight := ClampPopupHeight(batch, batch.RowHeight * engines.Length + 24)
        RegisterTextToolTheme(batch)
        batch.Gui.Show("w" popupWidth " h" popupHeight)
        LayoutTextTools(batch, 0, 0)
        ; Complete the first frame before a synchronous process can block the UI.
        DllCall("RedrawWindow", "ptr", batch.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x185)
        InitializeTextToolInput(batch, text)
        return batch
    } catch as err {
        if batch.HasOwnProp("Gui")
            CloseTextToolBatch(batch)
        ShowStaticPopup(title, err.Message)
    } finally {
        Critical "Off"
    }
}

CreateTextToolWindow(batch, title, scriptName, engines, config) {
    global TextToolBatches, TextToolViews
    batch.Scroll := 0, batch.Current := 0, batch.ScriptName := scriptName, batch.Engines := engines
    batch.HeaderHeight := 0, batch.UserSized := false, batch.AutoHeight := 0
    batch.Ui := GetPopupUiConfig(config)
    windowFlags := batch.Ui.AlwaysOnTop ? "+AlwaysOnTop " : ""
    batch.Gui := Gui(windowFlags "+Resize -DPIScale +MinSize420x240", title)
    batch.Hwnd := batch.Gui.Hwnd
    batch.Gui.SetFont("s" batch.Ui.FontSize, batch.Ui.FontName)
    batch.Scale := A_ScreenDPI / 96
    batch.SmallFontSize := Min(11, batch.Ui.FontSize)
    batch.BodyFont := CreateTextToolFont(batch.Ui.FontName, batch.Ui.FontSize, batch.Scale)
    batch.SmallFont := CreateTextToolFont(batch.Ui.FontName, batch.SmallFontSize, batch.Scale)
    CreateTextToolHeader(batch)
    batch.View := Gui("+Parent" batch.Hwnd " -Caption +0x40000000 +0x200000 -DPIScale")
    batch.View.SetFont("s" batch.Ui.FontSize, batch.Ui.FontName)
    TextToolViews[batch.View.Hwnd] := batch
    batch.View.OnEvent("Escape", (*) => CloseTextToolBatch(batch))
    batch.RowHeight := Max(Round(250 * batch.Scale), Round(batch.Ui.FontSize * 16 * batch.Scale))
    TextToolBatches[batch.Hwnd] := batch
    batch.Gui.OnEvent("Close", (*) => CloseTextToolBatch(batch))
    batch.Gui.OnEvent("Escape", (*) => CloseTextToolBatch(batch))
    batch.Gui.OnEvent("Size", (guiObj, minMax, width, height) => LayoutTextTools(batch, width, height))
}

CreateTextToolHeader(batch) {
    global TextToolInputs
    batch.HeaderHeight := Round(78 * batch.Scale)
    batch.SearchBackground := batch.Gui.Add("Text", "x12 y12 w400 h36", "")
    batch.Search := batch.Gui.Add("Edit", "x12 y12 w400 h36 -Multi WantReturn -E0x200 -Border")
    batch.SearchLineHeight := TextToolInputLineHeight(batch.Search.Hwnd)
    inputPadding := Round(8 * batch.Scale)
    SendMessage(0xD3, 3, inputPadding | (inputPadding << 16), batch.Search.Hwnd)
    batch.Submit := batch.Gui.Add("Button", "x420 y12 w110 h36", "Run")
    batch.Submit.SetFont("s" batch.SmallFontSize)
    batch.Hint := batch.Gui.Add("Text", "x12 y50 w400 h24", "")
    batch.Hint.SetFont("s" Min(10, batch.Ui.FontSize))
    batch.Submit.OnEvent("Click", (*) => SubmitTextTool(batch))
    batch.InputProc := CallbackCreate(TextToolInputMessage, , 6)
    if !DllCall("comctl32\SetWindowSubclass", "ptr", batch.Search.Hwnd,
        "ptr", batch.InputProc, "uptr", 1, "uptr", 0)
        throw Error("Could not initialize the text input.")
    TextToolInputs[batch.Search.Hwnd] := batch
    batch.BackgroundProc := CallbackCreate(TextToolBackgroundMessage, , 6)
    if !DllCall("comctl32\SetWindowSubclass", "ptr", batch.SearchBackground.Hwnd,
        "ptr", batch.BackgroundProc, "uptr", 1, "uptr", 0)
        throw Error("Could not initialize the text input.")
}

CreateTextToolRows(batch, engines) {
    for engine in engines {
        task := {Engine: engine, Output: "", Error: ""}
        task.Label := batch.View.Add("Text", "x12 y12 w400 h32", engine)
        task.Label.SetFont("s" Min(13, batch.Ui.FontSize) " bold")
        task.Status := batch.View.Add("Text", "x12 y44 w400 h30 Right", "Ready")
        task.Status.SetFont("s" batch.SmallFontSize)
        task.Copy := batch.View.Add("Button", "x500 y12 w100 h36", "Copy")
        task.Copy.SetFont("s" batch.SmallFontSize)
        task.Copy.OnEvent("Click", CopyTextTool.Bind(task))
        task.Edit := CreateRichEdit(batch.View.Hwnd, batch.BodyFont)
        task.ErrorEdit := CreateRichEdit(batch.View.Hwnd, batch.SmallFont)
        DllCall("ShowWindow", "ptr", task.ErrorEdit, "int", 0)
        batch.Tasks.Push(task)
    }
}

InitializeTextToolInput(batch, text) {
    if Trim(text) != ""
        batch.Search.Value := RegExReplace(text, "\r\n|\r|\n", " ")
    batch.Search.Focus()
    SendMessage(0x00B1, 0, -1, batch.Search.Hwnd)
    if Trim(text) != ""
        BeginTextToolRun(batch, text)
}

CopyTextTool(task, *) {
    A_Clipboard := task.Output
}

TryReadTaskFile(path, &text) {
    try {
        text := FileRead(path, "UTF-8")
        return true
    } catch {
        return false
    }
}

; Nest updates so text, geometry and selection become visible together.
BeginTextToolPaint(batch) {
    if batch.HasOwnProp("PaintDepth") && batch.PaintDepth {
        batch.PaintDepth += 1
        return
    }
    batch.PaintDepth := 1
    batch.PaintWindows := []
    batch.DirtyWindows := Map()
    batch.RichStates := []
    if batch.HasOwnProp("View") && batch.View.Hwnd {
        SendMessage(0xB, 0, 0, batch.View.Hwnd)
        batch.PaintWindows.Push(batch.View.Hwnd)
    }
    for row in batch.Tasks {
        for hwnd in [row.Edit, row.ErrorEdit] {
            selection := Buffer(8), scroll := Buffer(8)
            SendMessage(0x434, 0, selection.Ptr, hwnd)
            SendMessage(0x4DD, 0, scroll.Ptr, hwnd)
            batch.RichStates.Push({Hwnd: hwnd, Selection: selection, Scroll: scroll})
        }
        for hwnd in [row.Edit, row.ErrorEdit, row.Label.Hwnd, row.Copy.Hwnd, row.Status.Hwnd] {
            if DllCall("GetWindowLongW", "ptr", hwnd, "int", -16, "uint") & 0x10000000 {
                SendMessage(0xB, 0, 0, hwnd)
                batch.PaintWindows.Push(hwnd)
            }
        }
    }
}

EndTextToolPaint(batch) {
    batch.PaintDepth -= 1
    if batch.PaintDepth
        return
    for state in batch.RichStates {
        length := SendMessage(0xE, 0, 0, state.Hwnd)
        NumPut("int", Min(length, NumGet(state.Selection, 0, "int")), state.Selection, 0)
        NumPut("int", Min(length, NumGet(state.Selection, 4, "int")), state.Selection, 4)
        SendMessage(0x437, 0, state.Selection.Ptr, state.Hwnd)
        SendMessage(0x4DE, 0, state.Scroll.Ptr, state.Hwnd)
    }
    for hwnd in batch.PaintWindows
        SendMessage(0xB, 1, 0, hwnd)
    ; WM_SETREDRAW(TRUE) makes a window visible: restore intended error visibility.
    for row in batch.Tasks
        DllCall("ShowWindow", "ptr", row.ErrorEdit, "int", Trim(row.Error) != "" ? 4 : 0)
    for hwnd, flags in batch.DirtyWindows
        DllCall("RedrawWindow", "ptr", hwnd, "ptr", 0, "ptr", 0, "uint", flags)
}

MoveTextToolControl(batch, hwnd, x, y, width, height) {
    if !batch.HasOwnProp("Positions")
        batch.Positions := Map()
    key := x "," y "," width "," height
    if batch.Positions.Has(hwnd) && batch.Positions[hwnd] == key
        return false
    batch.Positions[hwnd] := key
    DllCall("MoveWindow", "ptr", hwnd, "int", x, "int", y,
        "int", width, "int", height, "int", 0)
    batch.DirtyWindows[hwnd] := 1
    batch.DirtyWindows[batch.View.Hwnd] := 7 ; exposed background and transparent labels
    return true
}

UpdateRichText(hwnd, previous, text, lineHeight) {
    if text == previous
        return false
    append := StrLen(text) > StrLen(previous) && SubStr(text, 1, StrLen(previous)) == previous
    if !append {
        SetRichText(hwnd, text, lineHeight)
        return false
    }
    ; -1 resolves the native end even when RichEdit normalizes CR/LF pairs.
    SendMessage(0xB1, -1, -1, hwnd) ; EM_SETSEL: append at the actual end
    suffix := SubStr(text, StrLen(previous) + 1)
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0xC2, "ptr", 0, "wstr", suffix) ; EM_REPLACESEL
    if lineHeight != 1.0 {
        SendMessage(0xB1, -1, -1, hwnd)
        ApplyLineSpacing(hwnd, lineHeight, false)
    }
    return true
}

CreateTextToolFont(fontName, fontPt, scale) {
    lf := Buffer(92, 0)                                    ; LOGFONTW
    NumPut("int", -Round(fontPt * 96 * scale / 72), lf, 0)
    NumPut("int", 400, lf, 16)
    NumPut("uchar", 1, lf, 23)
    StrPut(fontName, lf.Ptr + 28, 32)
    hFont := DllCall("CreateFontIndirectW", "ptr", lf.Ptr, "ptr")
    if !hFont
        throw Error("Could not create the popup font.")
    return hFont
}

; A plain Edit fixes its line height to the font, so the text boxes are RichEdit
; controls instead. AHK cannot create one, hence the raw CreateWindowExW.
CreateRichEdit(parentHwnd, hFont) {
    static loaded := DllCall("LoadLibrary", "str", "Msftedit.dll", "ptr")
    ; WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL.
    ; No WS_VSCROLL: blocks size to their content, so only the window scrolls.
    style := 0x40000000 | 0x10000000 | 0x00010000 | 0x0004 | 0x0800 | 0x0040
    ; No WS_EX_CLIENTEDGE: the sunken 3D frame reads as a hard line against the
    ; window background. The block is set apart by its fill and the padding.
    hwnd := DllCall("CreateWindowExW", "uint", 0, "str", "RICHEDIT50W", "str", ""
        , "uint", style, "int", 0, "int", 0, "int", 100, "int", 100
        , "ptr", parentHwnd, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")
    if !hwnd
        throw Error("Could not create the RichEdit text box.")
    ; A RichEdit inherits nothing from the Gui, so font and colours are explicit.
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0x30      ; WM_SETFONT
        , "ptr", hFont, "ptr", 1)
    return hwnd
}

; Replace a RichEdit's text, then restore the line spacing a text change clears.
SetRichText(hwnd, text, lineHeight) {
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0x000C, "ptr", 0, "wstr", text) ; WM_SETTEXT
    ApplyLineSpacing(hwnd, lineHeight)
}

; Space the lines as a multiple of their natural height. Rule 5 reads
; dyLineSpacing as twentieths of a line; rule 4 looks equivalent but collapses
; the text to a few pixels while still reporting success.
ApplyLineSpacing(hwnd, multiple, selectAll := true) {
    if multiple = 1.0
        return
    if selectAll
        DllCall("SendMessageW", "ptr", hwnd, "uint", 0x00B1, "ptr", 0, "ptr", -1) ; EM_SETSEL all
    pf := Buffer(188, 0)                           ; PARAFORMAT2
    NumPut("uint", 188, pf, 0)
    NumPut("uint", 0x00000100, pf, 4)              ; PFM_LINESPACING
    NumPut("int", Round(multiple * 20), pf, 164)
    NumPut("uchar", 5, pf, 170)                    ; bLineSpacingRule 5
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0x0447, "ptr", 0x0001, "ptr", pf.Ptr) ; EM_SETPARAFORMAT
    if selectAll
        DllCall("SendMessageW", "ptr", hwnd, "uint", 0x00B1, "ptr", 0, "ptr", 0)
}

; Inset the text from the control's edges. Unlike line spacing this survives a
; text change. A resize does keep the inset, but only as undocumented behaviour,
; so the layout re-applies after each MoveWindow rather than relying on it.
ApplyTextPadding(hwnd, pad) {
    if pad <= 0
        return
    cr := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", hwnd, "ptr", cr.Ptr)
    width := NumGet(cr, 8, "int"), height := NumGet(cr, 12, "int")
    ; Never inset so far that no text fits; a tiny box simply gets less padding.
    pad := Min(pad, (width - 20) // 2, (height - 8) // 2)
    if pad <= 0
        return
    rect := Buffer(16, 0)
    NumPut("int", pad, "int", pad, "int", width - pad, "int", height - pad, rect)
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0x00B4, "ptr", 0, "ptr", rect.Ptr) ; EM_SETRECTNP
}

; Top of a character, in client pixels. A RichEdit fills a POINTL rather than
; packing the coordinates into the return value the way a plain Edit does.
RichPosY(hwnd, charIndex) {
    pt := Buffer(8, 0)
    DllCall("SendMessageW", "ptr", hwnd, "uint", 0x00D6, "ptr", pt.Ptr, "ptr", charIndex)
    return NumGet(pt, 4, "int")
}

; Pixel height a text box needs to show all its text unscrolled. The wrapped
; line count depends on the control's width, so call this only after its final
; MoveWindow().
MeasureEditHeight(hwnd, fallbackLineHeight) {
    lines := DllCall("SendMessageW", "ptr", hwnd, "uint", 0xBA, "ptr", 0, "ptr", 0) ; EM_GETLINECOUNT
    lineHeight := 0
    ; Line 2 is absent (-1) in single-line content, leaving no pair to measure.
    idx := DllCall("SendMessageW", "ptr", hwnd, "uint", 0xBB, "ptr", 1, "ptr", 0) ; EM_LINEINDEX
    if idx >= 0
        lineHeight := RichPosY(hwnd, idx) - RichPosY(hwnd, 0)
    if lineHeight <= 0
        lineHeight := fallbackLineHeight
    return Max(lines, 1) * lineHeight
}

SubmitTextTool(batch) {
    if !batch.Open
        return
    text := batch.Search.Value
    if Trim(text) = "" {
        batch.Hint.Value := "Enter text."
        batch.Search.Focus()
        return
    }
    batch.Hint.Value := ""
    BeginTextToolRun(batch, text)
    batch.Search.Focus()
}

TextToolInputKey(wParam, lParam, msg, hwnd) {
    global TextToolInputs, TextToolBatches
    ; Native RichEdit children do not participate in AHK's dialog Escape event.
    if wParam = 27 {
        root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
        if TextToolBatches.Has(root) {
            CloseTextToolBatch(TextToolBatches[root])
            return 0
        }
    }
    if wParam != 13 || !TextToolInputs.Has(hwnd)
        return
    batch := TextToolInputs[hwnd]
    ; IME consumes its confirmation Enter. Do not submit during composition.
    if batch.HasOwnProp("Composing") && batch.Composing
        return
    context := DllCall("imm32\ImmGetContext", "ptr", hwnd, "ptr")
    if context {
        composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", context,
            "uint", 8, "ptr", 0, "uint", 0, "int") > 0
        DllCall("imm32\ImmReleaseContext", "ptr", hwnd, "ptr", context)
        if composing
            return
    }
    if !(lParam & 0x40000000)
        SubmitTextTool(batch)
    return 0
}

TextToolInputMessage(hwnd, msg, wParam, lParam, subclassId, refData) {
    global TextToolInputs
    if TextToolInputs.Has(hwnd) {
        batch := TextToolInputs[hwnd]
        if msg = 0x10D
            batch.Composing := true
        else if msg = 0x10E
            batch.Composing := false
        else if msg = 0x302 {
            text := RegExReplace(A_Clipboard, "\r\n|\r|\n", " ")
            DllCall("SendMessageW", "ptr", hwnd, "uint", 0xC2, "ptr", 1, "wstr", text)
            return 0
        }
    }
    return DllCall("comctl32\DefSubclassProc", "ptr", hwnd, "uint", msg,
        "ptr", wParam, "ptr", lParam, "ptr")
}

; HTTRANSPARENT sends the hit-test on to the window below, so a press on the
; background strip lands in the Edit at the same point. The Edit then sets the
; caret and runs the drag itself; focusing it in code would select all instead.
TextToolBackgroundMessage(hwnd, msg, wParam, lParam, subclassId, refData) {
    if msg = 0x84 ; WM_NCHITTEST
        return -1 ; HTTRANSPARENT
    return DllCall("comctl32\DefSubclassProc", "ptr", hwnd, "uint", msg,
        "ptr", wParam, "ptr", lParam, "ptr")
}

BeginTextToolRun(batch, text) {
    global TextToolRuns, TextToolRoot
    Critical "On"
    run := 0
    BeginTextToolPaint(batch)
    try {
        if batch.Current
            StopTextToolRun(batch.Current)
        batch.Current := 0
        batch.Scroll := 0
        ResetTextToolResults(batch)
        run := CreateTextToolRun(batch, text)
        StartTextToolRunTasks(run)
        SetTimer(run.Poller, 200)
    } catch as err {
        if run {
            StopTextToolRun(run)
            SetTimer(run.Poller, 200)
        }
        for row in batch.Tasks {
            row.Status.Value := "Failed to start"
            row.Error := err.Message
            SetRichText(row.ErrorEdit, err.Message, batch.Ui.LineHeight)
        }
    } finally {
        try LayoutTextTools(batch, 0, 0)
        finally {
            EndTextToolPaint(batch)
            Critical "Off"
        }
    }
}

ResetTextToolResults(batch) {
    for row in batch.Tasks {
        row.Output := "", row.Error := ""
        SetRichText(row.Edit, "", batch.Ui.LineHeight)
        SetRichText(row.ErrorEdit, "", batch.Ui.LineHeight)
        batch.DirtyWindows[row.Edit] := 1
        batch.DirtyWindows[row.Status.Hwnd] := 5
        row.Status.Value := "Starting..."
    }
}

CreateTextToolRun(batch, text) {
    global TextToolRuns
    guid := Buffer(16)
    DllCall("ole32\CoCreateGuid", "ptr", guid)
    guidText := Buffer(78)
    DllCall("ole32\StringFromGUID2", "ptr", guid, "ptr", guidText, "int", 39)
    directory := A_Temp "\text-tools-" StrGet(guidText)
    run := {Dir: directory, Tasks: [], Owner: batch, Cancelled: false, Cleaned: false, Poller: 0}
    run.Poller := (*) => PollTextToolBatch(run)
    TextToolRuns[directory] := run
    batch.Current := run
    DirCreate(directory)
    run.Input := directory "\input.txt"
    FileAppend(text, run.Input, "UTF-8-RAW")
    return run
}

StartTextToolRunTasks(run) {
    global TextToolRoot
    batch := run.Owner
    for row in batch.Tasks {
        task := {Row: row, Process: 0, Done: false, Output: "", Error: "",
            OutputFile: run.Dir "\" A_Index ".out", ErrorFile: run.Dir "\" A_Index ".err"}
        run.Tasks.Push(task)
        try {
            arguments := ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                TextToolRoot "\auto_hotkey\run-task.ps1", "-Script", TextToolRoot "\" batch.ScriptName,
                "-InputFile", run.Input, "-OutputFile", task.OutputFile]
            if batch.ScriptName = "translate.ps1" {
                if row.Engine = "google"
                    arguments.Push("-Mode", "google")
                else
                    arguments.Push("-Model", row.Engine)
            }
            task.Process := Proc(arguments, task.ErrorFile)
            row.Status.Value := "Running..."
        } catch as err {
            task.Done := true
            row.Error := err.Message
            SetRichText(row.ErrorEdit, err.Message, batch.Ui.LineHeight)
            row.Status.Value := "Failed to start"
        }
    }
}

StopTextToolRun(run) {
    run.Cancelled := true
    for task in run.Tasks {
        if !task.Done && task.Process
            task.Process.Stop()
    }
}

PollTextToolBatch(run) {
    ; Prevent a submit/close interrupt between the ownership check and a UI write.
    Critical "On"
    try {
        if run.Cleaned
            return
        batch := run.Owner
        active := batch.Open && batch.Current = run && !run.Cancelled
        allDone := true
        updates := []
        for task in run.Tasks {
            if task.Done
                continue
            finished := task.Process.Poll()
            if active {
                row := task.Row
                output := row.Output, errorOutput := row.Error
                outputRead := TryReadTaskFile(task.OutputFile, &output)
                errorRead := TryReadTaskFile(task.ErrorFile, &errorOutput)
                ; A final locked file must be retried before disposing the task.
                if finished && ((!outputRead && FileExist(task.OutputFile)) || (!errorRead && FileExist(task.ErrorFile)))
                    finished := false
                status := finished ? (task.Process.ExitCode != 0 ? "Failed (exit " task.Process.ExitCode ")" : (Trim(output) = "" ? "Failed (empty output)" : "Completed")) : row.Status.Value
                if !(output == row.Output) || !(errorOutput == row.Error) || !(status == row.Status.Value)
                    updates.Push({Row: row, Output: output, Error: errorOutput, Status: status})
            }
            if finished {
                task.Done := true
                task.Process.Dispose()
            } else
                allDone := false
        }
        if updates.Length && active {
            BeginTextToolPaint(batch)
            try {
                layoutChanged := false
                for update in updates {
                    row := update.Row
                    if !(update.Output == row.Output) {
                        UpdateRichText(row.Edit, row.Output, update.Output, batch.Ui.LineHeight)
                        batch.DirtyWindows[row.Edit] := 1
                        layoutChanged := true
                    }
                    if !(update.Error == row.Error) {
                        UpdateRichText(row.ErrorEdit, row.Error, update.Error, batch.Ui.LineHeight)
                        batch.DirtyWindows[row.ErrorEdit] := 1
                        layoutChanged := true
                    }
                    row.Output := update.Output, row.Error := update.Error
                    if !(row.Status.Value == update.Status) {
                        row.Status.Value := update.Status
                        batch.DirtyWindows[row.Status.Hwnd] := 5
                    }
                }
                if layoutChanged
                    LayoutTextTools(batch, 0, 0)
            } finally {
                EndTextToolPaint(batch)
            }
        }
        if allDone {
            SetTimer(run.Poller, 0)
            CleanupTextToolRun(run)
        }
    } finally {
        Critical "Off"
    }
}

CloseTextToolBatch(batch) {
    global TextToolBatches, TextToolInputs, TextToolViews, TextToolRuns, TextToolThemeWindows
    Critical "On"
    try {
        if !batch.Open
            return
        batch.Open := false
        if TextToolThemeWindows.Has(batch.Hwnd)
            TextToolThemeWindows.Delete(batch.Hwnd)
        for directory, run in TextToolRuns {
            if run.Owner = batch
                StopTextToolRun(run)
        }
        if batch.HasOwnProp("Search") {
            if batch.HasOwnProp("InputProc") {
                DllCall("comctl32\RemoveWindowSubclass", "ptr", batch.Search.Hwnd,
                    "ptr", batch.InputProc, "uptr", 1)
                CallbackFree(batch.InputProc)
            }
            if batch.HasOwnProp("BackgroundProc") {
                DllCall("comctl32\RemoveWindowSubclass", "ptr", batch.SearchBackground.Hwnd,
                    "ptr", batch.BackgroundProc, "uptr", 1)
                CallbackFree(batch.BackgroundProc)
            }
            if TextToolInputs.Has(batch.Search.Hwnd)
                TextToolInputs.Delete(batch.Search.Hwnd)
        }
        if batch.HasOwnProp("View") {
            if TextToolViews.Has(batch.View.Hwnd)
                TextToolViews.Delete(batch.View.Hwnd)
            batch.View.Destroy()
        }
        batch.Gui.Destroy()
        ; Only now: deleting a font a live control still uses is undefined.
        if batch.HasOwnProp("BodyFont")
            DllCall("DeleteObject", "ptr", batch.BodyFont)
        if batch.HasOwnProp("SmallFont")
            DllCall("DeleteObject", "ptr", batch.SmallFont)
        if TextToolBatches.Has(batch.Hwnd)
            TextToolBatches.Delete(batch.Hwnd)
    } finally {
        Critical "Off"
    }
}

CleanupTextToolRun(run) {
    global TextToolRuns
    ; Called only after all job members exit. Check the absolute target before deletion.
    resolved := Buffer(65536)
    DllCall("GetFullPathNameW", "str", run.Dir, "uint", 32768, "ptr", resolved, "ptr", 0)
    target := StrGet(resolved)
    if !RegExMatch(target, "i)^" RegExReplace(A_Temp, "[\\.^$|?*+()\[\]{}]", "\$0") "\\text-tools-\{[0-9a-f-]{36}\}$")
        throw Error("Unrecognized text tools batch directory")
    try {
        if DirExist(target)
            DirDelete(target, true)
        run.Cleaned := true
        if TextToolRuns.Has(run.Dir)
            TextToolRuns.Delete(run.Dir)
        ; Release the timer closure and owner link after the final cleanup.
        run.Poller := 0
        run.Owner := 0
    } catch {
        ; Retry transient antivirus/file-sharing locks without losing ownership.
        if run.Poller
            SetTimer(run.Poller, 200)
    }
}

LayoutTextTools(batch, width, height) {
    if !batch.Open
        return
    ; Size events can be queued while a batch starts; use the current client size.
    batch.Gui.GetClientPos(,, &width, &height)
    if width <= 0 || height <= 0
        return
    ; A height we did not set ourselves means the user resized; stop auto-fitting.
    if batch.AutoHeight && Abs(height - batch.AutoHeight) > 2
        batch.UserSized := true
    windowHeight := height
    if batch.HeaderHeight && (!batch.HasOwnProp("HeaderWidth") || batch.HeaderWidth != width) {
        batch.HeaderWidth := width
        barPadding := Round(12 * batch.Scale)
        barHeight := Max(Round(36 * batch.Scale), Round(batch.Ui.FontSize * 2 * batch.Scale))
        batch.HeaderHeight := barPadding + barHeight + Round(30 * batch.Scale)
        submitWidth := Round(110 * batch.Scale)
        searchWidth := Max(40, width - barPadding * 3 - submitWidth)
        inputHeight := Min(barHeight, batch.SearchLineHeight)
        batch.SearchBackground.Move(barPadding, barPadding, searchWidth, barHeight)
        batch.Search.Move(barPadding, barPadding + (barHeight - inputHeight) // 2, searchWidth, inputHeight)
        batch.Submit.Move(width - barPadding - submitWidth, barPadding, submitWidth, barHeight)
        batch.Hint.Move(barPadding, barPadding + barHeight + 2, width - barPadding * 2, Round(24 * batch.Scale))
        ; Moving the initially sized controls can leave pixels on the parent.
        ; Repaint the header background too, not just the results child window.
        headerRect := Buffer(16, 0)
        NumPut("int", width, "int", batch.HeaderHeight, headerRect, 8)
        DllCall("RedrawWindow", "ptr", batch.Hwnd, "ptr", headerRect,
            "ptr", 0, "uint", 0x85)
    }
    ; Size the child by its outer bounds; Gui.Show w/h specify client bounds
    ; and would push the child's scrollbar beyond the parent's right edge.
    viewportSize := width "," height
    if !batch.HasOwnProp("ViewportSize") || batch.ViewportSize != viewportSize {
        batch.ViewportSize := viewportSize
        DllCall("MoveWindow", "ptr", batch.View.Hwnd, "int", 0, "int", batch.HeaderHeight,
            "int", width, "int", Max(1, height - batch.HeaderHeight), "int", 0)
        DllCall("ShowWindow", "ptr", batch.View.Hwnd, "int", 4)
        DllCall("RedrawWindow", "ptr", batch.View.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x85)
    }
    batch.View.GetClientPos(,, &width, &height)
    batch.Width := width
    padding := Round(12 * batch.Scale)
    gap := Round(6 * batch.Scale)
    titleHeight := Round(13 * batch.Scale * 1.8)
    buttonHeight := titleHeight + gap
    resultGap := Round(8 * batch.Scale)
    statusHeight := Round(20 * batch.Scale)
    buttonWidth := Round(76 * batch.Scale)
    editWidth := width - padding * 2
    fallbackLineHeight := Round(batch.Ui.FontSize * 2.2 * batch.Scale * batch.Ui.LineHeight)
    ; Spacing inside a text box, distinct from `padding` which separates blocks.
    textPad := Round(batch.Ui.Padding * batch.Scale)
    ; The error box uses the smaller font, so it needs its own line height.
    errorLineHeight := Round(batch.SmallFontSize * 2.35 * batch.Scale)
    BeginTextToolPaint(batch)
    try {
        ; Measure before placing: width must be final or the wrapped line count is stale.
        heights := []
        for task in batch.Tasks {
            hasError := Trim(task.Error) != ""
            ; Its own line height, not statusHeight: that clipped the text at 125% DPI.
            errorHeight := hasError ? errorLineHeight + gap : 0
            widthChanged := !task.HasOwnProp("MeasuredWidth") || task.MeasuredWidth != editWidth
            if widthChanged {
                rect := Buffer(16)
                DllCall("GetWindowRect", "ptr", task.Edit, "ptr", rect)
                DllCall("MapWindowPoints", "ptr", 0, "ptr", batch.View.Hwnd, "ptr", rect, "uint", 2)
                MoveTextToolControl(batch, task.Edit, NumGet(rect, 0, "int"), NumGet(rect, 4, "int"),
                    editWidth, Max(60, NumGet(rect, 12, "int") - NumGet(rect, 4, "int")))
                ApplyTextPadding(task.Edit, textPad)
            }
            if widthChanged || !task.HasOwnProp("MeasuredOutput") || !(task.MeasuredOutput == task.Output) {
                task.MeasuredHeight := Max(60, MeasureEditHeight(task.Edit, fallbackLineHeight) + textPad * 2)
                task.MeasuredWidth := editWidth
                task.MeasuredOutput := task.Output
            }
            editHeight := task.MeasuredHeight
            heights.Push({Edit: editHeight, Error: errorHeight, HasError: hasError,
                Total: buttonHeight + resultGap + editHeight + errorHeight + padding})
        }
        total := 24
        for entry in heights
            total += entry.Total
        batch.Height := height
        batch.TotalHeight := total
        batch.Scroll := Min(batch.Scroll, Max(0, batch.TotalHeight - height))
        info := Buffer(28, 0)
        ; Keep the scrollbar width reserved when disabled so wrapping stays stable.
        NumPut("uint", 28, "uint", 15, "int", 0, "int", batch.TotalHeight - 1, "uint", height, "int", batch.Scroll, info)
        scrollKey := batch.TotalHeight "," height "," batch.Scroll
        if !batch.HasOwnProp("ScrollKey") || batch.ScrollKey != scrollKey {
            DllCall("SetScrollInfo", "ptr", batch.View.Hwnd, "int", 1, "ptr", info, "int", true)
            batch.ScrollKey := scrollKey
        }
        y := 12 - batch.Scroll
        for task in batch.Tasks {
            entry := heights[A_Index]
            statusWidth := Round(160 * batch.Scale)
            statusRight := width - padding * 2 - buttonWidth
            statusX := statusRight - statusWidth
            MoveTextToolControl(batch, task.Label.Hwnd, padding, y, Max(60, statusX - padding - gap), titleHeight)
            MoveTextToolControl(batch, task.Copy.Hwnd, width - padding - buttonWidth, y, buttonWidth, buttonHeight)
            ; Status shares the title row, right-aligned against the Copy button.
            MoveTextToolControl(batch, task.Status.Hwnd, statusX, y + (buttonHeight - statusHeight) // 2, statusWidth, statusHeight)
            editY := y + buttonHeight + resultGap
            if MoveTextToolControl(batch, task.Edit, padding, editY, editWidth, entry.Edit)
                ApplyTextPadding(task.Edit, textPad)
            if !task.HasOwnProp("ErrorVisible") || task.ErrorVisible != entry.HasError {
                task.ErrorVisible := entry.HasError
                batch.DirtyWindows[batch.View.Hwnd] := 5
            }
            if entry.HasError {
                MoveTextToolControl(batch, task.ErrorEdit, padding, editY + entry.Edit + gap, editWidth, entry.Error - gap)
            }
            y += entry.Total
        }
        FitTextToolWindow(batch, windowHeight)
    } finally {
        EndTextToolPaint(batch)
    }
}

; Grow with the content, but never below MinHeight nor past MaxHeight or the screen.
ClampPopupHeight(batch, preferred) {
    return Max(Round(batch.Ui.MinHeight * batch.Scale),
        Min(Round(batch.Ui.MaxHeight * batch.Scale), A_ScreenHeight - 120, preferred))
}

; Resize the window to the measured content, bounded by MinHeight/MaxHeight.
; Skipped once the user has sized the window by hand.
FitTextToolWindow(batch, clientHeight) {
    if batch.UserSized
        return
    target := ClampPopupHeight(batch, batch.TotalHeight + batch.HeaderHeight)
    if Abs(target - clientHeight) <= 2
        return
    batch.Gui.GetPos(,,, &outerHeight)
    batch.Gui.GetClientPos(,,, &innerHeight)
    ; Move() takes the outer height; grow the target by the frame and caption.
    batch.AutoHeight := target
    batch.Gui.Move(,,, target + (outerHeight - innerHeight))
}

ScrollTextTools(wParam, lParam, msg, hwnd) {
    global TextToolViews
    if !TextToolViews.Has(hwnd) || lParam
        return
    batch := TextToolViews[hwnd]
    code := wParam & 0xFFFF
    position := batch.Scroll
    if code = 0
        position -= 48
    else if code = 1
        position += 48
    else if code = 2
        position -= batch.Height
    else if code = 3
        position += batch.Height
    else if code = 4 || code = 5 {
        info := Buffer(28, 0)
        NumPut("uint", 28, "uint", 0x10, info)
        DllCall("GetScrollInfo", "ptr", hwnd, "int", 1, "ptr", info)
        position := NumGet(info, 24, "int")
    } else if code = 6
        position := 0
    else if code = 7
        position := batch.TotalHeight
    batch.Scroll := Max(0, Min(position, batch.TotalHeight - batch.Height))
    LayoutTextTools(batch, batch.Width, batch.Height)
    return 0
}

WheelTextTools(wParam, lParam, msg, hwnd) {
    global TextToolViews
    if !TextToolViews.Has(hwnd) {
        hwnd := DllCall("GetParent", "ptr", hwnd, "ptr")
        if !TextToolViews.Has(hwnd)
            return
    }
    delta := (wParam >> 16) & 0xFFFF
    if delta >= 0x8000
        delta -= 0x10000
    return ScrollTextTools(delta > 0 ? 0 : 1, 0, 0x115, hwnd)
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

ShowStaticPopup(title, content) {
    ui := GetPopupUiConfig()
    windowFlags := ui.AlwaysOnTop ? "+AlwaysOnTop " : ""
    popup := Gui(windowFlags "+Resize", title)
    popup.SetFont("s" ui.FontSize, ui.FontName)
    edit := popup.Add("Edit", "w650 h260 ReadOnly", content)
    popup.OnEvent("Size", (g, state, w, h) => edit.Move(12, 12, Max(40, w - 24), Max(40, h - 24)))
    popup.OnEvent("Close", (*) => CloseStaticTextPopup(popup))
    popup.OnEvent("Escape", (*) => CloseStaticTextPopup(popup))
    RegisterTextToolTheme({Gui: popup, Hwnd: popup.Hwnd, Ui: ui, StaticEdit: edit})
    popup.Show()
    return popup
}

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

TextToolSearchCursor(wParam, lParam, *) {
    global TextToolBatches
    if (lParam & 0xFFFF) != 1 ; HTCLIENT: leave window borders alone
        return
    root := DllCall("GetAncestor", "ptr", wParam, "uint", 2, "ptr")
    if !TextToolBatches.Has(root)
        return
    window := TextToolBatches[root]
    if !window.HasOwnProp("SearchBackground")
        return
    ; The transparent background reports the window beneath it: the Edit where they
    ; overlap, else the Gui. Bound the Gui case or the whole client area gets the I-beam.
    if wParam = window.Hwnd {
        if !TextToolPointInControl(window.SearchBackground.Hwnd)
            return
    } else if wParam != window.SearchBackground.Hwnd && wParam != window.Search.Hwnd
        return
    static cursor := DllCall("LoadCursorW", "ptr", 0, "ptr", 32513, "ptr") ; IDC_IBEAM, shared
    DllCall("SetCursor", "ptr", cursor, "ptr")
    return true
}

; For a control that hit-tests transparent and so never reports itself.
TextToolPointInControl(hwnd) {
    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point)
        return false
    rect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect)
        return false
    x := NumGet(point, 0, "int"), y := NumGet(point, 4, "int")
    return x >= NumGet(rect, 0, "int") && x < NumGet(rect, 8, "int")
        && y >= NumGet(rect, 4, "int") && y < NumGet(rect, 12, "int")
}

TextToolInputLineHeight(hwnd) {
    ; Single-line Edit has no vertical alignment option. Center a font-height
    ; native Edit over a full-height background, keeping its input semantics.
    dc := DllCall("GetDC", "ptr", hwnd, "ptr")
    font := SendMessage(0x31, 0, 0, hwnd)
    previous := DllCall("SelectObject", "ptr", dc, "ptr", font, "ptr")
    try {
        metrics := Buffer(60, 0)
        if !DllCall("GetTextMetricsW", "ptr", dc, "ptr", metrics)
            throw Error("Could not measure the text input font.")
        return NumGet(metrics, 0, "int")
    } finally {
        DllCall("SelectObject", "ptr", dc, "ptr", previous, "ptr")
        DllCall("ReleaseDC", "ptr", hwnd, "ptr", dc)
    }
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

CloseStaticTextPopup(popup) {
    global TextToolThemeWindows
    if TextToolThemeWindows.Has(popup.Hwnd)
        TextToolThemeWindows.Delete(popup.Hwnd)
    popup.Destroy()
}

; Not HOME: it is not a Windows convention and may differ from USERPROFILE.
GetConfigRoot() {
    return EnvGet("USERPROFILE") "\.config"
}
