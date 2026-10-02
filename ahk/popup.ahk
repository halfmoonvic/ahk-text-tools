StartTextToolBatch(action, engines, text, config) {
    Critical "On"
    ; Created here, not by CreateTextToolWindow, so a window that fails partway
    ; through construction can still be closed.
    batch := {Tasks: [], Open: true}
    try {
        CreateTextToolWindow(batch, action, engines, config)
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
        ShowStaticPopup(action.Title, err.Message)
    } finally {
        Critical "Off"
    }
}

CreateTextToolWindow(batch, action, engines, config) {
    global TextToolBatches, TextToolViews
    batch.Scroll := 0, batch.Current := 0, batch.Tool := action.Id, batch.Title := action.Title, batch.Engines := engines
    batch.HeaderHeight := 0, batch.UserSized := false, batch.AutoHeight := 0
    batch.Ui := GetPopupUiConfig(config)
    windowFlags := batch.Ui.AlwaysOnTop ? "+AlwaysOnTop " : ""
    batch.Gui := Gui(windowFlags "+Resize -DPIScale +MinSize420x240", action.Title)
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
        task.Label := batch.View.Add("Text", "x12 y12 w400 h32", engine != "" ? engine : batch.Title)
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

CopyTextTool(task, *) {
    A_Clipboard := task.Output
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

CloseStaticTextPopup(popup) {
    global TextToolThemeWindows
    if TextToolThemeWindows.Has(popup.Hwnd)
        TextToolThemeWindows.Delete(popup.Hwnd)
    popup.Destroy()
}
