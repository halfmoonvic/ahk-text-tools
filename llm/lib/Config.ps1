# Config.ps1 - Loading and validating the model configuration for one request.
#
# Dot-sourced by Llm.Core.psm1. The caller names the configuration directory:
#   config.json  thinking levels, connect timeout, proxy
#   auth.json    API key per provider
#   models.json  provider endpoints and their model lists
#
# Every value is validated on read. Invalid configuration throws here rather
# than failing later against a live API.

# ---------------------------------------------------------------------------
# Get-LlmConfig <Directory> <Selected>
#   Load and cross-validate the three files for Selected, a provider/model
#   identifier, returning everything an adapter needs to build one request.
# ---------------------------------------------------------------------------
function Get-LlmConfig([string] $Directory, [string] $Selected) {
    $settings = Read-JsonConfigFile (Join-Path $Directory 'config.json')
    $auth = Read-JsonConfigFile (Join-Path $Directory 'auth.json')
    $models = Read-JsonConfigFile (Join-Path $Directory 'models.json')

    # Split only the provider separator. Model IDs and map keys may contain / or .
    $separator = $selected.IndexOf('/')
    if ($separator -le 0 -or $separator -eq $selected.Length - 1) {
        throw "invalid model identifier: $selected"
    }

    $providerName = $selected.Substring(0, $separator)
    $modelName = $selected.Substring($separator + 1)
    $provider = Get-JsonMember (Get-JsonMember $models 'providers') $providerName
    if ($null -eq $provider -or $provider.Kind -ne 'object') {
        throw "unknown provider: $providerName"
    }

    $modelList = Get-JsonMember $provider 'models'
    $model = $null
    if ($null -ne $modelList -and $modelList.Kind -eq 'array') {
        foreach ($candidate in $modelList.Value) {
            if ((Get-JsonString (Get-JsonMember $candidate 'id')) -ceq $modelName) {
                $model = $candidate
                break
            }
        }
    }

    if ($null -eq $model) {
        throw "unknown model: $selected"
    }

    $api = Get-JsonString (Get-JsonMember $provider 'api')
    if ($api -cnotin @('openai-completions', 'openai-responses', 'anthropic-messages')) {
        throw "unsupported api type: $api"
    }

    # Credentials belong in auth.json, so a baseUrl carrying userinfo is rejected.
    $base = Get-JsonString (Get-JsonMember $provider 'baseUrl')
    $uri = $null
    if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        $uri.UserInfo) {
        throw "invalid baseUrl for provider '$providerName'"
    }

    $key = Get-JsonString (Get-JsonMember $auth $providerName)
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "missing API key for provider '$providerName'"
    }

    # Control characters would corrupt the Authorization header.
    if ($key -match '[\x00-\x1f\x7f]') {
        throw "invalid API key for provider '$providerName'"
    }

    $thinkingNode = Get-JsonMember (Get-JsonMember $settings 'modelThinkingLevels') $selected
    if ($null -eq $thinkingNode) {
        $thinkingNode = Get-JsonMember $settings 'defaultThinkingLevel'
    }

    $thinking =
        if ($null -eq $thinkingNode) {
            'off'
        } else {
            Get-JsonString $thinkingNode
        }
    if ($thinking -cnotin @('off', 'low', 'medium', 'high')) {
        throw "invalid thinking level for model '$selected'; expected off, low, medium, or high"
    }

    $proxyUrl = Get-ProxyUrl $settings $providerName $uri.Scheme

    $timeoutNode = Get-JsonMember $settings 'connectTimeoutSeconds'
    $connectTimeout = 10
    if ($null -ne $timeoutNode) {
        if ($timeoutNode.Kind -ne 'number' -or
            $timeoutNode.Value -cnotmatch '\A[1-9][0-9]{0,5}\z') {
            throw 'connectTimeoutSeconds must be a positive integer'
        }

        $connectTimeout = [int]$timeoutNode.Value
    }

    return [pscustomobject]@{
        Provider       = $providerName
        Model          = $modelName
        Api            = $api
        BaseUrl        = $base
        ApiKey         = $key
        Thinking       = $thinking
        Proxy          = $proxyUrl
        ConnectTimeout = $connectTimeout
    }
}
