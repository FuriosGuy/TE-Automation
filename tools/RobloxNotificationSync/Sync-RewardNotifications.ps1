[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Apply,
    [int]$MaxPages,
    [int]$MaxUsers,
    [int]$MaxNotifications,
    [string]$NowUnixOverride,
    [string]$ApiKeyEnvironmentVariable = "ROBLOX_NOTIFICATION_API_KEY"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ApiRoot = "https://apis.roblox.com/cloud/v2"
$PresenceApiRoot = "https://presence.roblox.com/v1"
$GroupsApiRoot = "https://groups.roblox.com/v2"
$LocalDotEnvPath = Join-Path $PSScriptRoot ".env"
$script:ApiKey = $null

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Import-LocalDotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith("#")) {
            continue
        }

        if ($trimmedLine -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            Write-Warning "Ignoring malformed .env line."
            continue
        }

        $name = $Matches[1]
        if ($name -ne $ApiKeyEnvironmentVariable) {
            continue
        }

        $value = $Matches[2].Trim()
        if ($value.Length -ge 2) {
            $firstCharacter = $value.Substring(0, 1)
            $lastCharacter = $value.Substring($value.Length - 1, 1)
            if (($firstCharacter -eq '"' -and $lastCharacter -eq '"') -or ($firstCharacter -eq "'" -and $lastCharacter -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^<.*>$') {
            continue
        }

        $existingValue = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrWhiteSpace($existingValue)) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Get-RequiredString {
    param(
        [object]$Object,
        [string]$Name
    )

    $value = Get-PropertyValue $Object $Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Config field '$Name' is required."
    }

    return [string]$value
}

function Get-PositiveInt {
    param(
        [object]$Object,
        [string]$Name,
        [int]$DefaultValue
    )

    $value = Get-PropertyValue $Object $Name
    if ($null -eq $value) {
        return $DefaultValue
    }

    $parsed = 0
    if (-not [int]::TryParse([string]$value, [ref]$parsed) -or $parsed -le 0) {
        throw "Config field '$Name' must be a positive integer."
    }

    return $parsed
}

function Get-UserIdFromEntryId {
    param(
        [string]$EntryId,
        [string]$Prefix,
        [string]$Scope
    )

    $prefixes = @($Prefix)
    if (-not [string]::IsNullOrWhiteSpace($Scope)) {
        $prefixes += "$Scope/$Prefix"
    }

    foreach ($candidatePrefix in $prefixes) {
        if ($EntryId -match ("^" + [regex]::Escape($candidatePrefix) + "([0-9]+)$")) {
            $userId = 0L
            if ([long]::TryParse($Matches[1], [ref]$userId) -and $userId -gt 0) {
                return $userId
            }
        }
    }

    return $null
}

function Get-StatusCodeFromException {
    param([object]$Exception)

    $response = Get-PropertyValue $Exception "Response"
    if ($null -ne $response) {
        $statusValue = Get-PropertyValue $response "StatusCode"
        if ($null -ne $statusValue) {
            try {
                return [int]$statusValue
            } catch {
                return 0
            }
        }
    }

    if ($Exception.Message -match "(?<!\d)([45]\d{2})(?!\d)") {
        return [int]$Matches[1]
    }

    return 0
}

function Get-HttpErrorBody {
    param([object]$ErrorRecord)

    $errorDetails = Get-PropertyValue $ErrorRecord "ErrorDetails"
    $errorDetailsMessage = if ($null -ne $errorDetails) {
        Get-PropertyValue $errorDetails "Message"
    } else {
        $null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$errorDetailsMessage)) {
        return [string]$errorDetailsMessage
    }

    $exception = Get-PropertyValue $ErrorRecord "Exception"
    $response = Get-PropertyValue $exception "Response"
    if ($null -eq $response) {
        return $null
    }

    $content = Get-PropertyValue $response "Content"
    if ($null -ne $content) {
        try {
            $readAsStringAsync = $content.GetType().GetMethod("ReadAsStringAsync", [Type]::EmptyTypes)
            if ($null -ne $readAsStringAsync) {
                $task = $readAsStringAsync.Invoke($content, $null)
                $body = $task.GetAwaiter().GetResult()
                if (-not [string]::IsNullOrWhiteSpace([string]$body)) {
                    return [string]$body
                }
            }
        } catch {
            # Fall through to the HttpWebResponse stream path below.
        }
    }

    try {
        $stream = $response.GetResponseStream()
        if ($null -ne $stream) {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    return $body
                }
            } finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-ErrorDescription {
    param(
        [object]$ErrorRecord,
        [int]$MaximumLength = 1200
    )

    $body = Get-HttpErrorBody $ErrorRecord
    if ([string]::IsNullOrWhiteSpace([string]$body)) {
        return [string]$ErrorRecord.Exception.Message
    }

    $description = [string]$body
    if ($description.Length -gt $MaximumLength) {
        return $description.Substring(0, $MaximumLength) + "..."
    }
    return $description
}

