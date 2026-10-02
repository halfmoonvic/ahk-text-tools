# Config.ps1 - Reading JSON configuration files and the shared proxy settings.
#
# Dot-sourced by the modules that read configuration. Every value is validated
# on read, so invalid configuration throws here rather than failing later
# against a live service.

# ---------------------------------------------------------------------------
# Resolve-FileSystemPath <Path>
#   Resolve Path to a full filesystem path without requiring it to exist.
#   Rejects non-FileSystem providers so a path like Env:\FOO cannot be used
#   where a file is expected.
# ---------------------------------------------------------------------------
function Resolve-FileSystemPath([string] $Path) {
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'only FileSystem paths are supported'
    }

    return $resolved
}

# ---------------------------------------------------------------------------
# Get-ConfigDirectory
#   Return the directory holding config.json, models.json and auth.json:
#   TEXT_TOOLS_CONFIG_DIR when set, otherwise %USERPROFILE%\.config\text-tools.
#   kana.ps1 and text.ahk resolve the same directory on their own.
# ---------------------------------------------------------------------------
function Get-ConfigDirectory {
    $directory =
        if ($env:TEXT_TOOLS_CONFIG_DIR) {
            $env:TEXT_TOOLS_CONFIG_DIR
        } else {
            # Not the automatic $HOME: it resolves separately and would drift.
            Join-Path $env:USERPROFILE '.config\text-tools'
        }
    return Resolve-FileSystemPath $directory
}

# ---------------------------------------------------------------------------
# Get-ConfigSection <Settings> <Name>
#   Return one tool's section of config.json, or $null when it is absent so
#   every value in it falls back to its default.
# ---------------------------------------------------------------------------
function Get-ConfigSection($Settings, [string] $Name) {
    $section = Get-JsonMember $Settings $Name
    if ($null -ne $section -and $section.Kind -ne 'object') {
        throw "config.json: $Name must be an object"
    }

    return $section
}

# ---------------------------------------------------------------------------
# Read-JsonConfigFile <Path>
#   Read one configuration file and return its parsed JSON object node.
#   Decoding is strict UTF-8, so a mis-encoded file is reported as invalid
#   rather than silently producing replacement characters.
# ---------------------------------------------------------------------------
function Read-JsonConfigFile([string] $Path) {
    if (-not [IO.File]::Exists($Path)) {
        throw "missing configuration file: $Path"
    }

    try {
        $node = ConvertFrom-StrictJson ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)))
    } catch {
        throw "invalid JSON in $Path"
    }

    if ($node.Kind -ne 'object') {
        throw "configuration must be a JSON object: $Path"
    }

    return $node
}

# ---------------------------------------------------------------------------
# Get-ProxyUrl <Settings> <Provider> <Scheme> [-HttpOnly]
#   Return the configured proxy URL for Provider, or '' when that provider is
#   not listed under proxy.providers.
#
#   -HttpOnly applies the narrower rules the vendored Google Shell script can
#   parse; the AI adapters pass the URL straight to curl and accept any
#   supported scheme.
# ---------------------------------------------------------------------------
function Get-ProxyUrl($Settings, [string] $Provider, [string] $Scheme, [switch] $HttpOnly) {
    $proxy = Get-JsonMember $Settings 'proxy'
    $providers = Get-JsonMember $proxy 'providers'
    if ($null -eq $providers -or $providers.Kind -ne 'array') {
        return ''
    }

    foreach ($item in $providers.Value) {
        if ((Get-JsonString $item) -cne $Provider) {
            continue
        }

        $url = Get-JsonString (Get-JsonMember $proxy $Scheme)
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h') -or
            -not $uri.Host -or
            $url -match '[\x00-\x20\x7f]') {
            throw "invalid $Scheme proxy for provider '$Provider'"
        }

        if ($HttpOnly) {
            if ($uri.Scheme -ne 'http' -or
                $uri.HostNameType -eq [UriHostNameType]::IPv6 -or
                $uri.AbsolutePath -ne '/' -or
                $uri.Query -or
                $uri.Fragment) {
                throw 'Google Shell supports only an HTTP proxy with a hostname or IPv4 address and optional credentials'
            }

            # The legacy parser requires an explicit port, even for port 80.
            return 'http://' + $(if ($uri.UserInfo) { $uri.UserInfo + '@' }) + $uri.Host + ':' + $uri.Port
        }

        return $url
    }

    return ''
}
