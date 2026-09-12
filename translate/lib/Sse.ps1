function New-TranslationStream($Writer, [string] $Protocol) {
    return @{ Status='receiving'; Error=''; Protocol=$Protocol; Writer=$Writer; Seen=$false; Finished=$false; Line=[Text.StringBuilder]::new(); Data=[Collections.Generic.List[string]]::new(); Event='' }
}
function Set-StreamFailure($State, [string] $Message) {
    if ($State.Status -eq 'receiving') { $State.Status = 'failure'; $State.Error = "$($State.Protocol): $Message" }
}
function Write-TranslationDelta($State, $Node) {
    if ($State.Status -ne 'receiving' -or $null -eq $Node -or $Node.Kind -ne 'string' -or $Node.Value.Length -eq 0) { return }
    $State.Writer.Write([string]$Node.Value); $State.Writer.Flush(); $State.Seen = $true
}
function Complete-TranslationStream($State) {
    if ($State.Status -ne 'receiving') { return }
    if (-not $State.Seen) { Set-StreamFailure $State 'completed without translation content' }
    else { $State.Status = 'success' }
}
function Receive-SseEvent($State) {
    if ($State.Status -ne 'receiving' -or $State.Data.Count -eq 0) { $State.Event = ''; return }
    $data = [string]::Join("`n", $State.Data.ToArray()); $State.Data.Clear()
    $eventName = $State.Event; $State.Event = ''
    if ($data -ceq '[DONE]') {
        if ($State.Protocol -eq 'openai-completions') {
            if (-not $State.Finished) { Set-StreamFailure $State '[DONE] before finish_reason=stop' }
            else { Complete-TranslationStream $State }
        }
        return
    }
    try { $node = ConvertFrom-StrictJson $data }
    catch { Set-StreamFailure $State 'invalid JSON in SSE event'; return }
    if ($node.Kind -ne 'object') { Set-StreamFailure $State 'SSE event must be a JSON object'; return }
    if ($null -ne (Get-JsonMember $node 'error') -or (Get-JsonString (Get-JsonMember $node 'type')) -ceq 'error' -or $eventName -ceq 'error') { Set-StreamFailure $State 'API error'; return }
    switch ($State.Protocol) {
        'openai-completions' { Receive-OpenAICompletionsEvent $State $node }
        'openai-responses' { Receive-OpenAIResponsesEvent $State $node }
        'anthropic-messages' { Receive-AnthropicMessagesEvent $State $node }
    }
}
function Receive-SseLine($State, [string] $Line) {
    if ($State.Status -ne 'receiving') { return }
    if ($Line.EndsWith("`r")) { $Line = $Line.Substring(0, $Line.Length - 1) }
    if ($Line.Length -eq 0) { Receive-SseEvent $State; return }
    if ($Line[0] -ceq ':') { return }
    $colon = $Line.IndexOf(':')
    if ($colon -lt 0) { $field = $Line; $value = '' }
    else {
        $field = $Line.Substring(0, $colon); $value = $Line.Substring($colon + 1)
        if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
    }
    if ($field -ceq 'data') { $State.Data.Add($value) }
    elseif ($field -ceq 'event') { $State.Event = $value }
}
function Receive-SseChunk($State, [string] $Chunk) {
    if ($State.Status -ne 'receiving') { return }
    $start = 0
    while ($start -lt $Chunk.Length -and $State.Status -eq 'receiving') {
        $end = $Chunk.IndexOf("`n", $start)
        if ($end -lt 0) { [void]$State.Line.Append($Chunk.Substring($start)); break }
        [void]$State.Line.Append($Chunk.Substring($start, $end - $start))
        Receive-SseLine $State $State.Line.ToString(); [void]$State.Line.Clear()
        $start = $end + 1
    }
}
