; Recursive JSON parser. Objects are Maps, arrays are Arrays; no code evaluation.
class Json {
    static Parse(text) {
        parser := Json(text)
        value := parser.Value()
        parser.Space()
        if parser.Pos <= StrLen(text)
            throw Error("Unexpected text after JSON value")
        return value
    }
    __New(text) {
        this.Text := text
        this.Pos := 1
        this.Depth := 0
    }
    Space() {
        while this.Pos <= StrLen(this.Text) && InStr(" `t`r`n", SubStr(this.Text, this.Pos, 1))
            this.Pos++
    }
    Value() {
        this.Space()
        if ++this.Depth > 256
            throw Error("JSON nesting exceeds 256 levels")
        try {
            ch := SubStr(this.Text, this.Pos, 1)
            if ch = Chr(34)
                return this.String()
            if ch = "{" || ch = "[" {
                objectValue := ch = "{"
                value := objectValue ? Map() : []
                if objectValue
                    value.CaseSense := true
                endChar := objectValue ? "}" : "]"
                this.Pos++
                this.Space()
                if SubStr(this.Text, this.Pos, 1) = endChar {
                    this.Pos++
                    return value
                }
                loop {
                    this.Space()
                    if objectValue {
                        key := this.String()
                        if value.Has(key)
                            throw Error("Duplicate JSON key: " key)
                        this.Space()
                        if SubStr(this.Text, this.Pos++, 1) != ":"
                            throw Error("Expected colon in JSON object")
                        value[key] := this.Value()
                    } else
                        value.Push(this.Value())
                    this.Space()
                    delimiter := SubStr(this.Text, this.Pos++, 1)
                    if delimiter = endChar
                        return value
                    if delimiter != ","
                        throw Error("Expected comma in JSON collection")
                }
            }
            for literal in ["true", "false", "null"] {
                if SubStr(this.Text, this.Pos, StrLen(literal)) == literal {
                    this.Pos += StrLen(literal)
                    return {JsonLiteral: literal}
                }
            }
            if RegExMatch(SubStr(this.Text, this.Pos), "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", &number) {
                this.Pos += StrLen(number[0])
                return number[0] + 0
            }
            throw Error("Invalid JSON value at position " this.Pos)
        } finally {
            this.Depth--
        }
    }
    String() {
        if SubStr(this.Text, this.Pos++, 1) != Chr(34)
            throw Error("Expected JSON string")
        result := ""
        while this.Pos <= StrLen(this.Text) {
            ch := SubStr(this.Text, this.Pos++, 1)
            if ch = Chr(34)
                return result
            if Ord(ch) < 32
                throw Error("Control character in JSON string")
            if ch = "\" {
                escape := SubStr(this.Text, this.Pos++, 1)
                if escape = "u" {
                    code := this.HexUnit()
                    if code >= 0xD800 && code <= 0xDBFF {
                        if SubStr(this.Text, this.Pos, 2) != "\u"
                            throw Error("Unpaired JSON surrogate")
                        this.Pos += 2
                        low := this.HexUnit()
                        if low < 0xDC00 || low > 0xDFFF
                            throw Error("Unpaired JSON surrogate")
                        code := 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00
                    } else if code >= 0xDC00 && code <= 0xDFFF
                        throw Error("Unpaired JSON surrogate")
                    if code = 0
                        throw Error("NUL is not supported in text tool configuration")
                    ch := Chr(code)
                } else {
                    escapes := Map(Chr(34), Chr(34), "\", "\", "/", "/", "b", Chr(8), "f", Chr(12), "n", "`n", "r", "`r", "t", "`t")
                    if !escapes.Has(escape)
                        throw Error("Invalid JSON escape")
                    ch := escapes[escape]
                }
            }
            result .= ch
        }
        throw Error("Unterminated JSON string")
    }
    HexUnit() {
        hex := SubStr(this.Text, this.Pos, 4)
        if !RegExMatch(hex, "^[0-9a-fA-F]{4}$")
            throw Error("Invalid JSON Unicode escape")
        this.Pos += 4
        return Integer("0x" hex)
    }
}
