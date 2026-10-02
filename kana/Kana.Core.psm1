# Kana.Core.psm1 - Module entry point for the kana tool.
#
# Imported by kana.ps1 and by run-batch.ps1. Invoke-Kana is the only exported
# command.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Order matters: Json.ps1 defines the classes the rest parse against.
foreach ($file in @(
    '../common/Json.ps1',
    '../common/Process.ps1',
    '../common/Config.ps1',
    'lib/Config.ps1',
    'lib/Kuroshiro.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}

# ---------------------------------------------------------------------------
# Invoke-Kana -Text <Text> [-OutputFile] [-Engine] [-CancellationToken]
#   Annotate the Japanese in Text with kana readings and write the result to
#   OutputFile, or to stdout when OutputFile is empty.
#
#   Engine 'kuroshiro', also used when Engine is empty, runs the bundled
#   kana.mjs converter under Node.js. The reading script and output style come
#   from the kana section of config.json.
# ---------------------------------------------------------------------------
function Invoke-Kana {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $Text,
        [string] $OutputFile,
        [string] $Engine,
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )

    if (-not [string]::IsNullOrWhiteSpace($Engine) -and $Engine -cne 'kuroshiro') {
        throw 'kana engine must be kuroshiro'
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'no input text provided'
    }

    $options = Get-KanaConfig
    if ($OutputFile) {
        $OutputFile = Resolve-FileSystemPath $OutputFile
    }

    Invoke-Kuroshiro $Text $options $OutputFile $CancellationToken
}

Export-ModuleMember -Function Invoke-Kana
