# A version-independent JSON tree: numbers keep their original token and object
# dictionaries use ordinal (case-sensitive) keys. No ConvertFrom-Json dependency.
class TranslateJsonNode {
    [string] $Kind
    [object] $Value
    TranslateJsonNode([string] $kind, [object] $value) { $this.Kind = $kind; $this.Value = $value }
}

class TranslateJsonParser {
    [string] $Source
    [int] $Index
    [int] $Depth
    TranslateJsonParser([string] $source) { $this.Source = $source }
    [void] Fail([string] $message) { throw [FormatException]::new("invalid JSON: $message at character $($this.Index)") }
    [void] WhiteSpace() {
        while ($this.Index -lt $this.Source.Length -and " `t`r`n".IndexOf($this.Source[$this.Index]) -ge 0) { $this.Index++ }
    }
    [bool] Take([char] $character) {
        $this.WhiteSpace()
        if ($this.Index -lt $this.Source.Length -and $this.Source[$this.Index] -ceq $character) { $this.Index++; return $true }
        return $false
    }
    [string] String() {
        if (-not $this.Take('"')) { $this.Fail('expected string') }
        $value = [Text.StringBuilder]::new()
        $closed = $false
        while ($this.Index -lt $this.Source.Length) {
            $ch = $this.Source[$this.Index]; $this.Index++
            if ($ch -ceq '"') { $closed = $true; break }
            if ([int]$ch -lt 32) { $this.Fail('unescaped control character') }
            if ($ch -ceq '\') {
                if ($this.Index -ge $this.Source.Length) { $this.Fail('incomplete escape') }
                $ch = $this.Source[$this.Index]; $this.Index++
                switch -CaseSensitive ($ch) {
                    '"' { [void]$value.Append('"') }
                    '\' { [void]$value.Append('\') }
                    '/' { [void]$value.Append('/') }
                    'b' { [void]$value.Append([char]8) }
                    'f' { [void]$value.Append([char]12) }
                    'n' { [void]$value.Append([char]10) }
                    'r' { [void]$value.Append([char]13) }
                    't' { [void]$value.Append([char]9) }
                    'u' {
                        if ($this.Index + 4 -gt $this.Source.Length) { $this.Fail('incomplete Unicode escape') }
                        $hex = $this.Source.Substring($this.Index, 4)
                        if ($hex -cnotmatch '^[0-9a-fA-F]{4}$') { $this.Fail('invalid Unicode escape') }
                        [void]$value.Append([char][Convert]::ToInt32($hex,16)); $this.Index += 4
                    }
                    default { $this.Fail('invalid escape') }
                }
            } else { [void]$value.Append($ch) }
        }
        if (-not $closed) { $this.Fail('unterminated string') }
        $result = $value.ToString()
        for ($i = 0; $i -lt $result.Length; $i++) {
            if ([char]::IsHighSurrogate($result[$i])) {
                $i++
                if ($i -ge $result.Length -or -not [char]::IsLowSurrogate($result[$i])) { $this.Fail('missing low surrogate') }
            } elseif ([char]::IsLowSurrogate($result[$i])) { $this.Fail('unexpected low surrogate') }
        }
        return $result
    }
    [TranslateJsonNode] ValueNode() {
        $this.WhiteSpace(); $this.Depth++
        if ($this.Depth -gt 256) { $this.Fail('maximum nesting depth exceeded') }
        if ($this.Index -ge $this.Source.Length) { $this.Fail('expected value') }
        $node = $null
        $ch = $this.Source[$this.Index]
        if ($ch -ceq '{') {
            $this.Index++
            $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            if (-not $this.Take('}')) {
                do {
                    $key = $this.String()
                    if ($map.ContainsKey($key)) { $this.Fail('duplicate object key') }
                    if (-not $this.Take(':')) { $this.Fail('expected colon') }
                    $map.Add($key, $this.ValueNode())
                    if ($this.Take('}')) { break }
                    if (-not $this.Take(',')) { $this.Fail('expected comma or closing brace') }
                } while ($true)
            }
            $node = [TranslateJsonNode]::new('object', $map)
        } elseif ($ch -ceq '[') {
            $this.Index++; $items = [Collections.Generic.List[object]]::new()
            if (-not $this.Take(']')) {
                do {
                    $items.Add($this.ValueNode())
                    if ($this.Take(']')) { break }
                    if (-not $this.Take(',')) { $this.Fail('expected comma or closing bracket') }
                } while ($true)
            }
            $node = [TranslateJsonNode]::new('array', $items)
        } elseif ($ch -ceq '"') { $node = [TranslateJsonNode]::new('string', $this.String()) }
        else {
            $start = $this.Index
            while ($this.Index -lt $this.Source.Length -and ",}] `t`r`n".IndexOf($this.Source[$this.Index]) -lt 0) { $this.Index++ }
            $token = $this.Source.Substring($start, $this.Index - $start)
            switch -CaseSensitive ($token) {
                'true' { $node = [TranslateJsonNode]::new('boolean', $true) }
                'false' { $node = [TranslateJsonNode]::new('boolean', $false) }
                'null' { $node = [TranslateJsonNode]::new('null', $null) }
                default {
                    if ($token -cnotmatch '\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z') { $this.Fail('invalid value or number') }
                    $node = [TranslateJsonNode]::new('number', $token)
                }
            }
        }
        $this.Depth--; return $node
    }
    [TranslateJsonNode] Parse() {
        $node = $this.ValueNode(); $this.WhiteSpace()
        if ($this.Index -ne $this.Source.Length) { $this.Fail('trailing content') }
        return $node
    }
}

function ConvertFrom-StrictJson([string] $Text) { return [TranslateJsonParser]::new($Text).Parse() }
function Get-JsonMember($Node, [string] $Key) {
    if ($null -ne $Node -and $Node.Kind -eq 'object' -and $Node.Value.ContainsKey($Key)) { return $Node.Value[$Key] }
    return $null
}
function Get-JsonString($Node, [string] $Default = '') {
    if ($null -ne $Node -and $Node.Kind -eq 'string') { return [string]$Node.Value }
    return $Default
}
function ConvertTo-JsonString([AllowEmptyString()][string] $Text) {
    $result = [Text.StringBuilder]::new(); [void]$result.Append('"')
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ([char]::IsHighSurrogate($ch)) {
            if ($i + 1 -ge $Text.Length -or -not [char]::IsLowSurrogate($Text[$i+1])) { throw 'invalid Unicode surrogate in string' }
            [void]$result.Append($ch); $i++; [void]$result.Append($Text[$i]); continue
        }
        if ([char]::IsLowSurrogate($ch)) { throw 'invalid Unicode surrogate in string' }
        if ($ch -ceq '"') { [void]$result.Append('\"') }
        elseif ($ch -ceq '\') { [void]$result.Append('\\') }
        elseif ([int]$ch -lt 32) { [void]$result.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$result.Append($ch) }
    }
    [void]$result.Append('"'); return $result.ToString()
}
function ConvertTo-StrictJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [TranslateJsonNode]) {
        switch ($Value.Kind) {
            'number' { return $Value.Value }
            'null' { return 'null' }
            default { return ConvertTo-StrictJson $Value.Value }
        }
    }
    if ($Value -is [string]) { return ConvertTo-JsonString $Value }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in $Value.Keys) { (ConvertTo-JsonString $key) + ':' + (ConvertTo-StrictJson $Value[$key]) }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $values = foreach ($item in $Value) { ConvertTo-StrictJson $item }
        return '[' + ($values -join ',') + ']'
    }
    if ($Value -is [int] -or $Value -is [long]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    throw 'unsupported JSON value type'
}
