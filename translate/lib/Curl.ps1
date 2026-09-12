function ConvertTo-WindowsArgument([AllowEmptyString()][string] $Argument) {
    # Microsoft CRT argv rules: backslashes only need doubling before quotes or
    # before our closing quote. Always quoting also preserves empty arguments.
    $quoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}
function New-CurlProcess([string] $Executable, [string[]] $Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    # Environment changes are confined to the child. --proxy and --noproxy are
    # authoritative even if the calling shell has proxy environment variables.
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -match '^(http_proxy|https_proxy|all_proxy|no_proxy)$') { $info.EnvironmentVariables.Remove($key) }
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    return $process
}
function Stop-TranslateProcess($Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        while (-not $Process.WaitForExit(50)) { }
    } catch [InvalidOperationException] { }
    finally { $Process.Dispose() }
}
function Get-SystemCurl {
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
    $path = Join-Path $systemDirectory 'curl.exe'
    if (-not [IO.File]::Exists($path)) { throw "system curl missing: $path; actual version: unavailable; required: >= 7.76.0" }
    $process = New-CurlProcess $path @('--disable','--version')
    try {
        [void]$process.Start(); $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(20)) { }
        $versionText = $stdout.GetAwaiter().GetResult(); [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $versionText -notmatch '^curl (\d+\.\d+\.\d+)') { throw "cannot identify system curl version: $path; actual version: unknown; required: >= 7.76.0" }
        $actual = $Matches[1]
        if ([version]$actual -lt [version]'7.76.0') { throw "system curl too old: $path; actual version: $actual; required: >= 7.76.0" }
    } finally { Stop-TranslateProcess $process }
    return $path
}
function Test-TranslateProcessIdentity([int] $ProcessId, [long] $StartTicks) {
    $process = $null
    try { $process = [Diagnostics.Process]::GetProcessById($ProcessId); return $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks }
    catch [ArgumentException] { return $false }
    finally { if ($null -ne $process) { $process.Dispose() } }
}
function Remove-TranslateTempDirectory([string] $Directory) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Directory)
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($full) -ne $tempRoot.TrimEnd('\') -or [IO.Path]::GetFileName($full) -notmatch '^translate-request-\d+-\d+-[a-f0-9]{32}$') { throw 'refusing to remove unrecognized temporary directory' }
    if ([IO.Directory]::Exists($full)) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
}
function Clear-StaleTranslateRequests {
    foreach ($directory in Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'translate-request-*' -ErrorAction SilentlyContinue) {
        if ($directory.Name -notmatch '^translate-request-(\d+)-(\d+)-[a-f0-9]{32}$' -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $ownerId = [int]$Matches[1]; $ownerTicks = [long]$Matches[2]
        try {
            if (Test-TranslateProcessIdentity $ownerId $ownerTicks) { continue }
            $childFile = Join-Path $directory.FullName 'curl-owner'
            if ([IO.File]::Exists($childFile)) {
                $child = [IO.File]::ReadAllText($childFile)
                if ($child -notmatch '^(\d+) (\d+)$') { continue }
                $childId = [int]$Matches[1]; $childTicks = [long]$Matches[2]
                if (Test-TranslateProcessIdentity $childId $childTicks) { Stop-TranslateProcess ([Diagnostics.Process]::GetProcessById($childId)) }
            }
            Remove-TranslateTempDirectory $directory.FullName
        } catch { # Inaccessible process identity or files: leave them untouched.
        }
    }
}
function Get-CurlHttpStatus([string] $HeaderFile) {
    if (-not [IO.File]::Exists($HeaderFile)) { return 0 }
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::Open($HeaderFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
        $headers = $reader.ReadToEnd()
    } finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
    $status = 0
    foreach ($block in [regex]::Matches($headers, '(?s)(.*?)(?:\r?\n){2}')) {
        if ($block.Groups[1].Value -match '\AHTTP/\S+\s+(\d{3})([^\r\n]*)') {
            $candidate = [int]$Matches[1]; $reason = $Matches[2]
            if ($candidate -ge 200 -and $reason -notmatch '(?i)connection established') { $status = $candidate }
        }
    }
    return $status
}
function Invoke-CurlSse($Config, $Request, [string] $OutputFile, [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None) {
    Clear-StaleTranslateRequests
    $executable = Get-SystemCurl
    $directory = $null; $process = $null; $writer = $null; $outputStream = $null; $state = $null
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        $owner = [Diagnostics.Process]::GetCurrentProcess()
        try { $directory = Join-Path ([IO.Path]::GetTempPath()) ("translate-request-$PID-$($owner.StartTime.ToUniversalTime().Ticks)-" + [guid]::NewGuid().ToString('N')) }
        finally { $owner.Dispose() }
        [void][IO.Directory]::CreateDirectory($directory)
        $bodyFile = Join-Path $directory 'body.json'; $headerFile = Join-Path $directory 'request.headers'; $responseHeaders = Join-Path $directory 'response.headers'
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
        $state = New-TranslationStream $writer $Config.Api
        $arguments = @('--disable','--silent','--show-error','--no-buffer','--fail-with-body','--suppress-connect-headers','--request','POST','--url',$Request.Url,'--header',('@' + $headerFile),'--dump-header',$responseHeaders,'--data-binary',('@' + $bodyFile))
        if ($Config.Proxy) { $arguments += @('--proxy', $Config.Proxy, '--noproxy', '') }
        else { $arguments += @('--proxy', '', '--noproxy', '*') }
        $process = New-CurlProcess $executable $arguments
        [void]$process.Start()
        # Drain stderr immediately on the .NET async IO path, without a runspace
        # callback. Never echo server-controlled diagnostics or credentials.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [IO.File]::WriteAllText((Join-Path $directory 'curl-owner'), "$($process.Id) $($process.StartTime.ToUniversalTime().Ticks)", $utf8)
        $buffer = [char[]]::new(4096)
        $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        $status = 0; $eof = $false
        while ($state.Status -eq 'receiving') {
            $CancellationToken.ThrowIfCancellationRequested()
            if ($status -eq 0) { $status = Get-CurlHttpStatus $responseHeaders }
            if ($status -ne 0 -and ($status -lt 200 -or $status -ge 300)) { Set-StreamFailure $state "HTTP $status"; break }
            if ($readTask.IsCompleted -and ($status -ne 0 -or $process.HasExited)) {
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $eof = $true; break }
                if ($status -ge 200 -and $status -lt 300) { Receive-SseChunk $state ([string]::new($buffer, 0, $count)) }
                if ($state.Status -ne 'receiving') { break }
                $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
            } else { [Threading.Thread]::Sleep(10) }
        }
        if ($state.Status -eq 'success') { return }
        if ($state.Status -eq 'failure') { throw $state.Error }
        if ($eof) {
            while (-not $process.WaitForExit(20)) { $CancellationToken.ThrowIfCancellationRequested() }
            [void]$stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "$($Config.Api): HTTP/network request failed (curl exit code $($process.ExitCode))" }
            throw "$($Config.Api): stream truncated: EOF before required completion event"
        }
    } finally {
        if ($null -ne $state -and $state.Status -eq 'receiving') { $state.Status = 'failure' }
        try { Stop-TranslateProcess $process }
        finally {
            try { if ($null -ne $writer) { $writer.Dispose() } }
            finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $directory) { Remove-TranslateTempDirectory $directory }
            }
        }
    }
}
