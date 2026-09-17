# OpenAICompletions.ps1 - Request building and event handling for the OpenAI
# Chat Completions API.
#
# Dot-sourced by Translate.Core.psm1 and selected when a provider declares
# api = 'openai-completions' in models.json. Also used by OpenAI-compatible
# third-party endpoints such as DeepSeek.

# ---------------------------------------------------------------------------
# New-OpenAICompletionsRequest <Config> <Prompt>
#   Build the URL, JSON body, and headers for one streaming request.
# ---------------------------------------------------------------------------
function New-OpenAICompletionsRequest($Config, [string] $Prompt) {
    # baseUrl may already name the endpoint, so append only when needed.
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if (-not $endpoint.EndsWith('/chat/completions', [StringComparison]::Ordinal)) {
        $endpoint += '/chat/completions'
    }

    # This API spells "thinking off" as reasoning_effort = none.
    $effort =
        if ($Config.Thinking -eq 'off') {
            'none'
        } else {
            $Config.Thinking
        }

    $body = [ordered]@{
        model = $Config.Model
        messages = @(
            @{ role = 'system'; content = $Config.SystemPrompt },
            @{ role = 'user'; content = $Prompt }
        )
        temperature = $Config.Temperature
        reasoning_effort = $effort
        stream = $true
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
# Receive-OpenAICompletionsEvent <State> <Node>
#   Handle one decoded SSE event, appending any content delta to the output.
#
#   A finish_reason other than 'stop' means the response was truncated, so it
#   is treated as a failure. Setting Finished here only records that a valid
#   end arrived; the stream is completed later by the [DONE] sentinel.
# ---------------------------------------------------------------------------
function Receive-OpenAICompletionsEvent($State, $Node) {
    $choices = Get-JsonMember $Node 'choices'
    if ($null -eq $choices -or $choices.Kind -ne 'array' -or $choices.Value.Count -eq 0) {
        return
    }

    $choice = $choices.Value[0]
    Write-TranslationDelta $State (Get-JsonMember (Get-JsonMember $choice 'delta') 'content')

    # Absent, null, and empty all mean "not finished yet".
    $reason = Get-JsonMember $choice 'finish_reason'
    if ($null -ne $reason -and $reason.Kind -ne 'null' -and
        -not ($reason.Kind -eq 'string' -and $reason.Value -eq '')) {
        if ($reason.Kind -ne 'string' -or $reason.Value -cne 'stop') {
            Set-StreamFailure $State 'unaccepted finish_reason'
            return
        }

        $State.Finished = $true
    }
}
