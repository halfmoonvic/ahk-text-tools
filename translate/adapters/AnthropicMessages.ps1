# AnthropicMessages.ps1 - Request building and event handling for the Anthropic
# Messages API.
#
# Dot-sourced by Translate.Core.psm1 and selected when a provider declares
# api = 'anthropic-messages' in models.json.

# ---------------------------------------------------------------------------
# New-AnthropicMessagesRequest <Config> <Prompt>
#   Build the URL, JSON body, and headers for one streaming request.
#
#   Thinking mode replaces temperature with a token budget: the API rejects
#   both together, and max_tokens must leave room for the answer on top of the
#   thinking budget.
# ---------------------------------------------------------------------------
function New-AnthropicMessagesRequest($Config, [string] $Prompt) {
    # baseUrl may be given with or without the /v1 prefix.
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if ($endpoint.EndsWith('/v1/messages', [StringComparison]::Ordinal)) {
        # Already complete.
    } elseif ($endpoint.EndsWith('/v1', [StringComparison]::Ordinal)) {
        $endpoint += '/messages'
    } else {
        $endpoint += '/v1/messages'
    }

    $body = [ordered]@{
        model = $Config.Model
        max_tokens = 4096
        system = $Config.SystemPrompt
        messages = @(@{ role = 'user'; content = $Prompt })
        stream = $true
    }

    if ($Config.Thinking -eq 'off') {
        $body['temperature'] = $Config.Temperature
    } else {
        $budget = @{ low = 1024; medium = 4096; high = 8192 }[$Config.Thinking]
        $body['max_tokens'] = $budget + 4096
        $body['thinking'] = @{ type = 'enabled'; budget_tokens = $budget }
    }

    return @{
        Url = $endpoint
        Body = (ConvertTo-StrictJson $body)
        Headers = @(
            'Content-Type: application/json',
            "x-api-key: $($Config.ApiKey)",
            'anthropic-version: 2023-06-01'
        )
    }
}

# ---------------------------------------------------------------------------
# Receive-AnthropicMessagesEvent <State> <Node>
#   Handle one decoded SSE event.
#
#   Completion takes two events: message_delta carries the stop_reason that
#   must be accepted, and only a later message_stop ends the stream. A
#   message_stop without an accepted stop_reason means the response was cut
#   short, so it is a failure rather than a success.
# ---------------------------------------------------------------------------
function Receive-AnthropicMessagesEvent($State, $Node) {
    $type = Get-JsonString (Get-JsonMember $Node 'type')
    $delta = Get-JsonMember $Node 'delta'

    # Thinking deltas arrive on this same event with a different delta type and
    # are deliberately not written to the output.
    if ($type -ceq 'content_block_delta' -and
        (Get-JsonString (Get-JsonMember $delta 'type')) -ceq 'text_delta') {
        Write-TranslationDelta $State (Get-JsonMember $delta 'text')
    }

    if ($type -ceq 'message_delta') {
        $reason = Get-JsonMember $delta 'stop_reason'
        if ($null -ne $reason -and $reason.Kind -ne 'null') {
            if ($reason.Kind -ne 'string' -or $reason.Value -cnotin @('end_turn', 'stop_sequence')) {
                Set-StreamFailure $State 'unaccepted stop_reason'
                return
            }

            $State.Finished = $true
        }
    }

    if ($type -ceq 'message_stop') {
        if (-not $State.Finished) {
            Set-StreamFailure $State 'message_stop without accepted stop_reason'
        } else {
            Complete-TranslationStream $State
        }
    }
}
