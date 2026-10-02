<#
.SYNOPSIS
    Annotates Japanese text with kana readings.

.DESCRIPTION
    Runs the kana tool in kana\Kana.Core.psm1, which wraps the bundled
    kana/kana.mjs converter (kuroshiro and kuromoji). Node.js and the vendored
    dictionary files must be present; deploy.ps1 installs them.

    Reading direction and output style come from the kana section of
    ~/.config/text-tools/config.json, falling back to hiragana furigana.

.EXAMPLE
    .\kana.ps1 -Text '<japanese text>'
    Write the annotated text to stdout.

.EXAMPLE
    .\kana.ps1 -InputFile in.txt -OutputFile out.txt
    Read from a file and write the result to another.
#>
param(
    [string] $Text,
    [string] $InputFile,
    [string] $OutputFile
)

if ($InputFile) {
    $Text = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($Text)) {
    exit 0
}

Import-Module (Join-Path $PSScriptRoot 'kana\Kana.Core.psm1') -Force -ErrorAction Stop
Invoke-Kana -Text $Text -OutputFile $OutputFile
