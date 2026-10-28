[CmdletBinding()]
param(
    [ValidateSet('search', 'page', 'player', 'parse')]
    [string]$Mode = 'player',

    [string]$Query = 'Sahara',

    [string]$Contact = $env:LIQUIPEDIA_CONTACT,

    [ValidateRange(1, 20)]
    [int]$Limit = 10,

    [ValidateSet('text', 'sections', 'links', 'templates')]
    [string]$ParseProperty = 'sections',

    [ValidateRange(1, 720)]
    [int]$CacheHours = 24,

    [switch]$Refresh,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Endpoint = 'https://liquipedia.net/fighters/api.php'
$ProjectName = 'Liquipedia-FGC-Query'
$ProjectVersion = '1.0'

function ConvertTo-QueryString {
    param([hashtable]$Parameters)

    $pairs = foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $encodedKey = [Uri]::EscapeDataString([string]$key)
        $encodedValue = [Uri]::EscapeDataString([string]$Parameters[$key])
        '{0}={1}' -f $encodedKey, $encodedValue
    }

    return ($pairs -join '&')
}

function Get-Sha256Text {
    param([string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-AppDataRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [IO.Path]::GetTempPath()
    }

    return (Join-Path $localAppData 'LiquipediaFgcQuery')
}

function Wait-LiquipediaRateLimit {
    param(
        [string]$StatePath,
        [bool]$IsParse
    )

    $mutex = New-Object System.Threading.Mutex($false, 'LiquipediaFgcQueryRateLimit')
    $lockTaken = $false

    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(60))
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            throw 'Timed out while waiting for the local Liquipedia rate-limit lock.'
        }

        $now = [DateTimeOffset]::UtcNow
        $lastNormal = [DateTimeOffset]::MinValue
        $lastParse = [DateTimeOffset]::MinValue

        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (Test-Property $state 'lastNormalUtc') {
                [DateTimeOffset]::TryParse([string]$state.lastNormalUtc, [ref]$lastNormal) | Out-Null
            }
            if (Test-Property $state 'lastParseUtc') {
                [DateTimeOffset]::TryParse([string]$state.lastParseUtc, [ref]$lastParse) | Out-Null
            }
        }

        $normalWait = 2.0 - ($now - $lastNormal).TotalSeconds
        $parseWait = if ($IsParse) { 30.0 - ($now - $lastParse).TotalSeconds } else { 0.0 }
        $waitSeconds = [Math]::Max(0.0, [Math]::Max($normalWait, $parseWait))

        if ($waitSeconds -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Ceiling($waitSeconds * 1000))
        }

        $requestTime = [DateTimeOffset]::UtcNow.ToString('o')
        $newState = [ordered]@{
            lastNormalUtc = $requestTime
            lastParseUtc = if ($IsParse) { $requestTime } else { $lastParse.ToString('o') }
        }

        $stateDirectory = Split-Path -Parent $StatePath
        if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
        }

        $newState | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-PageData {
    param([object]$ApiResponse)

    if (-not (Test-Property $ApiResponse 'query') -or -not (Test-Property $ApiResponse.query 'pages')) {
        throw 'Liquipedia response did not contain query.pages.'
    }

    $page = @($ApiResponse.query.pages)[0]
    if ($null -eq $page -or (Test-Property $page 'missing')) {
        throw "Liquipedia page was not found: $Query"
    }
    if (-not (Test-Property $page 'revisions') -or @($page.revisions).Count -eq 0) {
        throw "Liquipedia page has no readable revision: $Query"
    }

    $revision = @($page.revisions)[0]
    if (-not (Test-Property $revision 'slots') -or -not (Test-Property $revision.slots 'main')) {
        throw 'Liquipedia response did not contain the main revision slot.'
    }

    $mainSlot = $revision.slots.main
    if (-not (Test-Property $mainSlot 'content')) {
        throw 'Liquipedia response did not contain page wikitext.'
    }

    return [pscustomobject]@{
        title = $page.title
        pageId = $page.pageid
        revisionId = if (Test-Property $revision 'revid') { $revision.revid } else { $null }
        timestamp = if (Test-Property $revision 'timestamp') { $revision.timestamp } else { $null }
        wikitext = [string]$mainSlot.content
    }
}

function Get-PlayerFields {
    param([string]$Wikitext)

    $fieldNames = @(
        'id', 'localid', 'name', 'romanized_name', 'country', 'birth_date',
        'team', 'twitter', 'twitch', 'youtube', 'instagram'
    )

    $result = [ordered]@{}
    foreach ($fieldName in $fieldNames) {
        $pattern = '(?m)^\|' + [regex]::Escape($fieldName) + '[ \t]*=[ \t]*(.*)$'
        $match = [regex]::Match($Wikitext, $pattern)
        $value = if ($match.Success) { $match.Groups[1].Value.Trim() } else { '' }
        $result[$fieldName] = if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value }
    }

    return [pscustomobject]$result
}

