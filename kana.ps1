<#
.SYNOPSIS
    Annotates Japanese text with kana readings.

.DESCRIPTION
    Takes input from -Text, -InputFile, the pipeline, or stdin -- exactly one
    of them -- and writes the annotated text to -OutputFile or stdout.

    Runs the kana tool in kana\Kana.Core.psm1, which wraps the bundled
    kana/kana.mjs converter (kuroshiro and kuromoji). Node.js and the vendored
    dictionary files must be present; deploy.ps1 installs them.

    Reading direction and output style come from the kana section of
    ~/.config/text-tools/config.json; a missing value means hiragana
    furigana.

    Exit codes: 0 success, 1 failure, 2 invalid arguments, 130 cancelled.

.EXAMPLE
    .\kana.ps1 -Text '<japanese text>'
    Write the annotated text to stdout.

.EXAMPLE
    Get-Content notes.txt | .\kana.ps1
    Annotate piped input.

.EXAMPLE
    .\kana.ps1 -InputFile in.txt -OutputFile out.txt
    Read from a file and write the result to another.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()][string] $Text,
    [string] $InputFile,
    [string] $OutputFile,
    # Separate pipeline binding avoids overwriting explicitly supplied Text.
    [Parameter(ValueFromPipeline = $true, DontShow = $true)]
    [AllowEmptyString()][AllowNull()][string] $PipelineText,
    [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
    [object[]] $RemainingArguments
)
begin {
    $explicitText = $PSBoundParameters.ContainsKey('Text')
    $hasInputFile = $PSBoundParameters.ContainsKey('InputFile')
    $hasOutputFile = $PSBoundParameters.ContainsKey('OutputFile')
    $parts = [Collections.Generic.List[string]]::new()
    # Windows PowerShell -File may report ExpectingInput for redirected stdin.
    # Actual pipeline binding is also tracked in process.
    $hasPipeline = $MyInvocation.ExpectingInput -and -not [string]::IsNullOrEmpty($MyInvocation.Line)
}
process {
    if ($PSBoundParameters.ContainsKey('PipelineText')) {
        $hasPipeline = $true
        $parts.Add($PipelineText)
    }
}
end {
    $ErrorActionPreference = 'Stop'
    $kanaExitCode = 130
    try {
        if ($RemainingArguments.Count -gt 0 -or
            ([int]$explicitText + [int]$hasInputFile + [int]$hasPipeline) -gt 1) {
            $kanaExitCode = 2
            throw 'invalid arguments: choose one input source'
        }

        # ---------------------------------------------------------------
        # Resolve-EntryFilePath <Path>
        #   Resolve a caller-supplied path without requiring it to exist,
        #   rejecting non-FileSystem providers.
        # ---------------------------------------------------------------
        function Resolve-EntryFilePath([string] $Path) {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                throw 'file path must not be empty'
            }

            $provider = $null
            $drive = $null
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
            if ($provider.Name -ne 'FileSystem') {
                throw 'only FileSystem paths are supported'
            }

            return $resolved
        }

        # Strict UTF-8: a mis-encoded input file is an error, not mojibake.
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $source =
            if ($hasPipeline) {
                [string]::Join([Environment]::NewLine, $parts.ToArray())
            } elseif ($explicitText) {
                $Text
            } elseif ($hasInputFile) {
                [IO.File]::ReadAllText((Resolve-EntryFilePath $InputFile), $utf8)
            } else {
                $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8, $true, 1024, $true)
                try {
                    $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            }

        if ([string]::IsNullOrWhiteSpace($source)) {
            throw 'no input text provided'
        }

        $outputPath =
            if ($hasOutputFile) {
                Resolve-EntryFilePath $OutputFile
            } else {
                ''
            }
        Import-Module (Join-Path $PSScriptRoot 'kana\Kana.Core.psm1') -Force -ErrorAction Stop
        Invoke-Kana -Text $source -OutputFile $outputPath
        $kanaExitCode = 0
    } catch [System.Management.Automation.PipelineStoppedException] {
        $kanaExitCode = 130
    } catch [System.OperationCanceledException] {
        $kanaExitCode = 130
    } catch {
        if ($kanaExitCode -ne 2) {
            $kanaExitCode = 1
        }

        [Console]::Error.WriteLine('kana: ' + $_.Exception.Message)
    } finally {
        # PowerShell also runs finally when Ctrl+C stops the pipeline.
        # Windows PowerShell can overwrite a stopped -File pipeline's exit with
        # zero. Only terminate the standalone host after module cleanup finishes;
        # an invocation inside an existing interactive host must keep that host.
        if ($kanaExitCode -eq 130) {
            $hostArguments = [Environment]::GetCommandLineArgs()
            for ($argumentIndex = 0; $argumentIndex -lt $hostArguments.Length - 1; $argumentIndex++) {
                if ($hostArguments[$argumentIndex] -ieq '-File') {
                    $hostScript = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($hostArguments[$argumentIndex + 1])
                    if ($hostScript -ieq $PSCommandPath) {
                        [Environment]::Exit(130)
                    }

                    break
                }
            }
        }

        exit $kanaExitCode
    }
}
