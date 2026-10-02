# run-batch.ps1 - Runs every translate engine of one popup in a single process.
#
# text.ahk starts this once per run instead of one PowerShell per engine. Each
# engine translates on its own runspace thread and reports through N.out, N.err
# and N.status in OutputDirectory, N being its line number in EngineFile.
# text.ahk treats N.status as the signal that the other two files are final, so
# it must be the last file an engine writes, and must appear in one step.

param(
    [Parameter(Mandatory=$true)][string] $InputFile,
    [Parameter(Mandatory=$true)][string] $EngineFile,
    [Parameter(Mandatory=$true)][string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
# Keep all descendants' scratch files inside this window's batch directory.
$env:TEMP = $OutputDirectory
$env:TMP = $env:TEMP

# No exit in here: it would end the whole process and every other engine with it.
$translateEngine = {
    param([string] $Module, [string] $Text, [string] $Engine, [string] $Prefix)
    $ErrorActionPreference = 'Stop'
    $utf8 = [Text.UTF8Encoding]::new($false)
    $exitCode = 1
    try {
        Import-Module $Module
        Invoke-Translate -Text $Text -OutputFile "$Prefix.out" -Engine $Engine
        $exitCode = 0
    } catch {
        [IO.File]::WriteAllText("$Prefix.err", 'translate: ' + $_.Exception.Message, $utf8)
    } finally {
        [IO.File]::WriteAllText("$Prefix.status.tmp", [string]$exitCode, $utf8)
        [IO.File]::Move("$Prefix.status.tmp", "$Prefix.status")
    }
}

$pool = $null
$jobs = @()
try {
    # Strict UTF-8: a mis-encoded input file is an error, not mojibake.
    $text = [IO.File]::ReadAllText($InputFile, [Text.UTF8Encoding]::new($false, $true))
    $engines = [IO.File]::ReadAllLines($EngineFile, [Text.UTF8Encoding]::new($false, $true))
    if ($engines.Count -eq 0) {
        throw 'no translate engines given'
    }

    $module = Join-Path (Split-Path $PSScriptRoot -Parent) 'translate\Translate.Core.psm1'
    $pool = [runspacefactory]::CreateRunspacePool(1, $engines.Count)
    $pool.Open()
    for ($index = 0; $index -lt $engines.Count; $index++) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        [void]$shell.AddScript($translateEngine).
            AddArgument($module).
            AddArgument($text).
            AddArgument($engines[$index]).
            AddArgument((Join-Path $OutputDirectory ($index + 1)))
        $jobs += @{ Shell = $shell; Result = $shell.BeginInvoke() }
    }

    # One EndInvoke at a time: WaitHandle.WaitAll rejects several handles on the
    # STA thread Windows PowerShell runs scripts on.
    foreach ($job in $jobs) {
        [void]$job.Shell.EndInvoke($job.Result)
    }

    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    foreach ($job in $jobs) {
        $job.Shell.Dispose()
    }

    if ($null -ne $pool) {
        $pool.Dispose()
    }
}
