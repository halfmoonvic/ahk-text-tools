function New-AnthropicMessagesRequest($Config, [string] $Prompt) {
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if ($endpoint.EndsWith('/v1/messages', [StringComparison]::Ordinal)) { }
    elseif ($endpoint.EndsWith('/v1', [StringComparison]::Ordinal)) { $endpoint += '/messages' }
    else { $endpoint += '/v1/messages' }
    $body = [ordered]@{ model=$Config.Model; max_tokens=4096; system=$Config.SystemPrompt; messages=@(@{role='user';content=$Prompt}); stream=$true }
    if ($Config.Thinking -eq 'off') { $body['temperature'] = $Config.Temperature }
    else {
        $budget = @{low=1024; medium=4096; high=8192}[$Config.Thinking]
        $body['max_tokens'] = $budget + 4096; $body['thinking'] = @{type='enabled'; budget_tokens=$budget}
    }
    return @{ Url=$endpoint; Body=(ConvertTo-StrictJson $body); Headers=@('Content-Type: application/json', "x-api-key: $($Config.ApiKey)", 'anthropic-version: 2023-06-01') }
}
function Receive-AnthropicMessagesEvent($State, $Node) {
    $type = Get-JsonString (Get-JsonMember $Node 'type'); $delta = Get-JsonMember $Node 'delta'
    if ($type -ceq 'content_block_delta' -and (Get-JsonString (Get-JsonMember $delta 'type')) -ceq 'text_delta') { Write-TranslationDelta $State (Get-JsonMember $delta 'text') }
    if ($type -ceq 'message_delta') {
        $reason = Get-JsonMember $delta 'stop_reason'
        if ($null -ne $reason -and $reason.Kind -ne 'null') {
            if ($reason.Kind -ne 'string' -or $reason.Value -cnotin @('end_turn','stop_sequence')) { Set-StreamFailure $State 'unaccepted stop_reason'; return }
            $State.Finished = $true
        }
    }
    if ($type -ceq 'message_stop') {
        if (-not $State.Finished) { Set-StreamFailure $State 'message_stop without accepted stop_reason' }
        else { Complete-TranslationStream $State }
    }
}
