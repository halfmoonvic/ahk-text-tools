function Get-GitBash {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($key in @('HKCU:\Software\GitForWindows','HKLM:\SOFTWARE\GitForWindows')) {
        $installation = Get-ItemProperty -LiteralPath $key -Name InstallPath -ErrorAction SilentlyContinue
        if ($null -ne $installation) { $candidates += Join-Path $installation.InstallPath 'bin\bash.exe' }
    }
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    throw 'Google mode requires Git for Windows Bash; install Git for Windows with gawk'
}
function Invoke-GoogleTranslate([string] $Text, [string] $Target, [string] $OutputFile, $Common, [Threading.CancellationToken] $CancellationToken) {
    $bash = Get-GitBash
    $proxy = Get-TranslateProxy $Common.Settings 'google' 'http' -HttpOnly
    $inputPath = [IO.Path]::GetTempFileName()
    $process = $null; $writer = $null; $started = $false
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        [IO.File]::WriteAllText($inputPath, $Text, [Text.UTF8Encoding]::new($false))
        if ($OutputFile) {
            $stream = [IO.File]::Open($OutputFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        }
        $launcher = Join-Path $PSScriptRoot 'google-launch.sh'
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'google'
        $process = New-CurlProcess $bash @('--noprofile','--norc', $launcher.Replace('\','/'), $script.Replace('\','/'), $inputPath.Replace('\','/'), $Target)
        # Bash must not source caller-controlled startup code or inherit proxy settings.
        foreach ($key in @($process.StartInfo.EnvironmentVariables.Keys)) {
            if ($key -match '^(BASH_ENV|ENV|SHELLOPTS|BASHOPTS|TRANS_.*)$') { $process.StartInfo.EnvironmentVariables.Remove($key) }
        }
        $process.StartInfo.EnvironmentVariables['PATH'] = (Join-Path (Split-Path (Split-Path $bash -Parent) -Parent) 'usr\bin') + ';' + $env:PATH
        $process.StartInfo.EnvironmentVariables['LANG'] = 'en_US.UTF-8'
        $process.StartInfo.EnvironmentVariables['LC_ALL'] = 'en_US.UTF-8'
        if ($proxy) { $process.StartInfo.EnvironmentVariables['http_proxy'] = $proxy }
        [void]$process.Start(); $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(50)) { $CancellationToken.ThrowIfCancellationRequested() }
        $result = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        # Publish once, including partial translation on a later line's failure.
        if ($writer) { $writer.Write($result); $writer.Flush() }
        else {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($result)
            $output = [Console]::OpenStandardOutput(); $output.Write($bytes, 0, $bytes.Length); $output.Flush()
        }
        if ($process.ExitCode -ne 0) {
            if ($process.ExitCode -eq 127) { throw 'Google mode requires Git Bash with gawk and cygpath installed' }
            throw "Google Shell failed (exit $($process.ExitCode)): $($errorText.Trim())"
        }
        # The legacy script can emit HTTP errors yet exit zero after an earlier
        # successful line. Preserve that translation, but do not report success.
        if ($errorText -match '(?m)^\[ERROR\]') { throw "Google Shell reported an error: $($errorText.Trim())" }
        if ([string]::IsNullOrWhiteSpace($result)) { throw 'Google Shell returned an empty translation' }
    } finally {
        if ($null -ne $process -and $started) {
            if (-not $process.HasExited) {
                $killer = New-CurlProcess (Join-Path $env:SystemRoot 'System32\taskkill.exe') @('/PID', [string]$process.Id, '/T', '/F')
                try { [void]$killer.Start(); $killOut = $killer.StandardOutput.ReadToEndAsync(); $killErr = $killer.StandardError.ReadToEndAsync(); $killer.WaitForExit(); [void]$killOut.GetAwaiter().GetResult(); [void]$killErr.GetAwaiter().GetResult() }
                finally { $killer.Dispose() }
            }
            Stop-TranslateProcess $process
        } elseif ($null -ne $process) {
            $process.Dispose()
        }
        if ($writer) { $writer.Dispose() }
        if ([IO.File]::Exists($inputPath)) { [IO.File]::Delete($inputPath) }
    }
}
