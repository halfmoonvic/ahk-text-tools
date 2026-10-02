# Config.ps1 - Loading and validating the kana settings.
#
# Dot-sourced by Kana.Core.psm1. The settings read here are the kana section
# of config.json in Get-ConfigDirectory.

# ---------------------------------------------------------------------------
# Get-KanaConfig
#   Return the reading script (To) and output style (Mode) for kana.mjs. A
#   missing kana section, or a missing or null key in it, takes the default
#   of hiragana furigana; any other value must be one of the allowed names.
# ---------------------------------------------------------------------------
function Get-KanaConfig {
    $settings = Read-JsonConfigFile (Join-Path (Get-ConfigDirectory) 'config.json')
    $section = Get-ConfigSection $settings 'kana'

    return [pscustomobject]@{
        To   = Get-KanaOption $section 'to' @('hiragana', 'katakana', 'romaji')
        Mode = Get-KanaOption $section 'mode' @('furigana', 'ruby')
    }
}

# ---------------------------------------------------------------------------
# Get-KanaOption <Section> <Name> <Allowed>
#   Return kana.<Name>, or the first of Allowed when it is missing or null.
# ---------------------------------------------------------------------------
function Get-KanaOption($Section, [string] $Name, [string[]] $Allowed) {
    $node = Get-JsonMember $Section $Name
    if ($null -eq $node -or $node.Kind -eq 'null') {
        return $Allowed[0]
    }

    if ($node.Kind -ne 'string' -or $node.Value -cnotin $Allowed) {
        $names = ($Allowed[0..($Allowed.Count - 2)] -join ', ') + ' or ' + $Allowed[-1]
        throw "kana.$Name must be $names"
    }

    return [string]$node.Value
}
