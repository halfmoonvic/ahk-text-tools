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
    Install (or refresh) into ~\.local\bin\text-tools, with translate.ps1 and
    kana.ps1 shims in ~\.local\bin and configuration in ~\.config\text-tools.
    Configuration from the older ~\.config\translate and ~\.config\ahk layout
    is migrated into any file that does not exist yet.

.EXAMPLE
    .\deploy.ps1 -Update
    Pull the latest commits, then deploy.

.EXAMPLE
    .\deploy.ps1 -TargetDir D:\tools
    Install into D:\tools\text-tools with the shims in D:\tools; configuration
    still goes to ~\.config\text-tools.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $TargetDir = (Join-Path $env:USERPROFILE '.local\bin'),
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
# The shims find the program by this fixed name next to them.
$ProgramDir = Join-Path $TargetDir 'text-tools'
# Not a parameter: it must be the directory the tools read, so it follows
# Get-ConfigDirectory in common\Config.ps1.
$ConfigDir =
    if ($env:TEXT_TOOLS_CONFIG_DIR) {
        $env:TEXT_TOOLS_CONFIG_DIR
    } else {
        Join-Path $env:USERPROFILE '.config\text-tools'
    }
# Where earlier versions kept their configuration. Only ever read, to migrate it.
$LegacyConfigDir = Join-Path $env:USERPROFILE '.config'
$script:Stats = [ordered]@{ Created = 0; Updated = 0; Unchanged = 0; Skipped = 0 }
$script:Warnings = [Collections.Generic.List[string]]::new()
$script:Migrated = $false

# The strict parser keeps key order and number tokens, so migrated values are
# written back exactly as the user had them.
. (Join-Path $RepoRoot 'common\Json.ps1')

#region helpers ---------------------------------------------------------------

# ---------------------------------------------------------------------------
# Write-Step <Message>
#   Announce the start of a deployment stage.
# ---------------------------------------------------------------------------
function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Write-Item <State> <Path> [<Color>]
#   Report one file's outcome in an aligned two-column line.
# ---------------------------------------------------------------------------
function Write-Item([string] $State, [string] $Path, [ConsoleColor] $Color = 'Gray') {
    Write-Host ('    {0,-10} {1}' -f $State, $Path) -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Write-Warn <Message>
#   Record a non-fatal problem and echo it. Collected warnings are replayed in
#   the final summary so they are not lost in the scroll.
# ---------------------------------------------------------------------------
function Write-Warn([string] $Message) {
    $script:Warnings.Add($Message)
    Write-Host "    warning   $Message" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Get-FileHashOrNull <Path>
#   SHA-256 of a file, or $null when it does not exist. The null return is how
#   callers distinguish "absent" from "present but different".
# ---------------------------------------------------------------------------
function Get-FileHashOrNull([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# ---------------------------------------------------------------------------
# New-ParentDirectory <Path>
#   Create the directory that will hold Path, if it is missing.
# ---------------------------------------------------------------------------
function New-ParentDirectory([string] $Path) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Copy-IfDifferent <Source> <Destination> <Label>
#   Copy only when the contents differ, so repeat runs leave timestamps alone
#   and the summary counts reflect real changes.
# ---------------------------------------------------------------------------
function Copy-IfDifferent([string] $Source, [string] $Destination, [string] $Label) {
    $sourceHash = Get-FileHashOrNull $Source
    if ($null -eq $sourceHash) {
        throw "missing source file: $Source"
    }

    $destinationHash = Get-FileHashOrNull $Destination

    if ($sourceHash -eq $destinationHash) {
        $script:Stats.Unchanged++
        return
    }

    $isNew = $null -eq $destinationHash
    $action =
        if ($isNew) {
            'create'
        } else {
            'update'
        }
    if (-not $PSCmdlet.ShouldProcess($Destination, $action)) {
        return
    }

    New-ParentDirectory $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    if ($isNew) {
        $script:Stats.Created++
        Write-Item 'created' $Label Green
    } else {
        $script:Stats.Updated++
        Write-Item 'updated' $Label Green
    }
}

#endregion

#region stage 0: optional git pull --------------------------------------------

# ---------------------------------------------------------------------------
# Invoke-RepositoryUpdate
#   Fast-forward the checkout before deploying. Refuses to touch a dirty tree
#   and downgrades every failure to a warning: a failed pull should still
#   deploy whatever is already checked out.
# ---------------------------------------------------------------------------
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

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'git pull --ff-only')) {
        return
    }

    & git -C $RepoRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'git pull failed; deploying the current checkout'
    }
}

