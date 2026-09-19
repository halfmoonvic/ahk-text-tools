<#
.SYNOPSIS
    Annotates Japanese text with kana readings.

.DESCRIPTION
    Wraps the bundled kana/kana.mjs converter, which uses kuroshiro and
    kuromoji. Node.js and the vendored dictionary files must be present;
    deploy.ps1 installs them.

    Reading direction and output style come from the japanese.kana section of
    ~/.config/ahk/settings.json, falling back to hiragana furigana.

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

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Write-KanaOutput <Content>
#   Write the result to OutputFile, or to the pipeline when none was given.
# ---------------------------------------------------------------------------
function Write-KanaOutput {
    param([string] $Content)

    if ($OutputFile) {
        [IO.File]::WriteAllText($OutputFile, $Content, $Utf8NoBom)
    } else {
        Write-Output $Content
    }
}

# ---------------------------------------------------------------------------
# Get-KanaConfigValue <Object> <Name> <Default>
#   Read one property, substituting Default when the object, the property, or
#   its value is missing or empty.
# ---------------------------------------------------------------------------
function Get-KanaConfigValue {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Default
    )

    if ($null -eq $Object) {
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or $prop.Value -eq '') {
        return $Default
    }

    return $prop.Value
}

# ---------------------------------------------------------------------------
# Get-KanaConfig
#   Load the japanese.kana settings. Any missing file or unreadable JSON falls
#   back to the defaults: annotation is more useful than an error here.
# ---------------------------------------------------------------------------
function Get-KanaConfig {
    $default = [pscustomobject]@{
        to = 'hiragana'
        mode = 'furigana'
    }
    # Duplicated from Config.ps1: this script does not import the module.
    $configPath = Join-Path $env:USERPROFILE '.config\ahk\settings.json'

    if (!(Test-Path -LiteralPath $configPath)) {
        return $default
    }

    try {
        $root = (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        return $default
    }

    $japanese = Get-KanaConfigValue $root 'japanese' $null
    $kana = Get-KanaConfigValue $japanese 'kana' $default

    return [pscustomobject]@{
        to = Get-KanaConfigValue $kana 'to' $default.to
        mode = Get-KanaConfigValue $kana 'mode' $default.mode
    }
}

if ($InputFile) {
    $Text = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($Text)) {
    exit 0
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) {
    throw 'Node.js is required for Japanese kana annotation, but node was not found on PATH.'
}

$toolRoot = Join-Path $ScriptRoot 'kana'
$scriptPath = Join-Path $toolRoot 'kana.mjs'
$vendorRoot = Join-Path $toolRoot 'vendor'
$kuroshiroPath = Join-Path $vendorRoot 'kuroshiro.min.js'
$kuromojiPath = Join-Path $vendorRoot 'kuromoji.js'
$dictPath = Join-Path $vendorRoot 'dict'

if (!(Test-Path -LiteralPath $scriptPath)) {
    throw "Japanese kana converter script not found: $scriptPath"
}

if (!(Test-Path -LiteralPath $kuroshiroPath) -or
    !(Test-Path -LiteralPath $kuromojiPath) -or
    !(Test-Path -LiteralPath $dictPath)) {
    throw "Japanese kana vendor files are missing under $vendorRoot."
}

$kanaConfig = Get-KanaConfig
$to = $kanaConfig.to
$mode = $kanaConfig.mode

$tempInput = $null
$tempOutput = $null

try {
    # Text goes through files so the shell never has to quote it.
    $tempInput = [IO.Path]::GetTempFileName()
    $tempOutput = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tempInput, $Text, $Utf8NoBom)

    # kuromoji resolves its dictionary relative to the working directory.
    Push-Location $toolRoot
    try {
        & $node.Source $scriptPath --input $tempInput --output $tempOutput --to $to --mode $mode
        if ($LASTEXITCODE -ne 0) {
            throw "Japanese kana converter failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    $result = [IO.File]::ReadAllText($tempOutput, [Text.Encoding]::UTF8)
    Write-KanaOutput $result
} finally {
    if ($tempInput -and (Test-Path -LiteralPath $tempInput)) {
        Remove-Item -LiteralPath $tempInput -Force
    }

    if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
        Remove-Item -LiteralPath $tempOutput -Force
    }
}
