param(
    [Parameter(Mandatory=$true)][string] $Script,
    [Parameter(Mandatory=$true)][string] $InputFile,
    [Parameter(Mandatory=$true)][string] $OutputFile,
    [string] $Mode,
    [string] $Model
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
# Keep all descendants' scratch files inside this window's batch directory.
$env:TEMP = [IO.Path]::GetDirectoryName($OutputFile)
$env:TMP = $env:TEMP
try {
    $arguments = @{ InputFile=$InputFile; OutputFile=$OutputFile }
    if ($Mode) { $arguments.Mode = $Mode }
    if ($Model) { $arguments.Model = $Model }
    & $Script @arguments
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