#endregion

#region stage 1: program files ------------------------------------------------

# text.ahk derives the project root by stripping "\ahk\<file>" from its
# own path, and run-batch.ps1 loads each tool's <tool>\<Tool>.Core.psm1 from
# there. The two-level layout below is therefore mandatory - do not flatten it.
# ---------------------------------------------------------------------------
# Install-ProgramFiles
#   Copy the scripts into ProgramDir, preserving the repository's directory
#   layout for the reason described above, then put the terminal shims in
#   TargetDir.
# ---------------------------------------------------------------------------
function Install-ProgramFiles {
    Write-Step "Deploying program files to $ProgramDir"

    $files = @(
        'ahk\text.ahk'
        'ahk\json.ahk'
        'ahk\proc.ahk'
        'ahk\run-batch.ps1'
        'translate.ps1'
        'kana.ps1'
        'common\Config.ps1'
        'common\Json.ps1'
        'common\Process.ps1'
        'llm\Llm.Core.psm1'
        'llm\lib\Config.ps1'
        'llm\lib\Curl.ps1'
        'llm\lib\Sse.ps1'
        'llm\adapters\AnthropicMessages.ps1'
        'llm\adapters\OpenAICompletions.ps1'
        'llm\adapters\OpenAIResponses.ps1'
        'translate\Translate.Core.psm1'
        'translate\google'
        'translate\lib\Config.ps1'
        'translate\lib\Google.ps1'
        'translate\lib\google-launch.sh'
        'kana\Kana.Core.psm1'
        'kana\kana.mjs'
        'kana\lib\Config.ps1'
        'kana\lib\Kuroshiro.ps1'
    )

    foreach ($file in $files) {
        Copy-IfDifferent (Join-Path $RepoRoot $file) (Join-Path $ProgramDir $file) $file
    }

    foreach ($shim in 'translate.ps1', 'kana.ps1') {
        Copy-IfDifferent (Join-Path $RepoRoot "shims\$shim") (Join-Path $TargetDir $shim) "shim $shim"
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

# ---------------------------------------------------------------------------
# Get-MissingVendorFile <VendorRoot>
#   List vendor files that are absent or zero-length. Empty files count as
#   missing so an interrupted download is retried rather than trusted.
# ---------------------------------------------------------------------------
function Get-MissingVendorFile([string] $VendorRoot) {
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($file in $script:VendorFiles) {
        $path = Join-Path $VendorRoot $file
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.Length -eq 0) {
            $missing.Add($file)
        }
    }
    return $missing.ToArray()
}

# ---------------------------------------------------------------------------
# Expand-NpmPackage <Name> <Destination>
#   Download the latest tarball for a package and extract it. Uses the
#   registry API and bundled tar directly, so npm need not be installed.
# ---------------------------------------------------------------------------
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
    if ($LASTEXITCODE -ne 0) {
        throw "failed to extract $Name (tar exit $LASTEXITCODE)"
    }

    $packageRoot = Join-Path $extractRoot 'package'
    if (-not (Test-Path -LiteralPath $packageRoot)) {
        throw "unexpected archive layout for $Name"
    }
    return $packageRoot
}

