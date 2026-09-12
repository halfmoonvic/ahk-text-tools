function New-OpenAICompletionsRequest($Config, [string] $Prompt) {
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if (-not $endpoint.EndsWith('/chat/completions', [StringComparison]::Ordinal)) { $endpoint += '/chat/completions' }
    $effort = if ($Config.Thinking -eq 'off') { 'none' } else { $Config.Thinking }
    $body = [ordered]@{ model=$Config.Model; messages=@(@{role='system';content=$Config.SystemPrompt}, @{role='user';content=$Prompt}); temperature=$Config.Temperature; reasoning_effort=$effort; stream=$true }
    return @{ Url=$endpoint; Body=(ConvertTo-StrictJson $body); Headers=@('Content-Type: application/json', "Authorization: Bearer $($Config.ApiKey)") }
}
function Receive-OpenAICompletionsEvent($State, $Node) {
    $choices = Get-JsonMember $Node 'choices'
    if ($null -eq $choices -or $choices.Kind -ne 'array' -or $choices.Value.Count -eq 0) { return }
    $choice = $choices.Value[0]
    Write-TranslationDelta $State (Get-JsonMember (Get-JsonMember $choice 'delta') 'content')
    $reason = Get-JsonMember $choice 'finish_reason'
    if ($null -ne $reason -and $reason.Kind -ne 'null' -and -not ($reason.Kind -eq 'string' -and $reason.Value -eq '')) {
        if ($reason.Kind -ne 'string' -or $reason.Value -cne 'stop') { Set-StreamFailure $State 'unaccepted finish_reason'; return }
        $State.Finished = $true
    }
}
