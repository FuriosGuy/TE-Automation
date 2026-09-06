[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Apply,
    [int]$MaxPages = 10,
    [string]$EventKey,
    [string]$NowUtcOverride,
    [string]$ApiKeyEnvironmentVariable = "ROBLOX_EVENT_API_KEY"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ApiRoot = "https://apis.roblox.com/virtual-events/v3"
$LocalDotEnvPath = Join-Path $PSScriptRoot ".env"

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

function Resolve-LocalPath {
    param([string]$PathValue)

    if ([IO.Path]::IsPathRooted($PathValue)) {
        return [IO.Path]::GetFullPath($PathValue)
    }

    $currentDirectoryPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
    if (Test-Path -LiteralPath $currentDirectoryPath) {
        return $currentDirectoryPath
    }

    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $PathValue))
}

function Convert-ToUtcTimestamp {
    param(
        [object]$Value,
        [string]$FieldName
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$FieldName must contain an RFC 3339 timestamp."
    }

    try {
        if ($Value -is [DateTimeOffset]) {
            $parsed = $Value
        } elseif ($Value -is [DateTime]) {
            $parsed = [DateTimeOffset]$Value
        } else {
            $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            $parsed = [DateTimeOffset]::Parse(
                [string]$Value,
                [Globalization.CultureInfo]::InvariantCulture,
                $styles
            )
        }
        return $parsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    } catch {
        throw "$FieldName is not a valid RFC 3339 timestamp: $Value"
    }
}

