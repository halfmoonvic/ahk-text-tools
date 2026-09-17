# Sse.ps1 - Server-sent-event parsing and translation stream state.
#
# Dot-sourced by Translate.Core.psm1. Receive-SseChunk is fed raw curl stdout and
# drives the chain chunk -> line -> event -> per-protocol handler in the adapters.
#
# Stream state:
#   Status starts at 'receiving' and moves once to 'success' or 'failure'. Every
#   entry point returns early unless Status is still 'receiving', so a failure is
#   recorded once and later events in the same stream cannot overwrite it.

# ---------------------------------------------------------------------------
# New-TranslationStream <Writer> <Protocol>
#   Create the mutable state bag shared by the SSE reader and the adapters.
#   Seen tracks whether any content arrived; Finished tracks whether the
#   protocol signalled an acceptable end, so a truncated stream is not
#   reported as success.
# ---------------------------------------------------------------------------
function New-TranslationStream($Writer, [string] $Protocol) {
    return @{
        Status   = 'receiving'
        Error    = ''
        Protocol = $Protocol
        Writer   = $Writer
        Seen     = $false
        Finished = $false
        Line     = [Text.StringBuilder]::new()
        Data     = [Collections.Generic.List[string]]::new()
        Event    = ''
    }
}

# ---------------------------------------------------------------------------
# Set-StreamFailure <State> <Message>
#   Record the first failure. Later calls are ignored so the original cause
#   survives to the caller.
# ---------------------------------------------------------------------------
function Set-StreamFailure($State, [string] $Message) {
    if ($State.Status -eq 'receiving') {
        $State.Status = 'failure'
        $State.Error = "$($State.Protocol): $Message"
    }
}

# ---------------------------------------------------------------------------
# Write-TranslationDelta <State> <Node>
#   Write one text delta straight through to the output writer. Flushed per
#   delta so translations stream to the caller instead of arriving at once.
# ---------------------------------------------------------------------------
function Write-TranslationDelta($State, $Node) {
    if ($State.Status -ne 'receiving' -or $null -eq $Node -or
        $Node.Kind -ne 'string' -or $Node.Value.Length -eq 0) {
        return
    }

    $State.Writer.Write([string]$Node.Value)
    $State.Writer.Flush()
    $State.Seen = $true
}

# ---------------------------------------------------------------------------
# Complete-TranslationStream <State>
#   Close a stream that ended normally. An end with no content is a failure:
#   the caller must not treat an empty translation as a valid result.
# ---------------------------------------------------------------------------
function Complete-TranslationStream($State) {
    if ($State.Status -ne 'receiving') {
        return
    }

    if (-not $State.Seen) {
        Set-StreamFailure $State 'completed without translation content'
    } else {
        $State.Status = 'success'
    }
}

# ---------------------------------------------------------------------------
# Receive-SseEvent <State>
#   Dispatch one buffered event to the adapter for this protocol. Clears the
#   data and event-name buffers whether or not the event is understood.
# ---------------------------------------------------------------------------
function Receive-SseEvent($State) {
    if ($State.Status -ne 'receiving' -or $State.Data.Count -eq 0) {
        $State.Event = ''
        return
    }

    $data = [string]::Join("`n", $State.Data.ToArray())
    $State.Data.Clear()
    $eventName = $State.Event
    $State.Event = ''

    if ($data -ceq '[DONE]') {
        if ($State.Protocol -eq 'openai-completions') {
            if (-not $State.Finished) {
                Set-StreamFailure $State '[DONE] before finish_reason=stop'
            } else {
                Complete-TranslationStream $State
            }
        }
        return
    }

    try {
        $node = ConvertFrom-StrictJson $data
    } catch {
        Set-StreamFailure $State 'invalid JSON in SSE event'
        return
    }

    if ($node.Kind -ne 'object') {
        Set-StreamFailure $State 'SSE event must be a JSON object'
        return
    }

    if ($null -ne (Get-JsonMember $node 'error') -or
        (Get-JsonString (Get-JsonMember $node 'type')) -ceq 'error' -or
        $eventName -ceq 'error') {
        Set-StreamFailure $State 'API error'
        return
    }

    switch ($State.Protocol) {
        'openai-completions' { Receive-OpenAICompletionsEvent $State $node }
        'openai-responses' { Receive-OpenAIResponsesEvent $State $node }
        'anthropic-messages' { Receive-AnthropicMessagesEvent $State $node }
    }
}

# ---------------------------------------------------------------------------
# Receive-SseLine <State> <Line>
#   Parse one SSE field line. A blank line terminates the current event; a
#   leading ':' marks a comment. Per the SSE grammar a field with no colon is
#   a name with an empty value, and one leading space after the colon is
#   stripped.
# ---------------------------------------------------------------------------
function Receive-SseLine($State, [string] $Line) {
    if ($State.Status -ne 'receiving') {
        return
    }

    if ($Line.EndsWith("`r")) {
        $Line = $Line.Substring(0, $Line.Length - 1)
    }

    if ($Line.Length -eq 0) {
        Receive-SseEvent $State
        return
    }

    if ($Line[0] -ceq ':') {
        return
    }

    $colon = $Line.IndexOf(':')
    if ($colon -lt 0) {
        $field = $Line
        $value = ''
    } else {
        $field = $Line.Substring(0, $colon)
        $value = $Line.Substring($colon + 1)
        if ($value.StartsWith(' ')) {
            $value = $value.Substring(1)
        }
    }

    if ($field -ceq 'data') {
        $State.Data.Add($value)
    } elseif ($field -ceq 'event') {
        $State.Event = $value
    }
}

# ---------------------------------------------------------------------------
# Receive-SseChunk <State> <Chunk>
#   Feed a raw stdout chunk into the line splitter. A partial trailing line is
#   buffered in $State.Line until a later chunk completes it, so an event split
#   across two reads is still parsed correctly.
# ---------------------------------------------------------------------------
function Receive-SseChunk($State, [string] $Chunk) {
    if ($State.Status -ne 'receiving') {
        return
    }

    $start = 0
    while ($start -lt $Chunk.Length -and $State.Status -eq 'receiving') {
        $end = $Chunk.IndexOf("`n", $start)
        if ($end -lt 0) {
            [void]$State.Line.Append($Chunk.Substring($start))
            break
        }

        [void]$State.Line.Append($Chunk.Substring($start, $end - $start))
        Receive-SseLine $State $State.Line.ToString()
        [void]$State.Line.Clear()
        $start = $end + 1
    }
}
