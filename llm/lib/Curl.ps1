# Curl.ps1 - Running the streaming HTTP request through the system curl.exe.
#
# Dot-sourced by Llm.Core.psm1. The adapters build a request and
# Invoke-CurlSse streams the response through Sse.ps1 to the output writer.
#
# Why curl rather than .NET HTTP: Windows PowerShell 5.1's stack cannot stream a
# response body incrementally, so text would only appear once complete.
#
# Each request gets its own temporary directory named with the owning process id
# and start time. Body and headers are passed as @files so credentials never
# appear in a command line other processes can read.

# ---------------------------------------------------------------------------
# Get-SystemCurl
#   Return the path to the Windows-bundled curl.exe. It must be 7.76.0 or
#   newer for --fail-with-body; an older one rejects that option at request
#   time, which Invoke-CurlSse reports through exit code 2.
#
#   Resolved through Sysnative for a 32-bit process on 64-bit Windows, which
#   would otherwise be redirected to the 32-bit System32.
# ---------------------------------------------------------------------------
function Get-SystemCurl {
    $systemDirectory =
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            Join-Path $env:SystemRoot 'Sysnative'
        } else {
            Join-Path $env:SystemRoot 'System32'
        }
    $path = Join-Path $systemDirectory 'curl.exe'
    if (-not [IO.File]::Exists($path)) {
        throw "system curl missing: $path"
    }

    return $path
}

