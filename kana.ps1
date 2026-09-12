param(
    [string]$Text,
    [string]$InputFile,
    [string]$OutputFile
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-KanaOutput {
    param([string]$Content)

    if ($OutputFile) {
        [System.IO.File]::WriteAllText($OutputFile, $Content, $Utf8NoBom)
    } else {
        Write-Output $Content
    }
}

function Get-KanaConfigValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default
    )

    if ($null -eq $Object) {
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value -or $prop.Value -eq "") {
        return $Default
    }

    return $prop.Value
}

function Get-KanaConfig {
    $default = [pscustomobject]@{
        to = "hiragana"
        mode = "furigana"
    }
    $homeDirectory = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $configPath = Join-Path $homeDirectory ".config\ahk\config.json"

    if (!(Test-Path -LiteralPath $configPath)) {
        return $default
    }

    try {
        $root = (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        return $default
    }

    $japanese = Get-KanaConfigValue $root "japanese" $null
    $kana = Get-KanaConfigValue $japanese "kana" $default

    return [pscustomobject]@{
        to = Get-KanaConfigValue $kana "to" $default.to
        mode = Get-KanaConfigValue $kana "mode" $default.mode
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
    throw "Node.js is required for Japanese kana annotation, but node was not found on PATH."
}

$toolRoot = Join-Path $ScriptRoot "kana"
$scriptPath = Join-Path $toolRoot "kana.mjs"
$vendorRoot = Join-Path $toolRoot "vendor"
$kuroshiroPath = Join-Path $vendorRoot "kuroshiro.min.js"
$kuromojiPath = Join-Path $vendorRoot "kuromoji.js"
$dictPath = Join-Path $vendorRoot "dict"

if (!(Test-Path -LiteralPath $scriptPath)) {
    throw "Japanese kana converter script not found: $scriptPath"
}

if (!(Test-Path -LiteralPath $kuroshiroPath) -or !(Test-Path -LiteralPath $kuromojiPath) -or !(Test-Path -LiteralPath $dictPath)) {
    throw "Japanese kana vendor files are missing under $vendorRoot."
}

$kanaConfig = Get-KanaConfig
$to = $kanaConfig.to
$mode = $kanaConfig.mode

$tempInput = $null
$tempOutput = $null

try {
    $tempInput = [System.IO.Path]::GetTempFileName()
    $tempOutput = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempInput, $Text, $Utf8NoBom)

    Push-Location $toolRoot
    try {
        & $node.Source $scriptPath --input $tempInput --output $tempOutput --to $to --mode $mode
        if ($LASTEXITCODE -ne 0) {
            throw "Japanese kana converter failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    $result = [System.IO.File]::ReadAllText($tempOutput, [System.Text.Encoding]::UTF8)
    Write-KanaOutput $result
} finally {
    if ($tempInput -and (Test-Path -LiteralPath $tempInput)) {
        Remove-Item -LiteralPath $tempInput -Force
    }

    if ($tempOutput -and (Test-Path -LiteralPath $tempOutput)) {
        Remove-Item -LiteralPath $tempOutput -Force
    }
}