try {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        throw 'Query cannot be empty.'
    }

    $apiParameters = [ordered]@{
        format = 'json'
        formatversion = '2'
    }

    switch ($Mode) {
        'search' {
            $apiParameters.action = 'query'
            $apiParameters.list = 'search'
            $apiParameters.srsearch = $Query
            $apiParameters.srnamespace = '0'
            $apiParameters.srlimit = [string]$Limit
        }
        { $_ -in @('page', 'player') } {
            $apiParameters.action = 'query'
            $apiParameters.prop = 'revisions'
            $apiParameters.titles = $Query
            $apiParameters.redirects = '1'
            $apiParameters.rvslots = 'main'
            $apiParameters.rvprop = 'ids|timestamp|content'
        }
        'parse' {
            $apiParameters.action = 'parse'
            $apiParameters.page = $Query
            $apiParameters.prop = $ParseProperty
            $apiParameters.redirects = '1'
        }
    }

    $requestUri = $Endpoint + '?' + (ConvertTo-QueryString -Parameters $apiParameters)
    $sourcePage = 'https://liquipedia.net/fighters/' + [Uri]::EscapeDataString($Query.Replace(' ', '_'))

    if ($DryRun) {
        [pscustomobject]@{
            ok = $true
            mode = 'dry-run'
            requestedMode = $Mode
            query = $Query
            requestUri = $requestUri
            networkRequestSent = $false
            normalMinimumIntervalSeconds = 2
            parseMinimumIntervalSeconds = 30
        } | ConvertTo-Json -Depth 10
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Contact) -or
        $Contact -match 'example\.com|ASK_|your[-_ ]?(email|contact)') {
        throw 'Set -Contact or LIQUIPEDIA_CONTACT to a real email address or contact URL.'
    }
    if ($Contact -notmatch '@' -and $Contact -notmatch '^https?://') {
        throw 'Contact must be a real email address or an HTTP(S) contact URL.'
    }

    $appDataRoot = Get-AppDataRoot
    $cacheRoot = Join-Path $appDataRoot 'Cache'
    $cacheKey = Get-Sha256Text -Text $requestUri
    $cachePath = Join-Path $cacheRoot ($cacheKey + '.json')
    $response = $null
    $fromCache = $false

    if (-not $Refresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        $cacheRecord = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expiresAt = [DateTimeOffset]::MinValue
        if ((Test-Property $cacheRecord 'expiresAt') -and
            [DateTimeOffset]::TryParse([string]$cacheRecord.expiresAt, [ref]$expiresAt) -and
            [DateTimeOffset]::UtcNow -lt $expiresAt) {
            $response = $cacheRecord.response
            $fromCache = $true
        }
    }

    if (-not $fromCache) {
        $statePath = Join-Path $appDataRoot 'rate-limit.json'
        Wait-LiquipediaRateLimit -StatePath $statePath -IsParse ($Mode -eq 'parse')

        $headers = @{
            'User-Agent' = "$ProjectName/$ProjectVersion (contact: $Contact)"
            'Accept' = 'application/json'
            'Accept-Encoding' = 'gzip'
        }

        $response = Invoke-RestMethod -Uri $requestUri -Method Get -Headers $headers -TimeoutSec 30
        if (Test-Property $response 'error') {
            throw ('Liquipedia API error: ' + ($response.error | ConvertTo-Json -Compress))
        }

        if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
        }

        [ordered]@{
            requestUri = $requestUri
            fetchedAt = [DateTimeOffset]::UtcNow.ToString('o')
            expiresAt = [DateTimeOffset]::UtcNow.AddHours($CacheHours).ToString('o')
            response = $response
        } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    }

    switch ($Mode) {
        'search' {
            $result = @($response.query.search | ForEach-Object {
                [pscustomobject]@{
                    title = $_.title
                    pageId = $_.pageid
                    snippet = $_.snippet
                }
            })
        }
        'page' {
            $result = Get-PageData -ApiResponse $response
        }
        'player' {
            $pageData = Get-PageData -ApiResponse $response
            $result = [pscustomobject]@{
                title = $pageData.title
                pageId = $pageData.pageId
                revisionId = $pageData.revisionId
                timestamp = $pageData.timestamp
                player = Get-PlayerFields -Wikitext $pageData.wikitext
            }
        }
        'parse' {
            if (-not (Test-Property $response 'parse') -or
                -not (Test-Property $response.parse $ParseProperty)) {
                throw "Liquipedia parse response did not contain '$ParseProperty'."
            }
            $result = $response.parse.PSObject.Properties[$ParseProperty].Value
        }
    }

    [pscustomobject]@{
        ok = $true
        mode = $Mode
        query = $Query
        fromCache = $fromCache
        fetchedAt = [DateTimeOffset]::UtcNow.ToString('o')
        sourcePage = $sourcePage
        attribution = 'Liquipedia'
        contentLicense = 'CC BY-SA 3.0'
        result = $result
    } | ConvertTo-Json -Depth 30
}
catch {
    [pscustomobject]@{
        ok = $false
        mode = $Mode
        query = $Query
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 10
    exit 1
}
