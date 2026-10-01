# Config.ps1 - Loading and validating the three translate configuration files.
#
# Dot-sourced by Translate.Core.psm1. Configuration lives in one directory
# resolved from TRANSLATE_CONFIG_DIR, then %USERPROFILE%\.config\translate:
#   config.json  general settings, model selection, proxy, system prompt
#   auth.json    API key per provider
#   models.json  provider endpoints and their model lists
#
# Every value is validated on read. Invalid configuration throws here rather
# than failing later against a live API.

# ---------------------------------------------------------------------------
# Get-TranslateCommonConfig
#   Load config.json and the settings both modes need. Returned Threshold is
#   the Chinese-character ratio above which auto-detection picks English as
#   the target.
# ---------------------------------------------------------------------------
function Get-TranslateCommonConfig {
    $directory =
        if ($env:TRANSLATE_CONFIG_DIR) {
            $env:TRANSLATE_CONFIG_DIR
        } else {
            # Not the automatic $HOME: it resolves separately and would drift.
            Join-Path $env:USERPROFILE '.config\translate'
        }
    $directory = Resolve-FileSystemPath $directory
    $settings = Read-JsonConfigFile (Join-Path $directory 'config.json')

    $thresholdNode = Get-JsonMember $settings 'chineseRatioThreshold'
    $thresholdText = '0.3'
    if ($null -ne $thresholdNode -and $thresholdNode.Kind -in @('number', 'string')) {
        $thresholdText = $thresholdNode.Value
    } elseif ($null -ne $thresholdNode) {
        throw 'chineseRatioThreshold must be a number from 0 to 1'
    }

    # Parsed with the invariant culture so a comma decimal separator in the
    # host's locale cannot change how the threshold is read.
    $threshold = 0.0
    if ($thresholdText -cnotmatch '\A([0-9]+(\.[0-9]*)?|\.[0-9]+)\z' -or
        -not [double]::TryParse(
            $thresholdText,
            [Globalization.NumberStyles]::AllowDecimalPoint,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$threshold) -or
        $threshold -lt 0 -or $threshold -gt 1) {
        throw 'chineseRatioThreshold must be a number from 0 to 1'
    }

    return [pscustomobject]@{
        Directory = $directory
        Settings  = $settings
        Threshold = $threshold
    }
}

# ---------------------------------------------------------------------------
# Get-TranslateConfig [<ModelOverride>]
#   Load and cross-validate all three files for AI mode, returning everything
#   an adapter needs to build one request. ModelOverride takes precedence over
#   the model named in config.json.
# ---------------------------------------------------------------------------
function Get-TranslateConfig([string] $ModelOverride) {
    $common = Get-TranslateCommonConfig
    $directory = $common.Directory
    $settings = $common.Settings
    $auth = Read-JsonConfigFile (Join-Path $directory 'auth.json')
    $models = Read-JsonConfigFile (Join-Path $directory 'models.json')

    $selected = $ModelOverride
    if ([string]::IsNullOrWhiteSpace($selected)) {
        $selection = Get-JsonMember $settings 'model'
        if ($null -eq $selection -or $selection.Kind -ne 'string' -or
            [string]::IsNullOrWhiteSpace($selection.Value)) {
            throw 'config.json must define model as a non-empty string when -Model is not supplied or is blank'
        }

        $selected = $selection.Value
    }

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

    # systemPrompt moved to the top level; ai.systemPrompt is the older location.
    $promptNode = Get-JsonMember $settings 'systemPrompt'
    if ($null -eq $promptNode -or $promptNode.Kind -ne 'string') {
        $promptNode = Get-JsonMember (Get-JsonMember $settings 'ai') 'systemPrompt'
    }

    $systemPrompt = Get-JsonString $promptNode
    if (-not $systemPrompt) {
        $systemPrompt = 'You are a direct translation engine. Output only the translated text and preserve paragraph breaks.'
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
        Threshold      = $common.Threshold
        SystemPrompt   = $systemPrompt
        Proxy          = $proxyUrl
        ConnectTimeout = $connectTimeout
    }
}

# ---------------------------------------------------------------------------
# Get-DetectedTarget <Text> <Threshold>
#   Pick the translation target for -Target auto: 'en' when the Chinese share
#   of the letters counted reaches Threshold, otherwise 'zh'. Text with no
#   Chinese or Latin letters at all falls through to 'zh'.
# ---------------------------------------------------------------------------
function Get-DetectedTarget([string] $Text, [double] $Threshold) {
    # Preserve the legacy UTF-8 E4 B8 80 through E9 BF BF counting range.
    $chinese = [regex]::Matches($Text, '[\u4e00-\u9fff]').Count
    $english = [regex]::Matches($Text, '[A-Za-z]').Count
    if ($chinese + $english -gt 0 -and $chinese / ($chinese + $english) -ge $Threshold) {
        return 'en'
    }

    return 'zh'
}