function Invoke-JsonRequest {
    param(
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [string]$Uri,
        [object]$Body,
        [hashtable]$Headers = @{}
    )

    $requestHeaders = @{
        Accept = "application/json"
    }
    foreach ($headerName in $Headers.Keys) {
        $requestHeaders[$headerName] = $Headers[$headerName]
    }

    $bodyJson = if ($null -ne $Body) {
        $Body | ConvertTo-Json -Depth 12 -Compress
    } else {
        $null
    }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $requestParameters = @{
                Method = $Method
                Uri = $Uri
                Headers = $requestHeaders
                ErrorAction = "Stop"
            }
            if ($null -ne $bodyJson) {
                $requestParameters.ContentType = "application/json"
                $requestParameters.Body = $bodyJson
            }

            $response = Invoke-WebRequest @requestParameters
            $parsedBody = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
                try {
                    $parsedBody = $response.Content | ConvertFrom-Json
                } catch {
                    throw "Response was not valid JSON."
                }
            }

            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $parsedBody
            }
        } catch {
            $statusCode = Get-StatusCodeFromException $_.Exception
            $isRetryable = $statusCode -eq 429 -or $statusCode -ge 500 -or $statusCode -eq 0
            if ($isRetryable -and $attempt -lt 4) {
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt - 1))
                continue
            }

            $errorDescription = Get-ErrorDescription $_
            throw "Request failed: $Method $Uri | HTTP $statusCode | $errorDescription"
        }
    }

    throw "Request failed after retries: $Method $Uri"
}

function Invoke-PublicJsonRequest {
    param(
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [string]$Uri,
        [object]$Body
    )

    return Invoke-JsonRequest -Method $Method -Uri $Uri -Body $Body
}

function Invoke-OpenCloudJsonRequest {
    param(
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [string]$Uri,
        [object]$Body
    )

    return Invoke-JsonRequest -Method $Method -Uri $Uri -Body $Body -Headers @{ "x-api-key" = $script:ApiKey }
}

