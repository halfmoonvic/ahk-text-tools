<#
.SYNOPSIS
    Deploys the text-tools AutoHotkey suite to a Windows user's directories.

.DESCRIPTION
    Idempotent by design: program files are compared by hash and only copied when
    they differ, vendor libraries are skipped when already present, and existing
    configuration is never silently overwritten.

    Run it again any time to pick up repository changes; use -Update to pull first.

.EXAMPLE
    .\deploy.ps1
    Install (or refresh) into ~\.local\bin with configuration in ~\.config.

.EXAMPLE
    .\deploy.ps1 -Update
    Pull the latest commits, then deploy.

.EXAMPLE
    .\deploy.ps1 -TargetDir D:\tools\text-tools -ConfigDir D:\tools\config
    Install somewhere else entirely.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $TargetDir = (Join-Path $HOME '.local\bin'),
    [string] $ConfigDir = (Join-Path $HOME '.config'),
    [switch] $Update,
    [switch] $SkipVendor,
    [switch] $Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default, which npm rejects.
# PowerShell 7 already defaults to the system setting, so only widen when needed.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # A locked-down .NET may refuse; the download itself will report the failure.
    }
}

$RepoRoot = $PSScriptRoot
$script:Stats = [ordered]@{ Created = 0; Updated = 0; Unchanged = 0; Skipped = 0 }
$script:Warnings = [Collections.Generic.List[string]]::new()

#region helpers ---------------------------------------------------------------

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Item([string] $State, [string] $Path, [ConsoleColor] $Color = 'Gray') {
    Write-Host ('    {0,-10} {1}' -f $State, $Path) -ForegroundColor $Color
}

function Write-Warn([string] $Message) {
    $script:Warnings.Add($Message)
    Write-Host "    warning   $Message" -ForegroundColor Yellow
}

function Get-FileHashOrNull([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-ParentDirectory([string] $Path) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Copy-IfDifferent([string] $Source, [string] $Destination, [string] $Label) {
    $sourceHash = Get-FileHashOrNull $Source
    if ($null -eq $sourceHash) { throw "missing source file: $Source" }
    $destinationHash = Get-FileHashOrNull $Destination

    if ($sourceHash -eq $destinationHash) {
        $script:Stats.Unchanged++
        return
    }

    $isNew = $null -eq $destinationHash
    $action = if ($isNew) { 'create' } else { 'update' }
    if (-not $PSCmdlet.ShouldProcess($Destination, $action)) { return }

    New-ParentDirectory $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    if ($isNew) { $script:Stats.Created++; Write-Item 'created' $Label Green }
    else        { $script:Stats.Updated++; Write-Item 'updated' $Label Green }
}

#endregion

#region stage 0: optional git pull --------------------------------------------

function Invoke-RepositoryUpdate {
    Write-Step 'Updating repository'

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        Write-Warn 'not a git repository; skipping pull'
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn 'git not found on PATH; skipping pull'
        return
    }

    $status = & git -C $RepoRoot status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $status) {
        Write-Warn 'working tree has uncommitted changes; skipping pull'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'git pull --ff-only')) { return }

    & git -C $RepoRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Warn 'git pull failed; deploying the current checkout' }
}

#endregion

#region stage 1: program files ------------------------------------------------

# text.ahk derives the project root by stripping "\auto_hotkey\<file>" from its
# own path, then looks for translate.ps1 and kana.ps1 there. The two-level
# layout below is therefore mandatory - do not flatten it.
function Install-ProgramFiles {
    Write-Step "Deploying program files to $TargetDir"

    $files = @(
        'auto_hotkey\text.ahk'
        'auto_hotkey\json.ahk'
        'auto_hotkey\proc.ahk'
        'auto_hotkey\run-task.ps1'
        'translate.ps1'
        'kana.ps1'
        'translate\Translate.Core.psm1'
        'translate\google'
        'translate\lib\Config.ps1'
        'translate\lib\Curl.ps1'
        'translate\lib\Google.ps1'
        'translate\lib\Json.ps1'
        'translate\lib\Sse.ps1'
        'translate\lib\google-launch.sh'
        'translate\adapters\AnthropicMessages.ps1'
        'translate\adapters\OpenAICompletions.ps1'
        'translate\adapters\OpenAIResponses.ps1'
        'kana\kana.mjs'
    )

    foreach ($file in $files) {
        Copy-IfDifferent (Join-Path $RepoRoot $file) (Join-Path $TargetDir $file) $file
    }

    Write-Host "    $($script:Stats.Unchanged) unchanged, $($script:Stats.Created) created, $($script:Stats.Updated) updated"
}