# ---------------------------------------------------------------------------
# Remove-LlmTempDirectory <Directory>
#   Delete one request directory, refusing anything that is not a direct child
#   of the temp root matching our own naming pattern. This runs with -Recurse
#   -Force, so the guard is what keeps a bad caller from deleting elsewhere.
# ---------------------------------------------------------------------------
function Remove-LlmTempDirectory([string] $Directory) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Directory)
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($full) -ne $tempRoot.TrimEnd('\') -or
        [IO.Path]::GetFileName($full) -notmatch '^llm-request-\d+-\d+-[a-f0-9]{32}$') {
        throw 'refusing to remove unrecognized temporary directory'
    }

    if ([IO.Directory]::Exists($full)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# Clear-StaleLlmRequests
#   Remove request directories left behind by runs that were killed before
#   their finally block could clean up. A directory is only removed once its
#   owner is confirmed gone; a still-running curl child is stopped first.
#
#   Reparse points are skipped so a planted symlink cannot redirect the
#   delete. Failures are ignored: cleanup must never break a new request.
# ---------------------------------------------------------------------------
function Clear-StaleLlmRequests {
    foreach ($directory in Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'llm-request-*' -ErrorAction SilentlyContinue) {
        if ($directory.Name -notmatch '^llm-request-(\d+)-(\d+)-[a-f0-9]{32}$' -or
            ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            continue
        }

        $ownerId = [int]$Matches[1]
        $ownerTicks = [long]$Matches[2]
        try {
            if (Test-ProcessIdentity $ownerId $ownerTicks) {
                continue
            }

            $childFile = Join-Path $directory.FullName 'curl-owner'
            if ([IO.File]::Exists($childFile)) {
                $child = [IO.File]::ReadAllText($childFile)
                if ($child -notmatch '^(\d+) (\d+)$') {
                    continue
                }

                $childId = [int]$Matches[1]
                $childTicks = [long]$Matches[2]
                if (Test-ProcessIdentity $childId $childTicks) {
                    Stop-ChildProcess ([Diagnostics.Process]::GetProcessById($childId))
                }
            }

            Remove-LlmTempDirectory $directory.FullName
        } catch {
            # Inaccessible process identity or files: leave them untouched.
        }
    }
}

# ---------------------------------------------------------------------------
# Get-CurlHttpStatus <HeaderFile>
#   Read the final HTTP status from curl's dumped response headers, or 0 when
#   no status has been written yet.
#
#   The file may hold several header blocks from redirects and proxy CONNECT
#   exchanges, so the last real response status wins and 'Connection
#   established' is skipped.
# ---------------------------------------------------------------------------
function Get-CurlHttpStatus([string] $HeaderFile) {
    if (-not [IO.File]::Exists($HeaderFile)) {
        return 0
    }

    $stream = $null
    $reader = $null
    try {
        # Shared read: curl is still appending to this file.
        $stream = [IO.File]::Open($HeaderFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
        $headers = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $status = 0
    foreach ($block in [regex]::Matches($headers, '(?s)(.*?)(?:\r?\n){2}')) {
        if ($block.Groups[1].Value -match '\AHTTP/\S+\s+(\d{3})([^\r\n]*)') {
            $candidate = [int]$Matches[1]
            $reason = $Matches[2]
            if ($candidate -ge 200 -and $reason -notmatch '(?i)connection established') {
                $status = $candidate
            }
        }
    }

    return $status
}

# ---------------------------------------------------------------------------
# Invoke-CurlSse <Config> <Request> <OutputFile> [<CancellationToken>]
#   Run the streaming request and write the response text to OutputFile, or to
#   stdout when OutputFile is empty. Throws on any HTTP, network, or protocol
#   failure; returns normally only once the stream completes cleanly.
#
#   Polling with a small sleep rather than awaiting: a blocking await cannot be
#   interrupted by Ctrl+C on Windows PowerShell, which would leave the request
#   running after the user cancelled.
# ---------------------------------------------------------------------------
function Invoke-CurlSse($Config, $Request, [string] $OutputFile, [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None) {
    Clear-StaleLlmRequests
    $executable = Get-SystemCurl
    $directory = $null
    $process = $null
    $writer = $null
    $outputStream = $null
    $state = $null

    try {
        $CancellationToken.ThrowIfCancellationRequested()
        $owner = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $directory = Join-Path ([IO.Path]::GetTempPath()) (
                "llm-request-$PID-$($owner.StartTime.ToUniversalTime().Ticks)-" +
                [guid]::NewGuid().ToString('N'))
        } finally {
            $owner.Dispose()
        }

        [void][IO.Directory]::CreateDirectory($directory)
        $bodyFile = Join-Path $directory 'body.json'
        $headerFile = Join-Path $directory 'request.headers'
        $responseHeaders = Join-Path $directory 'response.headers'
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        [IO.File]::WriteAllText($bodyFile, $Request.Body, $utf8)
        [IO.File]::WriteAllText($headerFile, ($Request.Headers -join "`r`n") + "`r`n", $utf8)

        if ($OutputFile) {
            $outputStream = [IO.File]::Open($OutputFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $writer = [IO.StreamWriter]::new($outputStream, $utf8)
        } else {
            # Use the byte stream so stdout is UTF-8 on both PowerShell hosts.
            $writer = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8, 1024, $true)
        }

        $state = New-LlmStream $writer $Config.Api
        $arguments = @(
            '--disable',
            # Only the connection phase is bounded: a total limit would cut off long thinking responses.
            '--connect-timeout', [string]$Config.ConnectTimeout,
            '--silent',
            '--show-error',
            '--no-buffer',
            '--fail-with-body',
            '--suppress-connect-headers',
            '--request', 'POST',
            '--url', $Request.Url,
            '--header', ('@' + $headerFile),
            '--dump-header', $responseHeaders,
            '--data-binary', ('@' + $bodyFile)
        )
        if ($Config.Proxy) {
            $arguments += @('--proxy', $Config.Proxy, '--noproxy', '')
        } else {
            $arguments += @('--proxy', '', '--noproxy', '*')
        }

        $process = New-ChildProcess $executable $arguments
        [void]$process.Start()

        # Drain stderr immediately on the .NET async IO path, without a runspace
        # callback. Never echo server-controlled diagnostics or credentials.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [IO.File]::WriteAllText(
            (Join-Path $directory 'curl-owner'),
            "$($process.Id) $($process.StartTime.ToUniversalTime().Ticks)",
            $utf8)

        $buffer = [char[]]::new(4096)
        $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        $status = 0
        $eof = $false
        while ($state.Status -eq 'receiving') {
            $CancellationToken.ThrowIfCancellationRequested()
            if ($status -eq 0) {
                $status = Get-CurlHttpStatus $responseHeaders
            }

            if ($status -ne 0 -and ($status -lt 200 -or $status -ge 300)) {
                Set-StreamFailure $state "HTTP $status"
                break
            }

            # Wait for the status before consuming the body, so an error
            # response is never parsed as response text.
            if ($readTask.IsCompleted -and ($status -ne 0 -or $process.HasExited)) {
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $eof = $true
                    break
                }

                if ($status -ge 200 -and $status -lt 300) {
                    Receive-SseChunk $state ([string]::new($buffer, 0, $count))
                }

                if ($state.Status -ne 'receiving') {
                    break
                }

                $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
            } else {
                [Threading.Thread]::Sleep(10)
            }
        }

        if ($state.Status -eq 'success') {
            return
        }

        if ($state.Status -eq 'failure') {
            throw $state.Error
        }

        if ($eof) {
            while (-not $process.WaitForExit(20)) {
                $CancellationToken.ThrowIfCancellationRequested()
            }

            [void]$stderrTask.GetAwaiter().GetResult()
            # 28 can only come from --connect-timeout while no other time limit is passed.
            if ($process.ExitCode -eq 28) {
                throw "$($Config.Api): connection timed out after $($Config.ConnectTimeout)s"
            }

            if ($process.ExitCode -eq 2) {
                throw "$($Config.Api): curl rejected its arguments (exit code 2); system curl may be older than 7.76.0"
            }

            if ($process.ExitCode -ne 0) {
                throw "$($Config.Api): HTTP/network request failed (curl exit code $($process.ExitCode))"
            }

            throw "$($Config.Api): stream truncated: EOF before required completion event"
        }
    } finally {
        # A stream still 'receiving' here was cancelled; mark it failed so the
        # writer is not mistaken for a completed response.
        if ($null -ne $state -and $state.Status -eq 'receiving') {
            $state.Status = 'failure'
        }

        # Nested finally blocks: each stage must run even if an earlier one
        # throws, or the request directory would be left behind.
        try {
            Stop-ChildProcess $process
        } finally {
            try {
                if ($null -ne $writer) {
                    $writer.Dispose()
                }
            } finally {
                if ($null -ne $outputStream) {
                    $outputStream.Dispose()
                }

                if ($null -ne $directory) {
                    Remove-LlmTempDirectory $directory
                }
            }
        }
    }
}
