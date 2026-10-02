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
