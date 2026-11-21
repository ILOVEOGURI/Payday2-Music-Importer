[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$ParentPid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:DebugPort = 18922
$script:BridgePort = 18921
$script:ModRoot = $PSScriptRoot
$script:IpcRoot = Join-Path $script:ModRoot 'ipc'
$script:RequestDir = Join-Path $script:IpcRoot 'requests'
$script:StatusDir = Join-Path $script:IpcRoot 'status'
$script:LatestStatusPath = Join-Path $script:StatusDir 'latest.json'
$script:PickerStatusPath = Join-Path $script:StatusDir 'picker.json'
$script:TargetsEndpoint = "http://127.0.0.1:$script:DebugPort/json/list"
$script:Listener = $null
$script:RecentVideoIds = @{}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $jsonText = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($temporary, $jsonText, $encoding)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-PickerHeartbeat {
    param(
        [string]$State = 'ready',
        [string]$Message = 'Chromium picker is ready.'
    )

    Write-AtomicJson -Path $script:PickerStatusPath -Value ([ordered]@{
        state = $State
        message = $Message
        parentPid = $ParentPid
        updatedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
}

function Test-ParentRunning {
    try {
        $parent = Get-Process -Id $ParentPid -ErrorAction Stop
        return -not $parent.HasExited
    } catch {
        return $false
    }
}

function Get-YouTubeSelection {
    param([Parameter(Mandatory = $true)]$Target)

    $parsed = $null
    $rawUrl = [string]$Target.url
    if (-not [Uri]::TryCreate($rawUrl, [UriKind]::Absolute, [ref]$parsed)) {
        return $null
    }
    $allowedHosts = @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com')
    if ($parsed.Scheme -ne 'https' -or $allowedHosts -notcontains $parsed.Host.ToLowerInvariant() -or $parsed.AbsolutePath -ne '/watch') {
        return $null
    }
    $match = [regex]::Match($parsed.Query, '(?:\?|&)v=([A-Za-z0-9_-]{6,})')
    if (-not $match.Success) {
        return $null
    }

    $name = [string]$Target.title
    $name = $name -replace '\s+-\s+YouTube$', ''
    $name = [regex]::Replace($name, '[\x00-\x1F]', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'YouTube') {
        $name = "YouTube video $($match.Groups[1].Value)"
    }
    if ($name.Length -gt 100) {
        $name = $name.Substring(0, 100).Trim()
    }

    return [pscustomobject]@{
        url = $parsed.AbsoluteUri
        videoId = $match.Groups[1].Value
        name = $name
    }
}

function Queue-YouTubeSelection {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [ValidateSet('extension', 'devtools')][string]$Source = 'devtools'
    )

    $now = [DateTime]::UtcNow
    if ($script:RecentVideoIds.ContainsKey($Selection.videoId) -and ($now - $script:RecentVideoIds[$Selection.videoId]).TotalSeconds -lt 8) {
        return [pscustomobject]@{ ok = $true; duplicate = $true; name = [string]$Selection.name }
    }
    $script:RecentVideoIds[$Selection.videoId] = $now

    $id = 'picker_' + [guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        id = $id
        url = [string]$Selection.url
        name = [string]$Selection.name
        source = $Source
        createdEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    Write-AtomicJson -Path (Join-Path $script:RequestDir "$id.json") -Value $request
    Write-AtomicJson -Path $script:LatestStatusPath -Value ([ordered]@{
        id = $id
        name = [string]$Selection.name
        state = 'queued'
        percent = 0
        message = "Selected in Chromium ($Source). Download queued; the browser is returning to YouTube home."
        updatedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
    Write-Host "Queued YouTube video: $($Selection.name)"
    return [pscustomobject]@{ ok = $true; duplicate = $false; id = $id; name = [string]$Selection.name; source = $Source }
}

function Read-HttpRequest {
    param([Parameter(Mandatory = $true)][System.Net.Sockets.NetworkStream]$Stream)

    $reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    $requestLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        throw 'Empty browser request.'
    }

    $contentLength = 0
    $origin = ''
    while ($true) {
        $header = $reader.ReadLine()
        if ($null -eq $header -or $header -eq '') {
            break
        }
        if ($header -match '^Content-Length:\s*(\d+)\s*$') {
            $contentLength = [int]$matches[1]
        }
        if ($header -match '^Origin:\s*(.+?)\s*$') {
            $origin = $matches[1]
        }
    }
    if ($contentLength -lt 0 -or $contentLength -gt 16384) {
        throw 'Browser request body is too large.'
    }

    $body = ''
    if ($contentLength -gt 0) {
        $characters = New-Object char[] $contentLength
        $offset = 0
        while ($offset -lt $contentLength) {
            $read = $reader.Read($characters, $offset, $contentLength - $offset)
            if ($read -le 0) {
                throw 'Browser request ended before its body was complete.'
            }
            $offset += $read
        }
        $body = -join $characters
    }

    $parts = $requestLine -split '\s+', 3
    if ($parts.Count -lt 2) {
        throw 'Browser request line was invalid.'
    }
    return [pscustomobject]@{ method = $parts[0]; path = $parts[1]; origin = $origin; body = $body }
}

function Send-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Origin = 'null',
        [Parameter(Mandatory = $true)]$Body
    )

    $bodyText = ConvertTo-Json -InputObject $Body -Depth 4 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
    $headerText = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: application/json; charset=utf-8`r`nAccess-Control-Allow-Origin: $Origin`r`nAccess-Control-Allow-Methods: POST, OPTIONS`r`nAccess-Control-Allow-Headers: content-type`r`nAccess-Control-Allow-Private-Network: true`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerText)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Handle-ExtensionClient {
    param([Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $stream.ReadTimeout = 8000
    $stream.WriteTimeout = 8000
    $request = $null
    try {
        $request = Read-HttpRequest -Stream $stream
        if ($request.origin -notmatch '^chrome-extension://[a-p]{32}$') {
            Send-HttpResponse -Stream $stream -StatusCode 403 -Reason 'Forbidden' -Body ([ordered]@{ ok = $false; error = 'Only the bundled Chromium extension can use this bridge.' })
            return
        }
        if ($request.method -eq 'OPTIONS') {
            Send-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Origin $request.origin -Body ([ordered]@{ ok = $true })
            return
        }
        if ($request.method -ne 'POST' -or $request.path -ne '/import') {
            Send-HttpResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -Origin $request.origin -Body ([ordered]@{ ok = $false; error = 'Not found.' })
            return
        }

        $payload = [Uri]::UnescapeDataString($request.body) | ConvertFrom-Json
        $selection = Get-YouTubeSelection -Target $payload
        if (-not $selection) {
            throw 'The browser extension did not send a standard YouTube video page.'
        }
        $result = Queue-YouTubeSelection -Selection $selection -Source 'extension'
        Send-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Origin $request.origin -Body $result
    } catch {
        try {
            $safeOrigin = if ($request -and $request.origin -match '^chrome-extension://[a-p]{32}$') { $request.origin } else { 'null' }
            Send-HttpResponse -Stream $stream -StatusCode 400 -Reason 'Bad Request' -Origin $safeOrigin -Body ([ordered]@{ ok = $false; error = $_.Exception.Message })
        } catch {
        }
    } finally {
        $stream.Dispose()
        $Client.Close()
    }
}

function Return-ToYouTubeHome {
    param([Parameter(Mandatory = $true)][string]$WebSocketUrl)

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $socket.ConnectAsync([Uri]$WebSocketUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $command = ConvertTo-Json -InputObject ([ordered]@{
            id = 1
            method = 'Page.navigate'
            params = @{ url = 'https://www.youtube.com/' }
        }) -Depth 4 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($command)
        $segment = [System.ArraySegment[byte]]::new($bytes, 0, $bytes.Length)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        return $true
    } finally {
        $socket.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Path $script:RequestDir, $script:StatusDir -Force | Out-Null
    $script:Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $script:BridgePort)
    $script:Listener.Start()
    $pendingAccept = $script:Listener.BeginAcceptTcpClient($null, $null)
    Write-PickerHeartbeat -State 'ready' -Message 'Chromium bridge and bundled extension are ready.'
    $firstSeenAt = @{}
    $queuedVideoByTab = @{}
    $lastReturnAttempt = @{}
    $lastHeartbeat = [DateTime]::MinValue

    while (Test-ParentRunning) {
        if ($pendingAccept.IsCompleted) {
            $client = $script:Listener.EndAcceptTcpClient($pendingAccept)
            $pendingAccept = $script:Listener.BeginAcceptTcpClient($null, $null)
            Handle-ExtensionClient -Client $client
        }

        try {
            $targets = @(Invoke-RestMethod -Uri $script:TargetsEndpoint -TimeoutSec 2)
            foreach ($target in $targets) {
                if ([string]$target.type -ne 'page' -or [string]::IsNullOrWhiteSpace([string]$target.id)) {
                    continue
                }

                $tabId = [string]$target.id
                $selection = Get-YouTubeSelection -Target $target
                if (-not $selection) {
                    $firstSeenAt.Remove($tabId)
                    $queuedVideoByTab.Remove($tabId)
                    $lastReturnAttempt.Remove($tabId)
                    continue
                }

                if ($firstSeenAt.ContainsKey($tabId) -and $firstSeenAt[$tabId].videoId -ne $selection.videoId) {
                    $firstSeenAt.Remove($tabId)
                    $queuedVideoByTab.Remove($tabId)
                    $lastReturnAttempt.Remove($tabId)
                }
                if (-not $firstSeenAt.ContainsKey($tabId)) {
                    $firstSeenAt[$tabId] = [pscustomobject]@{ videoId = $selection.videoId; seenAt = [DateTime]::UtcNow }
                    continue
                }
                if (([DateTime]::UtcNow - $firstSeenAt[$tabId].seenAt).TotalMilliseconds -lt 5000) {
                    continue
                }

                if (-not $queuedVideoByTab.ContainsKey($tabId) -or $queuedVideoByTab[$tabId] -ne $selection.videoId) {
                    Queue-YouTubeSelection -Selection $selection -Source 'devtools' | Out-Null
                    $queuedVideoByTab[$tabId] = $selection.videoId
                    $lastReturnAttempt[$tabId] = [DateTime]::MinValue
                }

                if (([DateTime]::UtcNow - $lastReturnAttempt[$tabId]).TotalSeconds -ge 1) {
                    try {
                        if (Return-ToYouTubeHome -WebSocketUrl ([string]$target.webSocketDebuggerUrl)) {
                            $lastReturnAttempt[$tabId] = [DateTime]::UtcNow
                        }
                    } catch {
                        Write-PickerHeartbeat -State 'error' -Message "The video was queued, but Chromium could not return to YouTube home: $($_.Exception.Message)"
                        $lastReturnAttempt[$tabId] = [DateTime]::UtcNow
                    }
                }
            }
            if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 2) {
                Write-PickerHeartbeat -State 'ready' -Message 'Watching the Chromium window for YouTube video selections.'
                $lastHeartbeat = [DateTime]::UtcNow
            }
        } catch {
            if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 2) {
                Write-PickerHeartbeat -State 'ready' -Message 'Waiting for the Chromium picker window.'
                $lastHeartbeat = [DateTime]::UtcNow
            }
        }
        Start-Sleep -Milliseconds 150
    }
} catch {
    try {
        Write-PickerHeartbeat -State 'error' -Message $_.Exception.Message
    } catch {
    }
} finally {
    if ($script:Listener) {
        try { $script:Listener.Stop() } catch { }
    }
}