function Convert-ToUtcDateTimeOffset {
    param(
        [object]$Value,
        [string]$FieldName
    )

    return [DateTimeOffset]::Parse(
        (Convert-ToUtcTimestamp $Value $FieldName),
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Format-UtcTimestamp {
    param([DateTimeOffset]$Value)

    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function Convert-ToInt64 {
    param(
        [object]$Value,
        [string]$FieldName
    )

    $parsed = 0L
    $success = [long]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )
    if (-not $success -or $parsed -le 0) {
        throw "$FieldName must be a positive integer."
    }

    return $parsed
}

function Convert-ToNonNegativeInt32 {
    param(
        [object]$Value,
        [string]$FieldName
    )

    $parsed = 0L
    $success = [long]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )
    if (-not $success -or $parsed -lt 0 -or $parsed -gt [int]::MaxValue) {
        throw "$FieldName must be a non-negative 32-bit integer."
    }

    return [int]$parsed
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

function Invoke-RobloxEventRequest {
    param(
        [ValidateSet("GET", "POST", "PATCH")]
        [string]$Method,
        [string]$Uri,
        [object]$Body
    )

    $headers = @{
        "x-api-key" = $script:ApiKey
        Accept = "application/json"
    }
    $bodyJson = if ($null -ne $Body) {
        $Body | ConvertTo-Json -Depth 12 -Compress
    } else {
        $null
    }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            if ($null -eq $bodyJson) {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
            }

            return Invoke-RestMethod `
                -Method $Method `
                -Uri $Uri `
                -Headers $headers `
                -ContentType "application/json" `
                -Body $bodyJson `
                -ErrorAction Stop
        } catch {
            # PowerShell 7 may omit Exception.Response on Linux runners.
            $exception = $_.Exception
            $response = Get-PropertyValue $exception "Response"
            $statusCode = 0
            if ($null -ne $response) {
                $statusValue = Get-PropertyValue $response "StatusCode"
                if ($null -ne $statusValue) {
                    try {
                        $statusCode = [int]$statusValue
                    } catch {
                        $statusCode = 0
                    }
                }
            }
            if ($statusCode -eq 0 -and $exception.Message -match "(?<!\d)([45]\d{2})(?!\d)") {
                $statusCode = [int]$Matches[1]
            }

            $isRetryable = $statusCode -eq 429 -or $statusCode -ge 500
            if ($isRetryable -and $attempt -lt 4) {
                $delaySeconds = [int][Math]::Pow(2, $attempt - 1)
                $retryAfter = $null
                if ($null -ne $response) {
                    $responseHeaders = Get-PropertyValue $response "Headers"
                    if ($null -ne $responseHeaders) {
                        try {
                            $retryAfter = $responseHeaders["Retry-After"]
                        } catch {
                            $retryAfter = $null
                        }
                    }
                }
                if ($null -ne $retryAfter) {
                    $parsedRetryAfter = 0
                    if ([int]::TryParse([string]$retryAfter, [ref]$parsedRetryAfter)) {
                        $delaySeconds = [Math]::Max($delaySeconds, $parsedRetryAfter)
                    }
                }

                Write-Warning "Roblox API returned HTTP $statusCode. Retrying in ${delaySeconds}s (attempt $attempt/4)."
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            $errorDetail = $exception.Message
            $errorDetails = Get-PropertyValue $_ "ErrorDetails"
            $errorDetailsMessage = if ($null -ne $errorDetails) {
                Get-PropertyValue $errorDetails "Message"
            } else {
                $null
            }
            if ($null -ne $errorDetailsMessage -and -not [string]::IsNullOrWhiteSpace([string]$errorDetailsMessage)) {
                $errorDetail = "$errorDetail | response=$errorDetailsMessage"
            }
            if ($null -ne $response) {
                try {
                    $reader = [IO.StreamReader]::new($response.GetResponseStream())
                    $serverBody = $reader.ReadToEnd()
                    $reader.Dispose()
                    if (-not [string]::IsNullOrWhiteSpace($serverBody) -and $errorDetail -notlike "*response=*") {
                        $errorDetail = "$errorDetail | response=$serverBody"
                    }
                } catch {
                    # Preserve original HTTP error when response body unavailable.
                }
            }

            if ($errorDetail -match "Scope must be configured to allow all resources") {
                $errorDetail = "$errorDetail | Roblox event ID endpoints require universe.event access with Restrict by Experience disabled; use dedicated all-resources event key or OAuth 2.0."
            }

            throw "Roblox API request failed: $Method $Uri | HTTP $statusCode | $errorDetail"
        }
    }

    throw "Roblox API request failed after all retry attempts: $Method $Uri"
}

function Get-AllEvents {
    param(
        [long]$UniverseId,
        [int]$PageLimit
    )

    $events = [Collections.Generic.List[object]]::new()
    $pageToken = $null

    for ($pageNumber = 1; $pageNumber -le $PageLimit; $pageNumber++) {
        $uri = "$script:ApiRoot/universes/$UniverseId/game-events?pageSize=100&fields=*"
        if (-not [string]::IsNullOrWhiteSpace([string]$pageToken)) {
            $encodedToken = [Uri]::EscapeDataString([string]$pageToken)
            $uri += "&pageToken=$encodedToken"
        }

        $page = Invoke-RobloxEventRequest -Method GET -Uri $uri
        $pageEvents = Get-PropertyValue $page "gameEvents"
        foreach ($event in @($pageEvents)) {
            if ($null -ne $event) {
                $events.Add($event)
            }
        }

        $pageToken = Get-PropertyValue $page "nextPageToken"
        if ([string]::IsNullOrWhiteSpace([string]$pageToken)) {
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$pageToken)) {
        throw "Event list is incomplete. Increase -MaxPages before applying changes."
    }

    return @($events)
}

function Convert-LocalMidnightToUtc {
    param(
        [DateTime]$LocalDate,
        [TimeZoneInfo]$TimeZone
    )

    $unspecified = [DateTime]::SpecifyKind($LocalDate.Date, [DateTimeKind]::Unspecified)
    return [DateTimeOffset]([TimeZoneInfo]::ConvertTimeToUtc($unspecified, $TimeZone))
}

function Get-WeekendWindow {
    param([DateTimeOffset]$NowUtc)

    $tokyo = [TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
    $pacific = [TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
    $tokyoNow = [TimeZoneInfo]::ConvertTime($NowUtc, $tokyo)
    $daysSinceSaturday = (([int]$tokyoNow.DayOfWeek - [int][DayOfWeek]::Saturday) + 7) % 7
    $startDate = $tokyoNow.Date.AddDays(-$daysSinceSaturday)

    $startUtc = Convert-LocalMidnightToUtc $startDate $tokyo
    $pacificStart = [TimeZoneInfo]::ConvertTime($startUtc, $pacific)
    $daysUntilMonday = (([int][DayOfWeek]::Monday - [int]$pacificStart.DayOfWeek) + 7) % 7
    if ($daysUntilMonday -eq 0) {
        $daysUntilMonday = 7
    }
    $endDate = $pacificStart.Date.AddDays($daysUntilMonday)
    $endUtc = Convert-LocalMidnightToUtc $endDate $pacific

    if ($NowUtc -ge $endUtc) {
        $startDate = $startDate.AddDays(7)
        $startUtc = Convert-LocalMidnightToUtc $startDate $tokyo
        $pacificStart = [TimeZoneInfo]::ConvertTime($startUtc, $pacific)
        $daysUntilMonday = (([int][DayOfWeek]::Monday - [int]$pacificStart.DayOfWeek) + 7) % 7
        if ($daysUntilMonday -eq 0) {
            $daysUntilMonday = 7
        }
        $endDate = $pacificStart.Date.AddDays($daysUntilMonday)
        $endUtc = Convert-LocalMidnightToUtc $endDate $pacific
    }

    return [pscustomobject]@{
        start = $startUtc
        end = $endUtc
    }
}

function Get-RecurringWindow {
    param(
        [object]$Schedule,
        [DateTimeOffset]$NowUtc
    )

    $firstStart = Convert-ToUtcDateTimeOffset (Get-PropertyValue $Schedule "cycleStartUtc") "cycleStartUtc"
    $activeSeconds = Convert-ToInt64 (Get-PropertyValue $Schedule "activeDurationSeconds") "activeDurationSeconds"
    $graceSeconds = Convert-ToInt64 (Get-PropertyValue $Schedule "graceDurationSeconds") "graceDurationSeconds"
    $cycleSeconds = $activeSeconds + $graceSeconds
    $windowStart = $firstStart

    if ($NowUtc -ge $firstStart) {
        $elapsedSeconds = ($NowUtc - $firstStart).TotalSeconds
        $cycleIndex = [math]::Floor($elapsedSeconds / $cycleSeconds)
        $windowStart = $firstStart.AddSeconds($cycleIndex * $cycleSeconds)
        if ($NowUtc -ge $windowStart.AddSeconds($activeSeconds)) {
            $windowStart = $windowStart.AddSeconds($cycleSeconds)
        }
    }

    return [pscustomobject]@{
        start = $windowStart
        end = $windowStart.AddSeconds($activeSeconds)
    }
}

function Get-EventWindow {
    param(
        [object]$Event,
        [DateTimeOffset]$NowUtc
    )

    $schedule = Get-PropertyValue $Event "schedule"
    if ($null -eq $schedule) {
        throw "Event '$(Get-RequiredString $Event 'eventKey')' has no schedule."
    }

    $kind = Get-RequiredString $schedule "kind"
    if ($kind -eq "AbsoluteWindow") {
        return [pscustomobject]@{
            start = Convert-ToUtcDateTimeOffset (Get-PropertyValue $schedule "startTimeUtc") "startTimeUtc"
            end = Convert-ToUtcDateTimeOffset (Get-PropertyValue $schedule "endTimeUtc") "endTimeUtc"
        }
    }
    if ($kind -eq "RecurringWindow") {
        return Get-RecurringWindow $schedule $NowUtc
    }
    if ($kind -eq "WeekendTokyoToPacific") {
        return Get-WeekendWindow $NowUtc
    }

    throw "Unsupported schedule kind '$kind'."
}

function Get-EventWindows {
    param(
        [object]$Event,
        [DateTimeOffset]$NowUtc
    )

    $schedule = Get-PropertyValue $Event "schedule"
    $currentWindow = Get-EventWindow $Event $NowUtc
    if ($currentWindow.end -le $NowUtc) {
        return @()
    }

    $currentCandidate = [pscustomobject]@{
        window = $currentWindow
        active = $currentWindow.start -le $NowUtc -and $currentWindow.end -gt $NowUtc
        isNext = $false
    }
    $windows = [Collections.Generic.List[object]]::new()
    $windows.Add($currentCandidate)

    if (-not $currentCandidate.active -or $null -eq $schedule) {
        return @($windows)
    }

    $kind = Get-RequiredString $schedule "kind"
    $nextWindow = $null
    if ($kind -eq "RecurringWindow") {
        $activeSeconds = Convert-ToInt64 (Get-PropertyValue $schedule "activeDurationSeconds") "activeDurationSeconds"
        $graceSeconds = Convert-ToInt64 (Get-PropertyValue $schedule "graceDurationSeconds") "graceDurationSeconds"
        $nextStart = $currentWindow.end.AddSeconds($graceSeconds)
        $nextWindow = [pscustomobject]@{
            start = $nextStart
            end = $nextStart.AddSeconds($activeSeconds)
        }
    } elseif ($kind -eq "WeekendTokyoToPacific") {
        $nextWindow = Get-WeekendWindow ($currentWindow.end.AddSeconds(1))
    }

    if ($null -ne $nextWindow) {
        $windows.Add([pscustomobject]@{
            window = $nextWindow
            active = $false
            isNext = $true
        })
    }

    return @($windows)
}

function Get-ConfiguredEvents {
    param([object]$Config)

    $events = Get-PropertyValue $Config "events"
    if ($null -ne $events -and @($events).Count -gt 0) {
        return @($events)
    }

    # Keep old one-event config files readable during migration.
    $legacySchedule = [pscustomobject]@{
        kind = "AbsoluteWindow"
        startTimeUtc = Get-PropertyValue $Config "startTimeUtc"
        endTimeUtc = Get-PropertyValue $Config "endTimeUtc"
    }
    return @([pscustomobject]@{
        eventKey = "LegacyEvent"
        enabled = $true
        platformEventId = Get-PropertyValue $Config "managedEventId"
        title = Get-PropertyValue $Config "title"
        subtitle = Get-PropertyValue $Config "subtitle"
        description = Get-PropertyValue $Config "description"
        visibility = Get-PropertyValue $Config "visibility"
        thumbnailId = Get-PropertyValue $Config "thumbnailId"
        categories = Get-PropertyValue $Config "categories"
        notificationAudience = Get-PropertyValue $Config "notificationAudience"
        schedule = $legacySchedule
    })
}

function Get-EventStateKey {
    param(
        [string]$EventKey,
        [DateTimeOffset]$Start
    )

    return "$EventKey|$(Format-UtcTimestamp $Start)"
}

function Get-StateMap {
    param([object]$State)

    $map = @{}
    if ($null -eq $State) {
        return $map
    }

    $stateEvents = Get-PropertyValue $State "events"
    if ($null -ne $stateEvents) {
        foreach ($property in $stateEvents.PSObject.Properties) {
            $map[$property.Name] = $property.Value
        }
        return $map
    }

    # Migrate prior single-event state without deleting it.
    $legacyEventId = Get-PropertyValue $State "eventId"
    $legacyEventKey = Get-PropertyValue $State "eventKey"
    $legacyStart = Get-PropertyValue $State "startTime"
    if ($null -ne $legacyEventId -and $null -ne $legacyEventKey -and $null -ne $legacyStart) {
        $legacyKey = "$legacyEventKey|$legacyStart"
        $map[$legacyKey] = $State
    }

    return $map
}

function Get-SequenceRank {
    param(
        [object]$Config,
        [string]$EventKey
    )

    $publishPolicy = Get-PropertyValue $Config "publishPolicy"
    $sequence = if ($null -ne $publishPolicy) { Get-PropertyValue $publishPolicy "sequence" } else { $null }
    $rank = 100000
    $index = 0
    foreach ($sequenceKey in @($sequence)) {
        if ([string]$sequenceKey -eq $EventKey) {
            $rank = $index
            break
        }
        $index += 1
    }

    return $rank
}

function Select-SyncCandidates {
    param(
        [object]$Config,
        [DateTimeOffset]$NowUtc,
        [string]$RequestedEventKey
    )

    $candidatesByEventKey = @{}
    foreach ($event in Get-ConfiguredEvents $Config) {
        if ((Get-PropertyValue $event "enabled") -eq $false) {
            continue
        }

        $eventKey = Get-RequiredString $event "eventKey"
        if (-not [string]::IsNullOrWhiteSpace($RequestedEventKey) -and $eventKey -ne $RequestedEventKey) {
            continue
        }

        if ($candidatesByEventKey.ContainsKey($eventKey)) {
            throw "Duplicate eventKey '$eventKey'. Configure one schedule per eventKey."
        }

        $windows = Get-EventWindows $event $NowUtc
        if ($windows.Count -eq 0) {
            continue
        }

        $eventCandidates = [Collections.Generic.List[object]]::new()
        foreach ($windowCandidate in $windows) {
            $eventCandidates.Add([pscustomobject]@{
                event = $event
                eventKey = $eventKey
                window = $windowCandidate.window
                active = $windowCandidate.active
                isNext = $windowCandidate.isNext
                sequenceRank = Get-SequenceRank $Config $eventKey
                priority = if ($null -ne (Get-PropertyValue $event "priority")) { [int](Get-PropertyValue $event "priority") } else { 0 }
            })
        }
        $candidatesByEventKey[$eventKey] = @($eventCandidates)
    }

    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($eventCandidates in $candidatesByEventKey.Values) {
        foreach ($candidate in @($eventCandidates)) {
            $candidates.Add($candidate)
        }
    }

    return @($candidates |
        Sort-Object sequenceRank, @{ Expression = { if ($_.isNext) { 1 } else { 0 } } }, @{ Expression = { $_.window.start } }, @{ Expression = { -$_.priority } })
}

function Get-DesiredVisibility {
    param(
        [object]$Event,
        [object]$Candidate,
        [object]$RootConfig
    )

    $finalVisibility = Get-PropertyValue $Event "visibility"
    if ($null -eq $finalVisibility) {
        $finalVisibility = Get-PropertyValue $RootConfig "visibility"
    }
    $finalVisibility = ([string]$finalVisibility).ToLowerInvariant()

    $publishAfterPreviousEnds = Get-PropertyValue $Event "publishAfterPreviousWindowEnds"
    if ($null -eq $publishAfterPreviousEnds) {
        $publishAfterPreviousEnds = Get-PropertyValue $RootConfig "publishAfterPreviousWindowEnds"
    }
    if ($publishAfterPreviousEnds -eq $true -and $Candidate.isNext -eq $true -and $finalVisibility -eq "public") {
        $prePublishVisibility = Get-PropertyValue $Event "prePublishVisibility"
        if ($null -eq $prePublishVisibility) {
            $prePublishVisibility = Get-PropertyValue $RootConfig "prePublishVisibility"
        }
        if ($null -eq $prePublishVisibility -or [string]::IsNullOrWhiteSpace([string]$prePublishVisibility)) {
            $prePublishVisibility = "private"
        }
        return ([string]$prePublishVisibility).ToLowerInvariant()
    }

    return $finalVisibility
}

function New-EventPayload {
    param(
        [object]$Event,
        [DateTimeOffset]$WindowStart,
        [DateTimeOffset]$WindowEnd,
        [long]$PlaceId,
        [long]$GroupId,
        [object]$RootConfig,
        [string]$Visibility
    )

    if ($WindowEnd -le $WindowStart) {
        throw "Event '$([string](Get-PropertyValue $Event 'eventKey'))' has an invalid schedule window."
    }

    $visibilityValue = $Visibility
    if ([string]::IsNullOrWhiteSpace($visibilityValue)) {
        $visibilityValue = Get-PropertyValue $Event "visibility"
    }
    if ($null -eq $visibilityValue -or [string]::IsNullOrWhiteSpace([string]$visibilityValue)) {
        $visibilityValue = Get-PropertyValue $RootConfig "visibility"
    }
    $visibility = ([string]$visibilityValue).ToLowerInvariant()
    if ($visibility -notin @("public", "private")) {
        throw "visibility must be 'public' or 'private'."
    }

    $payload = [ordered]@{
        title = Get-RequiredString $Event "title"
        subtitle = Get-RequiredString $Event "subtitle"
        description = Get-PropertyValue $Event "description"
        startTime = Format-UtcTimestamp $WindowStart
        endTime = Format-UtcTimestamp $WindowEnd
        visibility = $visibility
        placeId = $PlaceId
    }

    if ($GroupId -gt 0) {
        $payload.groupId = $GroupId
    }

    $thumbnailId = Get-PropertyValue $Event "thumbnailId"
    if ($null -ne $thumbnailId -and -not [string]::IsNullOrWhiteSpace([string]$thumbnailId)) {
        $payload.thumbnails = @([ordered]@{
            mediaId = Convert-ToInt64 $thumbnailId "thumbnailId"
            rank = 0
        })
    }

    $categoriesConfig = Get-PropertyValue $Event "categories"
    if ($null -eq $categoriesConfig) {
        $singleCategory = Get-PropertyValue $Event "category"
        if ($null -ne $singleCategory -and -not [string]::IsNullOrWhiteSpace([string]$singleCategory)) {
            $categoriesConfig = @([pscustomobject]@{ category = [string]$singleCategory; rank = 0 })
        }
    }
    if ($null -ne $categoriesConfig) {
        $allowedCategories = @(
            "contentUpdate", "locationUpdate", "systemUpdate", "activity", "newContent",
            "itemDrop", "newSeason", "newLocation", "newMap", "moreLevels", "newFeature",
            "earlyAccess", "expansion", "challenge", "quest", "festival"
        )
        $categories = [Collections.Generic.List[object]]::new()
        foreach ($categoryConfig in @($categoriesConfig)) {
            $category = Get-RequiredString $categoryConfig "category"
            if ($category -notin $allowedCategories) {
                throw "Unsupported event category '$category'."
            }

            $rank = Convert-ToNonNegativeInt32 (Get-PropertyValue $categoryConfig "rank") "category rank"
            $categories.Add([ordered]@{ category = $category; rank = $rank })
        }
        if ($categories.Count -gt 0) {
            $payload.categories = @($categories)
        }
    }

    $notificationAudience = Get-PropertyValue $Event "notificationAudience"
    if ($null -eq $notificationAudience) {
        $notificationAudience = Get-PropertyValue $RootConfig "notificationAudience"
    }
    if ($null -ne $notificationAudience) {
        $audience = ([string]$notificationAudience).ToLowerInvariant()
        if ($audience -notin @("all", "rsvp", "subscribed", "group", "none")) {
            throw "notificationAudience must be all, rsvp, subscribed, group, or none."
        }
        $payload.config = [ordered]@{ notificationAudience = $audience }
    }

    return [pscustomobject]$payload
}

function Get-SeedEventId {
    param(
        [object]$Event,
        [DateTimeOffset]$WindowStart
    )

    $eventId = Get-PropertyValue $Event "platformEventId"
    $seedStartValue = Get-PropertyValue $Event "platformEventStartTimeUtc"
    if ([string]::IsNullOrWhiteSpace([string]$eventId) -or [string]::IsNullOrWhiteSpace([string]$seedStartValue)) {
        return $null
    }

    $seedStart = Convert-ToUtcDateTimeOffset $seedStartValue "platformEventStartTimeUtc"
    if ([math]::Abs(($seedStart - $WindowStart).TotalSeconds) -gt 120) {
        return $null
    }

    return Convert-ToInt64 $eventId "platformEventId"
}

function Get-ManagedEvent {
    param(
        [object]$Event,
        [object]$Candidate,
        [hashtable]$StateMap,
        [long]$PlaceId,
        [int]$PageLimit
    )

    $stateKey = Get-EventStateKey $Candidate.eventKey $Candidate.window.start
    $stateRecord = $StateMap[$stateKey]
    $eventIdValue = if ($null -ne $stateRecord) { Get-PropertyValue $stateRecord "eventId" } else { $null }
    if ([string]::IsNullOrWhiteSpace([string]$eventIdValue)) {
        $eventIdValue = Get-SeedEventId $Event $Candidate.window.start
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$eventIdValue)) {
        $eventId = Convert-ToInt64 $eventIdValue "managed event id"
        $uri = "$script:ApiRoot/game-events/$eventId`?fields=*"
        try {
            return Invoke-RobloxEventRequest -Method GET -Uri $uri
        } catch {
            if ($_.Exception.Message -notmatch "HTTP 404") {
                throw
            }
            Write-Warning "Stored event ID $eventId was not found. Listing current events before considering creation."
        }
    }

    $events = Get-AllEvents -UniverseId $script:UniverseId -PageLimit $PageLimit
    $title = Get-RequiredString $Event "title"
    $matchingTitleAndPlace = @($events | Where-Object {
        ([string](Get-PropertyValue $_ "title") -eq $title) -and
        ([string](Get-PropertyValue $_ "placeId") -eq [string]$PlaceId)
    })
    $exactSchedule = @($matchingTitleAndPlace | Where-Object {
        $returnedStart = Convert-ToUtcDateTimeOffset (Get-PropertyValue $_ "startTime") "event startTime"
        [math]::Abs(($returnedStart - $Candidate.window.start).TotalSeconds) -le 120
    })

    if ($exactSchedule.Count -eq 1) {
        return $exactSchedule[0]
    }
    if ($exactSchedule.Count -gt 1) {
        throw "Multiple events match '$($Candidate.eventKey)' schedule. Remove ambiguity or set platformEventId and platformEventStartTimeUtc."
    }

    return $null
}

function Test-EventCoreFields {
    param(
        [object]$Event,
        [object]$Payload
    )

    return (
        ([string](Get-PropertyValue $Event "title") -eq [string](Get-PropertyValue $Payload "title")) -and
        ([string](Get-PropertyValue $Event "subtitle") -eq [string](Get-PropertyValue $Payload "subtitle")) -and
        ([string](Get-PropertyValue $Event "placeId") -eq [string](Get-PropertyValue $Payload "placeId")) -and
        ((Convert-ToUtcTimestamp (Get-PropertyValue $Event "startTime") "returned startTime") -eq [string](Get-PropertyValue $Payload "startTime")) -and
        ((Convert-ToUtcTimestamp (Get-PropertyValue $Event "endTime") "returned endTime") -eq [string](Get-PropertyValue $Payload "endTime")) -and
        (([string](Get-PropertyValue $Event "visibility")).ToLowerInvariant() -eq ([string](Get-PropertyValue $Payload "visibility")).ToLowerInvariant())
    )
}

function Write-State {
    param(
        [string]$Path,
        [hashtable]$StateMap,
        [object]$Candidate,
        [object]$Event,
        [object]$Payload,
        [long]$UniverseId,
        [long]$PlaceId
    )

    $stateKey = Get-EventStateKey $Candidate.eventKey $Candidate.window.start
    $StateMap[$stateKey] = [ordered]@{
        eventId = [string](Get-PropertyValue $Event "id")
        eventKey = $Candidate.eventKey
        universeId = [string]$UniverseId
        placeId = [string]$PlaceId
        startTime = [string](Get-PropertyValue $Payload "startTime")
        endTime = [string](Get-PropertyValue $Payload "endTime")
        lastSyncStatus = "success"
        lastSyncUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $orderedEvents = [ordered]@{}
    foreach ($key in ($StateMap.Keys | Sort-Object)) {
        $orderedEvents[$key] = $StateMap[$key]
    }
    $state = [ordered]@{
        version = 2
        universeId = [string]$UniverseId
        placeId = [string]$PlaceId
        events = $orderedEvents
        lastSyncUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}

try {
    Import-LocalDotEnv -Path $LocalDotEnvPath

    $configFile = Resolve-LocalPath $ConfigPath
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Config not found: $configFile. Copy config.example.json to config.json first."
    }

    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    $script:UniverseId = Convert-ToInt64 (Get-PropertyValue $config "universeId") "universeId"
    $placeId = Convert-ToInt64 (Get-PropertyValue $config "placeId") "placeId"
    $groupId = 0
    $groupIdValue = Get-PropertyValue $config "groupId"
    if ($null -ne $groupIdValue -and -not [string]::IsNullOrWhiteSpace([string]$groupIdValue)) {
        $groupId = Convert-ToInt64 $groupIdValue "groupId"
    }

    $stateFileValue = Get-PropertyValue $config "stateFile"
    $stateFile = if ($null -ne $stateFileValue -and -not [string]::IsNullOrWhiteSpace([string]$stateFileValue)) {
        Resolve-LocalPath ([string]$stateFileValue)
    } else {
        Resolve-LocalPath "event-state.json"
    }
    $state = if (Test-Path -LiteralPath $stateFile) {
        Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    } else {
        $null
    }
    $stateMap = Get-StateMap $state
    $nowUtc = if ([string]::IsNullOrWhiteSpace($NowUtcOverride)) {
        [DateTimeOffset]::UtcNow
    } else {
        Convert-ToUtcDateTimeOffset $NowUtcOverride "NowUtcOverride"
    }
    $candidates = Select-SyncCandidates $config $nowUtc $EventKey
    if ($candidates.Count -eq 0) {
        throw "No enabled event has a current or future schedule."
    }

    Write-Host "Roblox Event Sync"
    Write-Host "Target: universe=$script:UniverseId | group=$groupId | place=$placeId"
    Write-Host "Selected $($candidates.Count) event window(s): current plus staged next window per eventKey"
    Write-Host "Mode: $(if ($Apply) { 'APPLY' } else { 'DRY-RUN' })"

    $payloads = @{}
    foreach ($candidate in $candidates) {
        $stateKey = Get-EventStateKey $candidate.eventKey $candidate.window.start
        $desiredVisibility = Get-DesiredVisibility `
            -Event $candidate.event `
            -Candidate $candidate `
            -RootConfig $config
        $payload = New-EventPayload `
            -Event $candidate.event `
            -WindowStart $candidate.window.start `
            -WindowEnd $candidate.window.end `
            -PlaceId $placeId `
            -GroupId $groupId `
            -RootConfig $config `
            -Visibility $desiredVisibility
        $payloads[$stateKey] = $payload
        $status = if ($candidate.active) { "ACTIVE" } else { "UPCOMING" }
        Write-Host "Selected: key=$($candidate.eventKey) | status=$status | visibility=$desiredVisibility | stagedNext=$($candidate.isNext)"
        Write-Host "Window: $($payload.startTime) to $($payload.endTime)"
        Write-Host "Payload:"
        Write-Host ($payload | ConvertTo-Json -Depth 12)
    }

    if (-not $Apply) {
        Write-Host "Dry-run complete. No Roblox API request was made. Use -Apply only after reviewing payload."
        exit 0
    }

    $script:ApiKey = ([string][Environment]::GetEnvironmentVariable($ApiKeyEnvironmentVariable)).Trim()
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        throw "Missing environment variable $ApiKeyEnvironmentVariable. API key never read from config or source code."
    }
    if ($script:ApiKey.Contains("`r") -or $script:ApiKey.Contains("`n") -or $script:ApiKey.Contains("`0")) {
        throw "$ApiKeyEnvironmentVariable contains an internal newline or NUL character. Re-enter the secret as one line."
    }

    foreach ($candidate in $candidates) {
        $event = $candidate.event
        $stateKey = Get-EventStateKey $candidate.eventKey $candidate.window.start
        $payload = $payloads[$stateKey]
        $existingEvent = Get-ManagedEvent `
            -Event $event `
            -Candidate $candidate `
            -StateMap $stateMap `
            -PlaceId $placeId `
            -PageLimit $MaxPages

        if ($null -ne $existingEvent) {
            $existingId = Convert-ToInt64 (Get-PropertyValue $existingEvent "id") "existing event id"
            Write-Host "Updating existing event: key=$($candidate.eventKey) | eventId=$existingId"
            $updatePayload = [ordered]@{}
            foreach ($property in $payload.PSObject.Properties) {
                if ($property.Name -ne "groupId") {
                    $updatePayload[$property.Name] = $property.Value
                }
            }
            $managedEvent = Invoke-RobloxEventRequest `
                -Method PATCH `
                -Uri "$ApiRoot/game-events/$existingId" `
                -Body ([pscustomobject]$updatePayload)
        } else {
            Write-Host "Creating new $($candidate.eventKey) event."
            $managedEvent = Invoke-RobloxEventRequest `
                -Method POST `
                -Uri "$ApiRoot/universes/$script:UniverseId/game-events" `
                -Body $payload
        }

        $managedEventId = Convert-ToInt64 (Get-PropertyValue $managedEvent "id") "returned event id"
        $verifiedEvent = Invoke-RobloxEventRequest -Method GET -Uri "$ApiRoot/game-events/$managedEventId`?fields=*"
        if (-not (Test-EventCoreFields -Event $verifiedEvent -Payload $payload)) {
            throw "Verification failed for event $managedEventId. State was not written for key $($candidate.eventKey)."
        }

        $requestedThumbnail = Get-PropertyValue $payload "thumbnails"
        if ($null -ne $requestedThumbnail) {
            $returnedThumbnail = Get-PropertyValue $verifiedEvent "thumbnails"
            if ($null -eq $returnedThumbnail -or @($returnedThumbnail).Count -eq 0) {
                Write-Warning "Roblox accepted event but returned no thumbnail. Check moderation or asset processing."
            }
        }

        Write-State `
            -Path $stateFile `
            -StateMap $stateMap `
            -Candidate $candidate `
            -Event $verifiedEvent `
            -Payload $payload `
            -UniverseId $script:UniverseId `
            -PlaceId $placeId
        Write-Host "Sync succeeded: key=$($candidate.eventKey) | eventId=$managedEventId"
    }
    Write-Host "State written: $stateFile"
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
