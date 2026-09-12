function New-OpenAIResponsesRequest($Config, [string] $Prompt) {
    $endpoint = $Config.BaseUrl.TrimEnd('/')
    if (-not $endpoint.EndsWith('/responses', [StringComparison]::Ordinal)) { $endpoint += '/responses' }
    $effort = if ($Config.Thinking -eq 'off') { 'none' } else { $Config.Thinking }
    $body = [ordered]@{ model=$Config.Model; instructions=$Config.SystemPrompt; input=$Prompt; temperature=$Config.Temperature; reasoning=@{effort=$effort}; stream=$true; store=$false }
    return @{ Url=$endpoint; Body=(ConvertTo-StrictJson $body); Headers=@('Content-Type: application/json', "Authorization: Bearer $($Config.ApiKey)") }
}
function Receive-OpenAIResponsesEvent($State, $Node) {
    $type = Get-JsonString (Get-JsonMember $Node 'type')
    switch -CaseSensitive ($type) {
        'response.failed' { Set-StreamFailure $State 'response.failed' }
        'response.incomplete' { Set-StreamFailure $State 'response.incomplete' }
        'response.output_text.delta' { Write-TranslationDelta $State (Get-JsonMember $Node 'delta') }
        'response.completed' { Complete-TranslationStream $State }
    }
}
