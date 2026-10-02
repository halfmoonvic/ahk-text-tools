# Config.ps1 - Loading the kana settings.
#
# Dot-sourced by Kana.Core.psm1. The settings read here are the kana section
# of config.json in Get-ConfigDirectory.

# ---------------------------------------------------------------------------
# Get-KanaConfig
#   Return the reading script (To) and output style (Mode) for kana.mjs. Any
#   missing file, unreadable JSON or empty value falls back to hiragana
#   furigana: annotation is more useful than an error here.
# ---------------------------------------------------------------------------
function Get-KanaConfig {
    $section = $null
    try {
        $settings = Read-JsonConfigFile (Join-Path (Get-ConfigDirectory) 'config.json')
        $section = Get-JsonMember $settings 'kana'
    } catch {
    }

    $to = Get-JsonString (Get-JsonMember $section 'to')
    $mode = Get-JsonString (Get-JsonMember $section 'mode')
    return [pscustomobject]@{
        To   = $(if ($to) { $to } else { 'hiragana' })
        Mode = $(if ($mode) { $mode } else { 'furigana' })
    }
}
