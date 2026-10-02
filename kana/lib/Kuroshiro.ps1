# Kuroshiro.ps1 - The kuroshiro engine, driven through the bundled kana.mjs.
#
# Dot-sourced by Kana.Core.psm1. kana.mjs tokenizes with kuromoji and converts
# the readings with kuroshiro; both libraries and the dictionary live under
# kana/vendor, which deploy.ps1 downloads.

# ---------------------------------------------------------------------------
# Invoke-Kuroshiro <Text> <Options> <OutputFile> <CancellationToken>
#   Annotate Text with kana.mjs and publish the result to OutputFile, or to
#   stdout when OutputFile is empty. Options carries To and Mode from
#   Get-KanaConfig.
# ---------------------------------------------------------------------------
function Invoke-Kuroshiro([string] $Text, $Options, [string] $OutputFile, [Threading.CancellationToken] $CancellationToken) {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) {
        throw 'Node.js is required for Japanese kana annotation, but node was not found on PATH.'
    }

    $toolRoot = Split-Path $PSScriptRoot -Parent
    $script = Join-Path $toolRoot 'kana.mjs'
    $vendorRoot = Join-Path $toolRoot 'vendor'
    if (-not [IO.File]::Exists($script)) {
        throw "Japanese kana converter script not found: $script"
    }

    if (-not [IO.File]::Exists((Join-Path $vendorRoot 'kuroshiro.min.js')) -or
        -not [IO.File]::Exists((Join-Path $vendorRoot 'kuromoji.js')) -or
        -not [IO.Directory]::Exists((Join-Path $vendorRoot 'dict'))) {
        throw "Japanese kana vendor files are missing under $vendorRoot."
    }

    $inputPath = [IO.Path]::GetTempFileName()
    $process = $null
    $started = $false
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        # Text goes through a file so the command line never has to quote it.
        [IO.File]::WriteAllText($inputPath, $Text, [Text.UTF8Encoding]::new($false))

        $process = New-ChildProcess $node.Source @(
            $script,
            '--input', $inputPath,
            '--to', $Options.To,
            '--mode', $Options.Mode
        )
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(50)) {
            $CancellationToken.ThrowIfCancellationRequested()
        }

        $result = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            # Node prints the source line and a stack around an uncaught
            # error; the "Error: ..." line is the part worth showing.
            $message = [regex]::Match($errorText, '(?m)^\w*Error\b.*$').Value.Trim()
            if (-not $message) {
                $message = $errorText.Trim()
            }

            throw "kuroshiro failed (exit $($process.ExitCode)): $message"
        }

        $utf8 = [Text.UTF8Encoding]::new($false)
        if ($OutputFile) {
            [IO.File]::WriteAllText($OutputFile, $result, $utf8)
        } else {
            $bytes = $utf8.GetBytes($result)
            $output = [Console]::OpenStandardOutput()
            $output.Write($bytes, 0, $bytes.Length)
            $output.Flush()
        }
    } finally {
        if ($started) {
            Stop-ChildProcess $process
        } elseif ($null -ne $process) {
            $process.Dispose()
        }

        if ([IO.File]::Exists($inputPath)) {
            [IO.File]::Delete($inputPath)
        }
    }
}
