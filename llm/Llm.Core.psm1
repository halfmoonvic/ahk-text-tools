# Llm.Core.psm1 - Module entry point for streaming one prompt through a model.
#
# Imported by the tool modules that offer AI engines. Invoke-LlmStream is the
# only exported command; it knows nothing about what the prompt asks for.
#
# The lib and adapter files are dot-sourced rather than made into nested
# modules so they share one scope: the adapters call helpers from Json.ps1 and
# Sse.ps1 directly, and Sse.ps1 dispatches back into the adapters by name.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Order matters: Json.ps1 defines the classes the rest parse against, and the
# adapters must exist before Sse.ps1 dispatches to them.
foreach ($file in @(
    '../common/Json.ps1',
    '../common/Process.ps1',
    '../common/Config.ps1',
    'lib/Config.ps1',
    'lib/Sse.ps1',
    'adapters/OpenAICompletions.ps1',
    'adapters/OpenAIResponses.ps1',
    'adapters/AnthropicMessages.ps1',
    'lib/Curl.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}

# ---------------------------------------------------------------------------
# Invoke-LlmStream -ConfigDirectory <Directory> -Model <Model>
#                  -SystemPrompt <SystemPrompt> -Prompt <Prompt>
#                  [-OutputFile] [-CancellationToken]
#   Send Prompt to Model, a provider/model identifier configured in
#   ConfigDirectory, and stream the response text to OutputFile, or to stdout
#   when OutputFile is empty. OutputFile must already be a full path.
# ---------------------------------------------------------------------------
function Invoke-LlmStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $ConfigDirectory,
        [Parameter(Mandatory=$true)][string] $Model,
        [Parameter(Mandatory=$true)][string] $SystemPrompt,
        [Parameter(Mandatory=$true)][string] $Prompt,
        [string] $OutputFile,
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )

    $config = Get-LlmConfig $ConfigDirectory $Model
    $request = switch ($config.Api) {
        'openai-completions' { New-OpenAICompletionsRequest $config $SystemPrompt $Prompt }
        'openai-responses' { New-OpenAIResponsesRequest $config $SystemPrompt $Prompt }
        'anthropic-messages' { New-AnthropicMessagesRequest $config $SystemPrompt $Prompt }
    }

    Invoke-CurlSse $config $request $OutputFile $CancellationToken
}

Export-ModuleMember -Function Invoke-LlmStream
