# OpenAIResponses.ps1 - Request building and event handling for the OpenAI
# Responses API.
#
# Dot-sourced by Translate.Core.psm1 and selected when a provider declares
# api = 'openai-responses' in models.json.

# ---------------------------------------------------------------------------
# New-OpenAIResponsesRequest <Config> <Prompt>
#   Build the URL, JSON body, and headers for one streaming request.
#
#   store = false keeps the prompt from being retained server-side, since
#   translated text is the user's own content.
# ---------------------------------------------------------------------------
function New-OpenAIResponsesRequest($Config, [string] $Prompt) {
    # baseUrl may already name the endpoint, so append only when needed.
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if (-not $endpoint.EndsWith('/responses', [StringComparison]::Ordinal)) {
        $endpoint += '/responses'
    }

    # This API spells "thinking off" as reasoning.effort = none.
    $effort =
        if ($Config.Thinking -eq 'off') {
            'none'
        } else {
            $Config.Thinking
        }

    $body = [ordered]@{
        model = $Config.Model
        instructions = $Config.SystemPrompt
        input = $Prompt
        reasoning = @{ effort = $effort }
        stream = $true
        store = $false
    }

    return @{
        Url = $endpoint
        Body = (ConvertTo-StrictJson $body)
        Headers = @(
            'Content-Type: application/json',
            "Authorization: Bearer $($Config.ApiKey)"
        )
    }
}

# ---------------------------------------------------------------------------
# Receive-OpenAIResponsesEvent <State> <Node>
#   Handle one decoded SSE event. This API names its terminal states
#   explicitly, so completion needs no [DONE] sentinel.
# ---------------------------------------------------------------------------
function Receive-OpenAIResponsesEvent($State, $Node) {
    $type = Get-JsonString (Get-JsonMember $Node 'type')
    switch -CaseSensitive ($type) {
        'response.failed' { Set-StreamFailure $State 'response.failed' }
        'response.incomplete' { Set-StreamFailure $State 'response.incomplete' }
        'response.output_text.delta' { Write-TranslationDelta $State (Get-JsonMember $Node 'delta') }
        'response.completed' { Complete-TranslationStream $State }
    }
}