#endregion

#region stage 2: kana vendor --------------------------------------------------

# Every file below ships prebuilt inside the npm tarballs, so this is an
# extract-and-copy step with no build tooling involved.
$script:DictionaryFiles = @(
    'base', 'cc', 'check', 'tid', 'tid_map', 'tid_pos',
    'unk', 'unk_char', 'unk_compat', 'unk_invoke', 'unk_map', 'unk_pos'
) | ForEach-Object { "dict\$_.dat.gz" }

$script:VendorFiles = @('kuroshiro.min.js', 'kuromoji.js') + $script:DictionaryFiles

function Get-MissingVendorFile([string] $VendorRoot) {
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($file in $script:VendorFiles) {
        $path = Join-Path $VendorRoot $file
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.Length -eq 0) { $missing.Add($file) }
    }
    return $missing.ToArray()
}

function Expand-NpmPackage([string] $Name, [string] $Destination) {
    $metadata = Invoke-RestMethod -Uri "https://registry.npmjs.org/$Name/latest" -UseBasicParsing
    $archive = Join-Path $Destination "$Name.tgz"

    Write-Host "    fetching   $Name@$($metadata.version)"

    # Invoke-WebRequest's progress bar cripples large downloads on 5.1.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $metadata.dist.tarball -OutFile $archive -UseBasicParsing
    } finally {
        $ProgressPreference = $previousProgress
    }

    $extractRoot = Join-Path $Destination $Name
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    # tar.exe ships with Windows 10 1803 and later.
    & tar -xzf $archive -C $extractRoot
    if ($LASTEXITCODE -ne 0) { throw "failed to extract $Name (tar exit $LASTEXITCODE)" }

    $packageRoot = Join-Path $extractRoot 'package'
    if (-not (Test-Path -LiteralPath $packageRoot)) { throw "unexpected archive layout for $Name" }
    return $packageRoot
}