# ---------------------------------------------------------------------------
# Install-KanaVendor
#   Fetch the kuroshiro and kuromoji files the kana tool needs. Skipped when
#   everything is already present unless -Force is given.
# ---------------------------------------------------------------------------
function Install-KanaVendor {
    Write-Step 'Checking kana vendor files'

    $vendorRoot = Join-Path $ProgramDir 'kana\vendor'
    $missing = @(if ($Force) { $script:VendorFiles } else { Get-MissingVendorFile $vendorRoot })

    if ($missing.Count -eq 0) {
        $script:Stats.Skipped += $script:VendorFiles.Count
        Write-Host "    all $($script:VendorFiles.Count) files present - skipping download" -ForegroundColor Green
        return
    }

    if ($Force) {
        Write-Host '    -Force specified; re-downloading'
    } else {
        Write-Host "    $($missing.Count) of $($script:VendorFiles.Count) files missing; downloading"
    }

    if (-not $PSCmdlet.ShouldProcess($vendorRoot, 'install vendor files')) {
        return
    }

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
        Write-Warn 'Japanese kana annotation (Win+Alt+S by default) will be unavailable; translation is unaffected.'
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region stage 3: configuration ------------------------------------------------

# ---------------------------------------------------------------------------
# Compare-JsonShape <Expected> <Actual> [<Prefix>]
#   Return dotted names of keys present in Expected but not in Actual,
#   recursing into nested objects. Compares structure only, never values, so
#   an existing config is reported as outdated without exposing its contents.
# ---------------------------------------------------------------------------
function Compare-JsonShape($Expected, $Actual, [string] $Prefix = '') {
    $differences = [Collections.Generic.List[string]]::new()
    if ($null -eq $Expected -or $Expected -isnot [psobject]) {
        return $differences
    }

    foreach ($property in $Expected.PSObject.Properties) {
        $name =
            if ($Prefix) {
                "$Prefix.$($property.Name)"
            } else {
                $property.Name
            }
        $other =
            if ($Actual -is [psobject]) {
                $Actual.PSObject.Properties[$property.Name]
            } else {
                $null
            }

        if ($null -eq $other) {
            $differences.Add("$name (missing locally)")
        } elseif ($property.Value -is [psobject] -and $property.Value -isnot [string] -and
                  $property.Value -isnot [ValueType] -and $property.Value -isnot [Array]) {
            foreach ($nested in Compare-JsonShape $property.Value $other.Value $name) {
                $differences.Add($nested)
            }
        }
    }
    return $differences.ToArray()
}

# ---------------------------------------------------------------------------
# Get-TemplateDifference <Template> <Json>
#   Return the keys the template has that the configuration text Json lacks.
# ---------------------------------------------------------------------------
function Get-TemplateDifference([string] $Template, [string] $Json) {
    # Distinct names: PowerShell variables are case-insensitive, so $template
    # here would silently overwrite the $Template parameter.
    $templateJson = Get-Content -LiteralPath $Template -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentJson =
        if (-not [string]::IsNullOrWhiteSpace($Json)) {
            $Json | ConvertFrom-Json
        }
    if ($null -eq $currentJson) {
        throw 'file is empty or not a JSON object'
    }
    return @(Compare-JsonShape $templateJson $currentJson)
}

# auth.json holds real API keys, so it is written once and never touched again.
# ---------------------------------------------------------------------------
# Install-ConfigFile <Template> <Destination> <Label> [-NeverOverwrite]
#   Install a configuration file from its example template. An existing file
#   is never overwritten silently; it is only reported when the template has
#   gained keys it lacks.
# ---------------------------------------------------------------------------
function Install-ConfigFile([string] $Template, [string] $Destination, [string] $Label, [switch] $NeverOverwrite) {
    $exists = Test-Path -LiteralPath $Destination -PathType Leaf

    if (-not $exists) {
        if (-not $PSCmdlet.ShouldProcess($Destination, 'create')) {
            return
        }
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
        $differences = @()
        $parsed = $false
        try {
            $differences = @(Get-TemplateDifference $Template (Get-Content -LiteralPath $Destination -Raw -Encoding UTF8))
            $parsed = $true
        } catch {
            Write-Warn "$Label could not be compared to the template: $($_.Exception.Message)"
        }
        if (-not $parsed) {
            return
        }
        if ($differences.Count -gt 0) {
            Write-Warn "$Label is missing keys present in the template: $($differences -join ', ')"
        } else {
            Write-Warn "$Label differs from the template (customised values); left untouched"
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, 'overwrite')) {
        return
    }
    $backup = "$Destination.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Destination -Destination $backup -Force
    Copy-Item -LiteralPath $Template -Destination $Destination -Force
    $script:Stats.Updated++
    Write-Item 'updated' "$Label (backup: $(Split-Path -Leaf $backup))" Green
}

# ---------------------------------------------------------------------------
# Read-LegacyJson <Relative>
#   Parse one old configuration file under LegacyConfigDir.
# ---------------------------------------------------------------------------
function Read-LegacyJson([string] $Relative) {
    $path = Join-Path $LegacyConfigDir $Relative
    try {
        $node = ConvertFrom-StrictJson ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true)))
    } catch {
        throw "$Relative is not valid JSON"
    }
    if ($node.Kind -ne 'object') {
        throw "$Relative is not a JSON object"
    }
    return $node
}

