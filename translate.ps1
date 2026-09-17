<#
.SYNOPSIS
    Translates text between Chinese and English.

.DESCRIPTION
    Takes input from -Text, -InputFile, the pipeline, or stdin -- exactly one
    of them -- and streams the translation to -OutputFile or stdout.

    Mode 'ai' uses a provider configured in ~/.config/translate; mode 'google'
    shells out to the vendored Translate Shell script and needs no API key.
    Target 'auto' picks the direction from the ratio of Chinese to Latin
    characters in the input.

    Exit codes: 0 success, 1 failure, 2 invalid arguments, 130 cancelled.

.EXAMPLE
    .\translate.ps1 -Text 'hello world'
    Translate one string to stdout.

.EXAMPLE
    Get-Content notes.txt | .\translate.ps1 -Target en
    Translate piped input, forcing English output.

.EXAMPLE
    .\translate.ps1 -InputFile in.txt -OutputFile out.txt -Mode google
    Translate a file without using an API key.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()][string] $Text,
    [string] $InputFile,
    [string] $OutputFile,
    [string] $Model,
    [string] $Mode = 'ai',
    [string] $Target = 'auto',
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
    $translateExitCode = 130
    try {
        if ($RemainingArguments.Count -gt 0 -or $Target -cnotin @('auto','zh','en') -or
            $Mode -cnotin @('ai','google') -or ($Mode -eq 'google' -and -not [string]::IsNullOrEmpty($Model)) -or
            ([int]$explicitText + [int]$hasInputFile + [int]$hasPipeline) -gt 1) {
            $translateExitCode = 2
            throw 'invalid arguments: choose one input source; Target must be auto, zh, or en; Mode must be ai or google; google does not accept Model'
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
        Import-Module (Join-Path $PSScriptRoot 'translate\Translate.Core.psm1') -Force -ErrorAction Stop
        Invoke-Translate -Text $source -OutputFile $outputPath -Model $Model -Target $Target -Mode $Mode
        $translateExitCode = 0
    } catch [System.Management.Automation.PipelineStoppedException] {
        $translateExitCode = 130
    } catch [System.OperationCanceledException] {
        $translateExitCode = 130
    } catch {
        if ($translateExitCode -ne 2) {
            $translateExitCode = 1
        }

        [Console]::Error.WriteLine('translate: ' + $_.Exception.Message)
    } finally {
        # PowerShell also runs finally when Ctrl+C stops the pipeline.
        # Windows PowerShell can overwrite a stopped -File pipeline's exit with
        # zero. Only terminate the standalone host after module cleanup finishes;
        # an invocation inside an existing interactive host must keep that host.
        if ($translateExitCode -eq 130) {
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

        exit $translateExitCode
    }
}
