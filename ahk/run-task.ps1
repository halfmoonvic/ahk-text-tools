# run-task.ps1 - Runs one text tool for the AutoHotkey front-end.
#
# text.ahk invokes this instead of the tool directly so that every task gets a
# single exit code and an error message on stderr, whatever the tool does.

param(
    [Parameter(Mandatory=$true)][string] $Script,
    [Parameter(Mandatory=$true)][string] $InputFile,
    [Parameter(Mandatory=$true)][string] $OutputFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
# Keep all descendants' scratch files inside this window's batch directory.
$env:TEMP = [IO.Path]::GetDirectoryName($OutputFile)
$env:TMP = $env:TEMP
try {
    & $Script -InputFile $InputFile -OutputFile $OutputFile
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
