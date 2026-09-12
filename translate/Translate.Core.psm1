Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
foreach ($file in @('lib/Json.ps1','lib/Config.ps1','lib/Sse.ps1','adapters/OpenAICompletions.ps1','adapters/OpenAIResponses.ps1','adapters/AnthropicMessages.ps1','lib/Curl.ps1','lib/Google.ps1')) { . (Join-Path $PSScriptRoot $file) }

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
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'no input text provided' }
    if ($Mode -eq 'google') {
        if (-not [string]::IsNullOrEmpty($Model)) { throw 'google does not accept Model' }
        $common = Get-TranslateCommonConfig
        if ($Target -eq 'auto') { $Target = Get-DetectedTarget $Text $common.Threshold }
        if ($OutputFile) { $OutputFile = Resolve-TranslateFilePath $OutputFile }
        Invoke-GoogleTranslate $Text $Target $OutputFile $common $CancellationToken
        return
    }
    $config = Get-TranslateConfig $Model
    if ($Target -eq 'auto') { $Target = Get-DetectedTarget $Text $config.Threshold }
    $language = if ($Target -eq 'en') { 'English' } else { 'Simplified Chinese' }
    $prompt = "Translate the following text into $language. Output only the translated text.`n`n$Text"
    $request = switch ($config.Api) {
        'openai-completions' { New-OpenAICompletionsRequest $config $prompt }
        'openai-responses' { New-OpenAIResponsesRequest $config $prompt }
        'anthropic-messages' { New-AnthropicMessagesRequest $config $prompt }
    }
    if ($OutputFile) { $OutputFile = Resolve-TranslateFilePath $OutputFile }
    Invoke-CurlSse $config $request $OutputFile $CancellationToken
}
Export-ModuleMember -Function Invoke-Translate
