ReadTextToolConfig() {
    path := GetConfigRoot() "\settings.json"
    if !FileExist(path)
        return Map()
    config := Json.Parse(FileRead(path, "UTF-8"))
    if !(config is Map)
        throw Error("Text tools configuration must be a JSON object.")
    return config
}

; A tool without an engine list runs one empty engine name, which the tool's
; core resolves to its own default. Names are checked only by the core.
GetTextToolEngines(config, id) {
    if !config.Has("engines")
        return [""]
    if !(config["engines"] is Map)
        throw Error("settings.json: engines must be an object.")
    if !config["engines"].Has(id)
        return [""]
    engines := config["engines"][id]
    if !(engines is Array) || !engines.Length
        throw Error("settings.json: engines." id " must be a nonempty array of engine names.")
    ; run-batch.ps1 reads the names one per line.
    for engine in engines {
        if Type(engine) != "String" || Trim(engine) = "" || RegExMatch(engine, "[\r\n]")
            throw Error("settings.json: each engines." id " entry must be a nonempty single-line string.")
    }
    return engines
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

; Must match Get-ConfigDirectory in common\Config.ps1.
; Not HOME: it is not a Windows convention and may differ from USERPROFILE.
GetConfigRoot() {
    directory := EnvGet("TEXT_TOOLS_CONFIG_DIR")
    return directory != "" ? directory : EnvGet("USERPROFILE") "\.config\text-tools"
}
