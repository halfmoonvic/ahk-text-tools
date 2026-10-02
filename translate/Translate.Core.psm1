# Translate.Core.psm1 - Module entry point for the translate tool.
#
# Imported by translate.ps1 and by the AutoHotkey front-end through
# run-batch.ps1. Invoke-Translate is the only exported command.
#
# AI mode goes through the llm module. It loads its own copy of the common
# files, so only strings and plain objects may cross into it, never a parsed
# JSON node: the two copies define separate StrictJsonNode types.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Order matters: Json.ps1 defines the classes the rest parse against.
foreach ($file in @(
    '../common/Json.ps1',
    '../common/Process.ps1',
    '../common/Config.ps1',
    'lib/Config.ps1',
    'lib/Google.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}

Import-Module (Join-Path $PSScriptRoot '../llm/Llm.Core.psm1') -ErrorAction Stop

# ---------------------------------------------------------------------------
# Invoke-Translate -Text <Text> [-OutputFile] [-Model] [-Mode] [-Target]
#                  [-CancellationToken]
#   Translate Text and stream the result to OutputFile, or to stdout when
#   OutputFile is empty.
#
#   Mode 'ai' goes through a configured provider; 'google' shells out to the
#   vendored Translate Shell script and accepts no Model. Target 'auto' picks
#   the direction from the ratio of Chinese to Latin characters in Text.
# ---------------------------------------------------------------------------
function Invoke-Translate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $Text,
        [string] $OutputFile,
        [string] $Model,
        [ValidateSet('ai','google')][string] $Mode = 'ai',
        [ValidateSet('auto','zh','en')][string] $Target = 'auto',
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'no input text provided'
    }

    if ($Mode -eq 'google') {
        if (-not [string]::IsNullOrEmpty($Model)) {
            throw 'google does not accept Model'
        }

        $common = Get-TranslateCommonConfig
        if ($Target -eq 'auto') {
            $Target = Get-DetectedTarget $Text $common.Threshold
        }

        if ($OutputFile) {
            $OutputFile = Resolve-FileSystemPath $OutputFile
        }

        Invoke-GoogleTranslate $Text $Target $OutputFile $common $CancellationToken
        return
    }

    $common = Get-TranslateCommonConfig
    $settings = Get-TranslateAiSettings $common $Model
    if ($Target -eq 'auto') {
        $Target = Get-DetectedTarget $Text $common.Threshold
    }

    $language =
        if ($Target -eq 'en') {
            'English'
        } else {
            'Simplified Chinese'
        }
    $prompt = New-TranslatePrompt $settings.UserPrompt $language $Text

    if ($OutputFile) {
        $OutputFile = Resolve-FileSystemPath $OutputFile
    }

    Invoke-LlmStream -Model $settings.Model `
        -SystemPrompt $settings.SystemPrompt -Prompt $prompt `
        -OutputFile $OutputFile -CancellationToken $CancellationToken
}

# ---------------------------------------------------------------------------
# New-TranslatePrompt <Template> <Language> <Text>
#   Fill {language} in Template and append Text as a <text> block. The block
#   is always added here rather than by the template, so the escaping below
#   matches the tag the model actually sees.
# ---------------------------------------------------------------------------
function New-TranslatePrompt([string] $Template, [string] $Language, [string] $Text) {
    # Text is appended only after the template is filled, so a {language}
    # inside the selection is left alone.
    $instruction = $Template.Replace('{language}', $Language)
    # A closing tag inside the selection would end the block early.
    $wrapped = $Text -replace '(?i)</(text\s*>)', "$([char]0xFF1C)/`$1"
    return "$instruction`n`n<text>`n$wrapped`n</text>"
}

Export-ModuleMember -Function Invoke-Translate
