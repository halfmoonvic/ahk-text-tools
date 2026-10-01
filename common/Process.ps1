# Process.ps1 - Starting and stopping the child processes the tools shell out to.
#
# Dot-sourced by the modules that run curl, bash or other helpers.

# ---------------------------------------------------------------------------
# ConvertTo-WindowsArgument <Argument>
#   Quote one argument for the Windows command line.
# ---------------------------------------------------------------------------
function ConvertTo-WindowsArgument([AllowEmptyString()][string] $Argument) {
    # Microsoft CRT argv rules: backslashes only need doubling before quotes or
    # before our closing quote. Always quoting also preserves empty arguments.
    $quoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

# ---------------------------------------------------------------------------
# New-ChildProcess <Executable> <Arguments>
#   Build a non-shell child process with UTF-8 redirected pipes. The caller
#   starts it; this only prepares StartInfo.
# ---------------------------------------------------------------------------
function New-ChildProcess([string] $Executable, [string[]] $Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)

    # Environment changes are confined to the child. Inherited proxy variables
    # are dropped so the proxy each caller configures explicitly is the only one.
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -match '^(http_proxy|https_proxy|all_proxy|no_proxy)$') {
            $info.EnvironmentVariables.Remove($key)
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    return $process
}

# ---------------------------------------------------------------------------
# Stop-ChildProcess <Process>
#   Kill and dispose a child process, tolerating one that already exited.
# ---------------------------------------------------------------------------
function Stop-ChildProcess($Process) {
    if ($null -eq $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }

        while (-not $Process.WaitForExit(50)) { }
    } catch [InvalidOperationException] {
    } finally {
        $Process.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Test-ProcessIdentity <ProcessId> <StartTicks>
#   Return whether the live process with ProcessId is the same one that
#   started at StartTicks. The start time distinguishes the original owner
#   from an unrelated process that later reused the id.
# ---------------------------------------------------------------------------
function Test-ProcessIdentity([int] $ProcessId, [long] $StartTicks) {
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        return $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks
    } catch [ArgumentException] {
        return $false
    } finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