function Get-StoreEntries {
    param(
        [string]$UniverseId,
        [string]$DataStoreId,
        [string]$Scope,
        [string]$KeyPrefix,
        [int]$PageSize,
        [int]$PageLimit,
        [int]$UserLimit
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $pageToken = $null

    for ($page = 1; $page -le $PageLimit; $page++) {
        if ([string]::IsNullOrWhiteSpace($Scope)) {
            throw "Data store scope is required for notification scans."
        }
        $filter = [uri]::EscapeDataString(('id.startsWith("' + $KeyPrefix + '")'))
        $uri = "$ApiRoot/universes/$UniverseId/data-stores/$DataStoreId/scopes/$Scope/entries?maxPageSize=$PageSize&filter=$filter"
        if (-not [string]::IsNullOrWhiteSpace([string]$pageToken)) {
            $uri += "&pageToken=" + [uri]::EscapeDataString([string]$pageToken)
        }

        $response = Invoke-OpenCloudJsonRequest -Method GET -Uri $uri
        $body = $response.Body
        # Preserve an empty array. PowerShell otherwise unwraps it to $null and
        # incorrectly reports a valid empty page as a malformed response.
        $dataStoreEntriesProperty = if ($null -ne $body) {
            $body.PSObject.Properties["dataStoreEntries"]
        } else {
            $null
        }
        $entriesProperty = if ($null -ne $body) {
            $body.PSObject.Properties["entries"]
        } else {
            $null
        }
        if ($null -ne $dataStoreEntriesProperty) {
            $pageEntries = @($dataStoreEntriesProperty.Value)
        } elseif ($null -ne $entriesProperty) {
            $pageEntries = @($entriesProperty.Value)
        } else {
            $responseProperties = if ($null -ne $body) {
                (@($body.PSObject.Properties | ForEach-Object { $_.Name }) -join ",")
            } else {
                "<empty>"
            }
            throw "List response did not contain dataStoreEntries or entries. Response properties: $responseProperties"
        }

        foreach ($entry in @($pageEntries)) {
            $entries.Add($entry)
            if ($entries.Count -ge $UserLimit) {
                return $entries
            }
        }

        $pageToken = Get-PropertyValue $body "nextPageToken"
        if ([string]::IsNullOrWhiteSpace([string]$pageToken)) {
            return $entries
        }
    }

    throw "Entry scan exceeded maxPages=$PageLimit. Increase bound only after reviewing scan size."
}

function Get-EntryValue {
    param(
        [string]$UniverseId,
        [string]$DataStoreId,
        [object]$Entry
    )

    $entryValue = Get-PropertyValue $Entry "value"
    if ($null -ne $entryValue) {
        if ($entryValue -is [string]) {
            try {
                return $entryValue | ConvertFrom-Json
            } catch {
                return $null
            }
        }
        return $entryValue
    }

    $entryId = Get-PropertyValue $Entry "id"
    if ($null -eq $entryId) {
        $entryId = Get-PropertyValue $Entry "key"
    }
    if ($null -eq $entryId) {
        return $null
    }

    $path = Get-PropertyValue $Entry "path"
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        $path = "universes/$UniverseId/data-stores/$DataStoreId/entries/$entryId"
    }
    $uri = if ([string]$path -match "^https?://") { [string]$path } else { "$ApiRoot/$path" }
    $response = Invoke-OpenCloudJsonRequest -Method GET -Uri $uri
    $value = Get-PropertyValue $response.Body "value"
    if ($value -is [string]) {
        try {
            return $value | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $value
}

function Get-NumberValue {
    param(
        [object]$Object,
        [string]$Name
    )

    $value = Get-PropertyValue $Object $Name
    if ($null -eq $value) {
        return $null
    }

    $parsed = 0L
    if ([long]::TryParse([string]$value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Test-GroupMember {
    param(
        [long]$UserId,
        [string]$GroupId,
        [hashtable]$Cache
    )

    $cacheKey = [string]$UserId
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey] -eq $true
    }

    $uri = "$GroupsApiRoot/users/$UserId/groups/roles"
    try {
        $response = Invoke-PublicJsonRequest -Method GET -Uri $uri
        $groups = Get-PropertyValue $response.Body "data"
        if ($null -eq $groups) {
            $groups = Get-PropertyValue $response.Body "groups"
        }

        $isMember = $false
        foreach ($membership in @($groups)) {
            $group = Get-PropertyValue $membership "group"
            $membershipGroupId = Get-PropertyValue $group "id"
            if ([string]$membershipGroupId -eq $GroupId) {
                $isMember = $true
                break
            }
        }
        $Cache[$cacheKey] = $isMember
        return $isMember
    } catch {
        Write-Warning "Group membership check failed for userId=$UserId; GroupReward notification skipped. $($_.Exception.Message)"
        $Cache[$cacheKey] = $false
        return $false
    }
}

function Get-PresenceByUserId {
    param(
        [long[]]$UserIds,
        [int]$BatchSize
    )

    $presenceByUserId = @{}
    for ($start = 0; $start -lt $UserIds.Count; $start += $BatchSize) {
        $end = [Math]::Min($start + $BatchSize - 1, $UserIds.Count - 1)
        $batch = @($UserIds[$start..$end])
        $response = Invoke-PublicJsonRequest `
            -Method POST `
            -Uri "$PresenceApiRoot/presence/users" `
            -Body @{ userIds = $batch }
        $presences = Get-PropertyValue $response.Body "userPresences"
        if ($null -eq $presences) {
            throw "Presence response did not contain userPresences."
        }

        foreach ($presence in @($presences)) {
            $userId = Get-PropertyValue $presence "userId"
            if ($null -ne $userId) {
                $presenceByUserId[[string]$userId] = $presence
            }
        }

        if ($end -lt $UserIds.Count - 1) {
            Start-Sleep -Milliseconds 100
        }
    }

    return $presenceByUserId
}

function Test-ActiveInTargetUniverse {
    param(
        [object]$Presence,
        [string]$UniverseId
    )

    if ($null -eq $Presence) {
        return $null
    }

    $presenceType = Get-NumberValue $Presence "userPresenceType"
    $presenceUniverseId = Get-PropertyValue $Presence "universeId"
    return $presenceType -eq 2 -and [string]$presenceUniverseId -eq $UniverseId
}

function Get-ReadyNotificationKey {
    param(
        [object]$PlayerData,
        [long]$NowUnix,
        [string]$GroupId,
        [long]$UserId,
        [hashtable]$GroupMembershipCache
    )

    $dailyNextClaim = Get-NumberValue $PlayerData "DailyRewardNextClaimUnix"
    if ($null -ne $dailyNextClaim -and $dailyNextClaim -le $NowUnix) {
        return "DailyRewardReady"
    }

    $spinInitialized = Get-PropertyValue $PlayerData "SpinWheelFreeSpinInitialized"
    $spinNextFree = Get-NumberValue $PlayerData "SpinWheelNextFreeSpinUnix"
    if ($spinInitialized -eq $true -and $null -ne $spinNextFree -and $spinNextFree -le $NowUnix) {
        return "SpinWheelReady"
    }

    $groupNextClaim = Get-NumberValue $PlayerData "VerifyRewardNextClaimUnix"
    if ($null -ne $groupNextClaim -and $groupNextClaim -le $NowUnix -and (Test-GroupMember $UserId $GroupId $GroupMembershipCache)) {
        return "GroupRewardReady"
    }

    return $null
}

function Send-UserNotification {
    param(
        [string]$UniverseId,
        [long]$UserId,
        [string]$MessageId,
        [string]$Category
    )

    $body = @{
        source = @{
            universe = "universes/$UniverseId"
        }
        payload = @{
            message_id = $MessageId
            type = "MOMENT"
        }
        analytics_data = @{
            category = $Category
        }
    }
    $uri = "$ApiRoot/users/$UserId/notifications"
    return Invoke-OpenCloudJsonRequest -Method POST -Uri $uri -Body $body
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "Could not parse config file '$ConfigPath': $($_.Exception.Message)"
}

$enabled = Get-PropertyValue $config "enabled"
$universeId = Get-RequiredString $config "universeId"
$dataStoreId = Get-RequiredString $config "playerDataStore"
$dataStoreScope = Get-PropertyValue $config "dataStoreScope"
if ([string]::IsNullOrWhiteSpace([string]$dataStoreScope)) {
    $dataStoreScope = "global"
}
$keyPrefix = Get-RequiredString $config "playerKeyPrefix"
$groupId = Get-RequiredString $config "groupId"
$pageSize = Get-PositiveInt $config "maxPageSize" 100
$pageLimit = if ($MaxPages -gt 0) { $MaxPages } else { Get-PositiveInt $config "maxPages" 25 }
$userLimit = if ($MaxUsers -gt 0) { $MaxUsers } else { Get-PositiveInt $config "maxUsersPerRun" 500 }
$notificationLimit = if ($MaxNotifications -gt 0) { $MaxNotifications } else { Get-PositiveInt $config "maxNotificationsPerRun" 250 }
$delayMilliseconds = Get-PositiveInt $config "requestDelayMilliseconds" 250
$presenceBatchSize = Get-PositiveInt $config "presenceBatchSize" 50
$notifyOnlyOffline = Get-PropertyValue $config "notifyOnlyOfflinePlayers"
$messageIds = Get-PropertyValue $config "messageIds"
$categories = Get-PropertyValue $config "categories"

if ($enabled -ne $true) {
    Write-Output "Reward notification sync disabled by config. No notifications sent."
    exit 0
}

Import-LocalDotEnv $LocalDotEnvPath
$script:ApiKey = [Environment]::GetEnvironmentVariable($ApiKeyEnvironmentVariable, "Process")
if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
    throw "Missing environment variable $ApiKeyEnvironmentVariable. API key is never read from config or source code."
}

$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (-not [string]::IsNullOrWhiteSpace($NowUnixOverride)) {
    $overrideValue = 0L
    if (-not [long]::TryParse($NowUnixOverride, [ref]$overrideValue)) {
        throw "NowUnixOverride must be a Unix timestamp."
    }
    $nowUnix = $overrideValue
}

Write-Output ("Scanning {0} for ready reward notifications. apply={1} nowUnix={2}" -f $universeId, $Apply.IsPresent, $nowUnix)
$entries = Get-StoreEntries $universeId $dataStoreId ([string]$dataStoreScope) $keyPrefix $pageSize $pageLimit $userLimit
$candidates = [System.Collections.Generic.List[object]]::new()
$skipped = 0

foreach ($entry in $entries) {
    $entryId = Get-PropertyValue $entry "id"
    if ($null -eq $entryId) {
        $entryId = Get-PropertyValue $entry "key"
    }
    $userId = Get-UserIdFromEntryId ([string]$entryId) $keyPrefix ([string]$dataStoreScope)
    if ($null -eq $userId) {
        $skipped++
        continue
    }

    try {
        $playerData = Get-EntryValue $universeId $dataStoreId $entry
        if ($null -eq $playerData) {
            $skipped++
            continue
        }
        $candidates.Add([pscustomobject]@{
            UserId = [long]$userId
            Data = $playerData
        })
    } catch {
        $skipped++
        Write-Warning "Player data read failed for userId=$userId. $($_.Exception.Message)"
    }
}

$presenceByUserId = @{}
if ($notifyOnlyOffline -eq $true -and $candidates.Count -gt 0) {
    $candidateUserIds = @($candidates | ForEach-Object { $_.UserId })
    try {
        $presenceByUserId = Get-PresenceByUserId $candidateUserIds $presenceBatchSize
    } catch {
        throw "Presence safety check failed; no notifications sent. $($_.Exception.Message)"
    }
}

$groupMembershipCache = @{}
$sent = 0
$wouldSend = 0
$offlineSkipped = 0
$notReady = 0
$notOptedIn = 0
$recipientThrottled = 0
$notificationFailures = 0
$reportedFailureSignatures = @{}

foreach ($candidate in $candidates) {
    if ($sent -ge $notificationLimit -and $Apply.IsPresent) {
        break
    }

    if ($notifyOnlyOffline -eq $true) {
        $presence = $presenceByUserId[[string]$candidate.UserId]
        $activeInTargetUniverse = Test-ActiveInTargetUniverse $presence $universeId
        if ($null -eq $activeInTargetUniverse) {
            $offlineSkipped++
            continue
        }
        if ($activeInTargetUniverse -eq $true) {
            $offlineSkipped++
            continue
        }
    }

    $key = Get-ReadyNotificationKey $candidate.Data $nowUnix $groupId $candidate.UserId $groupMembershipCache
    if ($null -eq $key) {
        $notReady++
        continue
    }

    $messageId = Get-PropertyValue $messageIds $key
    $category = Get-PropertyValue $categories $key
    if ([string]::IsNullOrWhiteSpace([string]$messageId)) {
        throw "Missing message ID for $key."
    }
    if ([string]::IsNullOrWhiteSpace([string]$category)) {
        $category = $key
    }

    if (-not $Apply.IsPresent) {
        $wouldSend++
        Write-Output "DRY RUN userId=$($candidate.UserId) key=$key"
        continue
    }

    try {
        $response = Send-UserNotification $universeId $candidate.UserId ([string]$messageId) ([string]$category)
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "HTTP $($response.StatusCode)"
        }
        $sent++
        Write-Output "SENT userId=$($candidate.UserId) key=$key statusCode=$($response.StatusCode)"
    } catch {
        $errorMessage = [string]$_.Exception.Message
        $normalizedErrorMessage = $errorMessage -replace "\s+", " "
        if ($normalizedErrorMessage -match "HTTP 400.*(?:FAILED_PRECONDITION|not opted in|not eligible|cannot receive notifications)") {
            $notOptedIn++
            continue
        }

        if ($normalizedErrorMessage -match "HTTP 429.*(?:1 notification per recipient|notification per recipient|recipient.*throttle|recipient.*cooldown)") {
            $recipientThrottled++
            continue
        }

        $notificationFailures++
        $failureSignature = $normalizedErrorMessage -replace "userId=\d+", "userId=<redacted>"
        if (-not $reportedFailureSignatures.ContainsKey($failureSignature)) {
            $reportedFailureSignatures[$failureSignature] = $true
            Write-Warning "Notification send failed for userId=$($candidate.UserId) key=$key. $normalizedErrorMessage"
        }
    }

    if ($delayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $delayMilliseconds
    }
}

Write-Output ("Complete. scanned={0} candidates={1} sent={2} dryRun={3} wouldSend={4} notReady={5} offlineOrUnknown={6} notOptedIn={7} recipientThrottled={8} notificationFailures={9} skipped={10}" -f `
    $entries.Count, $candidates.Count, $sent, (-not $Apply.IsPresent), $wouldSend, $notReady, $offlineSkipped, $notOptedIn, $recipientThrottled, $notificationFailures, $skipped)