function Install-KanaVendor {
    Write-Step 'Checking kana vendor files'

    $vendorRoot = Join-Path $TargetDir 'kana\vendor'
    $missing = @(if ($Force) { $script:VendorFiles } else { Get-MissingVendorFile $vendorRoot })

    if ($missing.Count -eq 0) {
        $script:Stats.Skipped += $script:VendorFiles.Count
        Write-Host "    all $($script:VendorFiles.Count) files present - skipping download" -ForegroundColor Green
        return
    }

    if ($Force) { Write-Host '    -Force specified; re-downloading' }
    else { Write-Host "    $($missing.Count) of $($script:VendorFiles.Count) files missing; downloading" }

    if (-not $PSCmdlet.ShouldProcess($vendorRoot, 'install vendor files')) { return }

    $staging = Join-Path ([IO.Path]::GetTempPath()) ("text-tools-vendor-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    try {
        $kuroshiro = Expand-NpmPackage 'kuroshiro' $staging
        $kuromoji = Expand-NpmPackage 'kuromoji' $staging

        $sources = @{ 'kuroshiro.min.js' = Join-Path $kuroshiro 'dist\kuroshiro.min.js'
                      'kuromoji.js'      = Join-Path $kuromoji  'build\kuromoji.js' }
        foreach ($file in $script:DictionaryFiles) {
            $sources[$file] = Join-Path $kuromoji ('dict\' + (Split-Path -Leaf $file))
        }

        foreach ($file in $script:VendorFiles) {
            Copy-IfDifferent $sources[$file] (Join-Path $vendorRoot $file) "kana\vendor\$file"
        }
    } catch {
        Write-Warn "could not install kana vendor files: $($_.Exception.Message)"
        Write-Warn 'Japanese kana annotation (Ctrl+Win+S) will be unavailable; translation is unaffected.'
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region stage 3: configuration ------------------------------------------------

function Compare-JsonShape($Expected, $Actual, [string] $Prefix = '') {
    $differences = [Collections.Generic.List[string]]::new()
    if ($null -eq $Expected -or $Expected -isnot [psobject]) { return $differences }

    foreach ($property in $Expected.PSObject.Properties) {
        $name = if ($Prefix) { "$Prefix.$($property.Name)" } else { $property.Name }
        $other = if ($Actual -is [psobject]) { $Actual.PSObject.Properties[$property.Name] } else { $null }

        if ($null -eq $other) {
            $differences.Add("$name (missing locally)")
        } elseif ($property.Value -is [psobject] -and $property.Value -isnot [string] -and
                  $property.Value -isnot [ValueType] -and $property.Value -isnot [Array]) {
            foreach ($nested in Compare-JsonShape $property.Value $other.Value $name) { $differences.Add($nested) }
        }
    }
    return $differences.ToArray()
}

# auth.json holds real API keys, so it is written once and never touched again.
function Install-ConfigFile([string] $Template, [string] $Destination, [string] $Label, [switch] $NeverOverwrite) {
    $exists = Test-Path -LiteralPath $Destination -PathType Leaf

    if (-not $exists) {
        if (-not $PSCmdlet.ShouldProcess($Destination, 'create')) { return }
        New-ParentDirectory $Destination
        Copy-Item -LiteralPath $Template -Destination $Destination -Force
        $script:Stats.Created++
        Write-Item 'created' $Label Green
        return
    }

    if ($NeverOverwrite) {
        $script:Stats.Skipped++
        Write-Item 'kept' "$Label (contains your API keys)" DarkGray
        return
    }

    if ((Get-FileHashOrNull $Template) -eq (Get-FileHashOrNull $Destination)) {
        $script:Stats.Unchanged++
        return
    }

    if (-not $Force) {
        $script:Stats.Skipped++
        Write-Item 'kept' $Label DarkGray
        # Distinct names: PowerShell variables are case-insensitive, so $template
        # here would silently overwrite the $Template parameter.
        $differences = @()
        $parsed = $false
        try {
            $templateJson = Get-Content -LiteralPath $Template -Raw -Encoding UTF8 | ConvertFrom-Json
            $currentJson = Get-Content -LiteralPath $Destination -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $currentJson) { throw 'file is empty or not a JSON object' }
            $differences = @(Compare-JsonShape $templateJson $currentJson)
            $parsed = $true
        } catch {
            Write-Warn "$Label could not be compared to the template: $($_.Exception.Message)"
        }
        if (-not $parsed) { return }
        if ($differences.Count -gt 0) {
            Write-Warn "$Label is missing keys present in the template: $($differences -join ', ')"
        } else {
            Write-Warn "$Label differs from the template (customised values); left untouched"
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, 'overwrite')) { return }
    $backup = "$Destination.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Destination -Destination $backup -Force
    Copy-Item -LiteralPath $Template -Destination $Destination -Force
    $script:Stats.Updated++
    Write-Item 'updated' "$Label (backup: $(Split-Path -Leaf $backup))" Green
}

function Install-Configuration {
    Write-Step "Deploying configuration to $ConfigDir"

    $map = @(
        @{ Template = 'config\ahk\settings.example.json';          Target = 'ahk\settings.json' }
        @{ Template = 'config\translate\config.example.json';      Target = 'translate\config.json' }
        @{ Template = 'config\translate\models.example.json';      Target = 'translate\models.json' }
    )

    foreach ($entry in $map) {
        Install-ConfigFile (Join-Path $RepoRoot $entry.Template) (Join-Path $ConfigDir $entry.Target) $entry.Target
    }

    Install-ConfigFile (Join-Path $RepoRoot 'config\translate\auth.example.json') `
        (Join-Path $ConfigDir 'translate\auth.json') 'translate\auth.json' -NeverOverwrite
}

#endregion

#region main ------------------------------------------------------------------

Write-Host ''
Write-Host 'text-tools deploy' -ForegroundColor White

if ($Update) { Invoke-RepositoryUpdate }

Install-ProgramFiles
if ($SkipVendor) {
    Write-Step 'Checking kana vendor files'
    Write-Host '    -SkipVendor specified; skipping'
} else {
    Install-KanaVendor
}
Install-Configuration

Write-Step 'Summary'
Write-Host ('    created {0}   updated {1}   unchanged {2}   skipped {3}' -f
    $script:Stats.Created, $script:Stats.Updated, $script:Stats.Unchanged, $script:Stats.Skipped)

if ($script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host "    $($script:Warnings.Count) warning(s) above" -ForegroundColor Yellow
}

$authPath = Join-Path $ConfigDir 'translate\auth.json'
$entryPoint = Join-Path $TargetDir 'auto_hotkey\text.ahk'

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host "  1. Add your API keys to $authPath"
Write-Host "     (not needed if you only use the free 'google' engine)"
Write-Host "  2. Run $entryPoint"
Write-Host '  3. Select text anywhere, then press Ctrl+Win+A to translate or Ctrl+Win+S for kana'
Write-Host ''

#endregion