# ---------------------------------------------------------------------------
# Select-JsonMember <Node> <Names> <Unknown> [<Prefix>]
#   Copy the members of Node named in Names, in that order, into a new ordered
#   dictionary. Member names not in Names are added to Unknown, dotted with
#   Prefix, so they can be reported as not migrated.
# ---------------------------------------------------------------------------
function Select-JsonMember($Node, [string[]] $Names, $Unknown, [string] $Prefix = '') {
    $selected = [ordered]@{}
    if ($null -eq $Node) {
        return $selected
    }
    if ($Node.Kind -ne 'object') {
        $Unknown.Add($Prefix.TrimEnd('.'))
        return $selected
    }
    foreach ($name in $Names) {
        if ($Node.Value.ContainsKey($name)) {
            $selected[$name] = $Node.Value[$name]
        }
    }
    foreach ($name in $Node.Value.Keys) {
        if ($name -cnotin $Names) {
            $Unknown.Add("$Prefix$name")
        }
    }
    return $selected
}

# ---------------------------------------------------------------------------
# Write-NotMigrated <Relative> <Unknown>
#   Report the keys of an old file that have no place in the new layout.
# ---------------------------------------------------------------------------
function Write-NotMigrated([string] $Relative, $Unknown) {
    if ($Unknown.Count -gt 0) {
        Write-Warn "$Relative`: not migrated: $($Unknown -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# New-MigratedConfig
#   Build config.json from the old translate\config.json and the kana options
#   of the old ahk\settings.json.
# ---------------------------------------------------------------------------
function New-MigratedConfig {
    $old = Read-LegacyJson 'translate\config.json'
    $unknown = [Collections.Generic.List[string]]::new()
    $top = Select-JsonMember $old @('proxy', 'defaultThinkingLevel', 'modelThinkingLevels',
        'connectTimeoutSeconds', 'model', 'chineseRatioThreshold', 'ai') $unknown

    $result = [ordered]@{}
    if ($top.Contains('proxy')) {
        $result['proxy'] = $top['proxy']
    }

    $llm = [ordered]@{}
    foreach ($name in 'defaultThinkingLevel', 'modelThinkingLevels', 'connectTimeoutSeconds') {
        if ($top.Contains($name)) {
            $llm[$name] = $top[$name]
        }
    }
    if ($llm.Count -gt 0) {
        $result['llm'] = $llm
    }

    $translate = [ordered]@{}
    if ($top.Contains('model')) {
        $translate['engine'] = $top['model']
    }
    if ($top.Contains('chineseRatioThreshold')) {
        $translate['chineseRatioThreshold'] = $top['chineseRatioThreshold']
    }
    $ai = Select-JsonMember $top['ai'] @('systemPrompt', 'userPrompt') $unknown 'ai.'
    if ($ai.Count -gt 0) {
        $translate['ai'] = $ai
    }
    if ($translate.Count -gt 0) {
        $result['translate'] = $translate
    }
    Write-NotMigrated 'translate\config.json' $unknown

    # Only the kana options are taken here; New-MigratedSettings reports the rest.
    if (Test-Path -LiteralPath (Join-Path $LegacyConfigDir 'ahk\settings.json') -PathType Leaf) {
        $settings = Read-LegacyJson 'ahk\settings.json'
        $ignored = [Collections.Generic.List[string]]::new()
        $kana = Select-JsonMember (Get-JsonMember (Get-JsonMember $settings 'japanese') 'kana') @('to', 'mode') $ignored
        if ($kana.Count -gt 0) {
            $result['kana'] = $kana
        }
    }

    return $result
}

# ---------------------------------------------------------------------------
# New-MigratedSettings
#   Build settings.json from the old ahk\settings.json: the engine list moves
#   under engines, and the kana options move to config.json.
# ---------------------------------------------------------------------------
function New-MigratedSettings {
    $old = Read-LegacyJson 'ahk\settings.json'
    $unknown = [Collections.Generic.List[string]]::new()
    $top = Select-JsonMember $old @('translate', 'hotkeys', 'ui', 'japanese') $unknown

    $result = [ordered]@{}
    if ($top.Contains('translate')) {
        $result['engines'] = [ordered]@{ translate = $top['translate'] }
    }
    foreach ($name in 'hotkeys', 'ui') {
        if ($top.Contains($name)) {
            $result[$name] = $top[$name]
        }
    }

    $japanese = Select-JsonMember $top['japanese'] @('kana') $unknown 'japanese.'
    [void](Select-JsonMember $japanese['kana'] @('to', 'mode') $unknown 'japanese.kana.')
    Write-NotMigrated 'ahk\settings.json' $unknown
    return $result
}

# ---------------------------------------------------------------------------
# New-MigratedModels
#   Build models.json from the providers of the old translate\models.json.
# ---------------------------------------------------------------------------
function New-MigratedModels {
    $old = Read-LegacyJson 'translate\models.json'
    $unknown = [Collections.Generic.List[string]]::new()
    $top = Select-JsonMember $old @('providers') $unknown
    if (-not $top.Contains('providers') -or $top['providers'].Kind -ne 'object') {
        throw 'translate\models.json has no providers object'
    }
    Write-NotMigrated 'translate\models.json' $unknown
    return $top['providers']
}

# ---------------------------------------------------------------------------
# Format-ConfigJson <Value> [<Indent>]
#   Serialize a migrated value in the style of the templates: four-space
#   indentation, and arrays of scalars or objects of scalars inside an array
#   kept on one line. Strings go through ConvertTo-JsonString, so non-ASCII
#   text and characters such as < stay literal, unlike ConvertTo-Json in
#   Windows PowerShell.
# ---------------------------------------------------------------------------
function Format-ConfigJson($Value, [int] $Indent = 0, [switch] $InArray) {
    $members = $null
    $items = $null
    if ($Value -is [Collections.IDictionary]) {
        $members = $Value
    } elseif ($Value.Kind -eq 'object') {
        $members = $Value.Value
    } elseif ($Value.Kind -eq 'array') {
        $items = $Value.Value
    } else {
        return ConvertTo-StrictJson $Value
    }

    $outer = ' ' * (4 * $Indent)
    $inner = ' ' * (4 * ($Indent + 1))
    if ($null -ne $members) {
        if ($members.Count -eq 0) {
            return '{}'
        }
        $scalar = @($members.Values | Where-Object { $_ -is [Collections.IDictionary] -or $_.Kind -in @('object', 'array') }).Count -eq 0
        if ($InArray -and $scalar) {
            $pairs = foreach ($key in $members.Keys) {
                (ConvertTo-JsonString $key) + ': ' + (ConvertTo-StrictJson $members[$key])
            }
            return '{ ' + ($pairs -join ', ') + ' }'
        }
        $pairs = foreach ($key in $members.Keys) {
            $inner + (ConvertTo-JsonString $key) + ': ' + (Format-ConfigJson $members[$key] ($Indent + 1))
        }
        return "{`n" + ($pairs -join ",`n") + "`n$outer}"
    }

    if ($items.Count -eq 0) {
        return '[]'
    }
    if (@($items | Where-Object { $_.Kind -in @('object', 'array') }).Count -eq 0) {
        return '[' + (@($items | ForEach-Object { ConvertTo-StrictJson $_ }) -join ', ') + ']'
    }
    $lines = foreach ($item in $items) {
        $inner + (Format-ConfigJson $item ($Indent + 1) -InArray)
    }
    return "[`n" + ($lines -join ",`n") + "`n$outer]"
}

# ---------------------------------------------------------------------------
# Copy-LegacyConfig <Name> <Template> <Destination>
#   Create Destination from the old configuration instead of the template.
#   The old files are only read; a file that cannot be migrated is reported
#   and left uncreated, so fixing it and deploying again picks it up.
# ---------------------------------------------------------------------------
function Copy-LegacyConfig([string] $Name, [string] $Template, [string] $Destination) {
    if ($Name -eq 'auth.json') {
        if (-not $PSCmdlet.ShouldProcess($Destination, 'migrate from translate\auth.json')) {
            return
        }
        New-ParentDirectory $Destination
        [IO.File]::Copy((Join-Path $LegacyConfigDir 'translate\auth.json'), $Destination)
        $script:Stats.Created++
        $script:Migrated = $true
        Write-Item 'migrated' "$Name (from translate\auth.json; contents not shown)" Green
        return
    }

    try {
        $value = switch ($Name) {
            'config.json' { New-MigratedConfig }
            'settings.json' { New-MigratedSettings }
            'models.json' { New-MigratedModels }
        }
        $text = (Format-ConfigJson $value) + "`n"
    } catch {
        Write-Warn "could not migrate $Name`: $($_.Exception.Message); fix it and deploy again"
        return
    }

    try {
        $missing = @(Get-TemplateDifference $Template $text)
        if ($missing.Count -gt 0) {
            Write-Warn "$Name is missing keys present in the template: $($missing -join ', ')"
        }
    } catch {
        Write-Warn "$Name could not be compared to the template: $($_.Exception.Message)"
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, 'migrate from the old configuration')) {
        return
    }
    New-ParentDirectory $Destination
    [IO.File]::WriteAllText($Destination, $text, [Text.UTF8Encoding]::new($false))
    $script:Stats.Created++
    $script:Migrated = $true
    Write-Item 'migrated' $Name Green
}

# ---------------------------------------------------------------------------
# Install-Configuration
#   Install every configuration file into ConfigDir: migrated from the old
#   layout when the file is new and its old source exists, otherwise from the
#   template.
# ---------------------------------------------------------------------------
function Install-Configuration {
    Write-Step "Deploying configuration to $ConfigDir"

    $map = @(
        @{ Name = 'config.json';   Template = 'config\config.example.json';   Legacy = 'translate\config.json' }
        @{ Name = 'settings.json'; Template = 'config\settings.example.json'; Legacy = 'ahk\settings.json' }
        @{ Name = 'models.json';   Template = 'config\models.example.json';   Legacy = 'translate\models.json' }
        @{ Name = 'auth.json';     Template = 'config\auth.example.json';     Legacy = 'translate\auth.json' }
    )

    foreach ($entry in $map) {
        $template = Join-Path $RepoRoot $entry.Template
        $destination = Join-Path $ConfigDir $entry.Name
        if (-not (Test-Path -LiteralPath $destination) -and
            (Test-Path -LiteralPath (Join-Path $LegacyConfigDir $entry.Legacy) -PathType Leaf)) {
            Copy-LegacyConfig $entry.Name $template $destination
        } else {
            Install-ConfigFile $template $destination $entry.Name -NeverOverwrite:($entry.Name -eq 'auth.json')
        }
    }
}

#endregion

#region main ------------------------------------------------------------------

Write-Host ''
Write-Host 'text-tools deploy' -ForegroundColor White

if ($Update) {
    Invoke-RepositoryUpdate
}

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

$authPath = Join-Path $ConfigDir 'auth.json'
$entryPoint = Join-Path $ProgramDir 'ahk\text.ahk'

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host "  1. Add your API keys to $authPath"
Write-Host "     (not needed if you only use the free 'google' engine)"
Write-Host "  2. Run $entryPoint"
Write-Host '  3. Select text anywhere, then press Win+Alt+A to translate or Win+Alt+S for kana (the defaults)'
if ($script:Migrated) {
    Write-Host ''
    Write-Host "  Your old configuration was copied, not moved. Once everything works, delete" -ForegroundColor White
    Write-Host "  $(Join-Path $LegacyConfigDir 'translate') and $(Join-Path $LegacyConfigDir 'ahk\settings.json')." -ForegroundColor White
}
Write-Host ''

#endregion
