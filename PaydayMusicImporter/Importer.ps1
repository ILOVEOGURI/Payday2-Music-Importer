[CmdletBinding()]
param(
    [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$script:ModRoot = $PSScriptRoot
$script:IpcRoot = Join-Path $script:ModRoot 'ipc'
$script:RequestDir = Join-Path $script:IpcRoot 'requests'
$script:ProcessingDir = Join-Path $script:IpcRoot 'processing'
$script:CompletedDir = Join-Path $script:IpcRoot 'completed'
$script:StatusDir = Join-Path $script:IpcRoot 'status'
$script:LatestStatusPath = Join-Path $script:StatusDir 'latest.json'
$script:HelperStatusPath = Join-Path $script:StatusDir 'helper.json'
$script:PickerStatusPath = Join-Path $script:StatusDir 'picker.json'
$script:PickerBridgePath = Join-Path $script:ModRoot 'PickerBridge.ps1'
$script:BrowserExtensionPath = Join-Path $script:ModRoot 'browser-extension'
$script:UserRoot = Join-Path $env:LOCALAPPDATA 'PD2MusicImporter'
$script:BrowserProfilePath = Join-Path $script:UserRoot 'chromium-profile'
$script:ChromiumRoot = Join-Path $script:UserRoot 'chromium'
$script:ChromiumExe = Join-Path $script:ChromiumRoot 'chrome-win\chrome.exe'
$script:ToolsDir = Join-Path $script:UserRoot 'tools'
$script:SettingsPath = Join-Path $script:UserRoot 'settings.json'
$script:YtDlpPath = Join-Path $script:ToolsDir 'yt-dlp.exe'
$script:DenoPath = Join-Path $script:ToolsDir 'deno.exe'
$script:FfmpegPath = Join-Path $script:ToolsDir 'ffmpeg.exe'
$script:ResolvedGameRoot = $null

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

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
    Write-Utf8File -Path $temporary -Text $jsonText
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Percent = $null
    )

    $statusPercent = $null
    if ($null -ne $Percent) {
        $statusPercent = [double]$Percent
    }

    $status = [ordered]@{
        id = [string]$Request.id
        name = [string]$Request.name
        state = $State
        percent = $statusPercent
        message = $Message
        updatedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }

    Write-AtomicJson -Path (Join-Path $script:StatusDir "$($Request.id).json") -Value $status
    Write-AtomicJson -Path $script:LatestStatusPath -Value $status
}

function Write-HelperHeartbeat {
    param(
        [string]$State = 'ready',
        [string]$Message = 'PowerShell helper is running.'
    )

    $heartbeat = [ordered]@{
        state = $State
        message = $Message
        pid = $PID
        updatedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    Write-AtomicJson -Path $script:HelperStatusPath -Value $heartbeat
}

function Start-PickerBridge {
    if (-not (Test-Path -LiteralPath $script:PickerBridgePath -PathType Leaf)) {
        Write-Host 'YouTube picker bridge is missing; manual URL imports remain available.' -ForegroundColor Yellow
        return
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ParentPid {1}' -f $script:PickerBridgePath, $PID
    try {
        $null = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    } catch {
        Write-Host "Could not start the YouTube picker bridge: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-Path -LiteralPath $script:PickerStatusPath -PathType Leaf)) {
            continue
        }
        try {
            $picker = Get-Content -LiteralPath $script:PickerStatusPath -Raw | ConvertFrom-Json
            if ([int]$picker.parentPid -eq $PID -and $picker.state -eq 'ready') {
                Write-Host 'YouTube picker bridge is ready.'
                return
            }
            if ([int]$picker.parentPid -eq $PID -and $picker.state -eq 'error') {
                Write-Host "YouTube picker bridge could not start: $($picker.message)" -ForegroundColor Yellow
                return
            }
        } catch {
        }
    }
    Write-Host 'YouTube picker bridge did not report ready. Manual URL imports remain available.' -ForegroundColor Yellow
}

function Start-YouTubePicker {
    Ensure-Chromium
    if (-not (Test-Path -LiteralPath (Join-Path $script:BrowserExtensionPath 'manifest.json') -PathType Leaf)) {
        throw 'The bundled Chromium picker extension is missing from the mod folder.'
    }
    New-Item -ItemType Directory -Path $script:BrowserProfilePath -Force | Out-Null
    $profile = [System.IO.Path]::GetFullPath($script:BrowserProfilePath)
    $extension = [System.IO.Path]::GetFullPath($script:BrowserExtensionPath)
    $arguments = '--user-data-dir="{0}" --no-first-run --no-default-browser-check --disable-extensions-except="{1}" --load-extension="{1}" --remote-debugging-address=127.0.0.1 --remote-debugging-port=18922 --remote-allow-origins=* --new-window https://www.youtube.com/' -f $profile, $extension
    Start-Process -FilePath $script:ChromiumExe -ArgumentList $arguments | Out-Null
    Write-Host 'Opened the YouTube picker in standalone Chromium.'
}

function Restart-Payday2 {
    param([Parameter(Mandatory = $true)]$Request)

    $gameExecutable = [System.IO.Path]::GetFullPath((Join-Path $script:ResolvedGameRoot 'PAYDAY2.exe'))
    if (-not (Test-Path -LiteralPath $gameExecutable -PathType Leaf)) {
        throw "PAYDAY 2 executable was not found at $gameExecutable."
    }

    Write-Status -Request $Request -State 'restarting' -Percent 0 -Message 'Closing PAYDAY 2 before restarting through Steam.'
    Write-HelperHeartbeat -State 'restarting' -Message 'Waiting for PAYDAY 2 to close.'
    Write-Host 'Restart requested from the in-game importer menu.' -ForegroundColor Cyan

    $gameProcesses = @(
        Get-Process -Name 'PAYDAY2' -ErrorAction SilentlyContinue | Where-Object {
            try {
                $processPath = [System.IO.Path]::GetFullPath($_.Path)
                [string]::Equals($processPath, $gameExecutable, [StringComparison]::OrdinalIgnoreCase)
            } catch {
                $false
            }
        }
    )

    foreach ($gameProcess in $gameProcesses) {
        try {
            if (-not $gameProcess.HasExited) {
                $null = $gameProcess.CloseMainWindow()
            }
        } catch {
        }
    }

    $closeDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($gameProcesses.Count -gt 0) {
        $stillRunning = @()
        foreach ($gameProcess in $gameProcesses) {
            try {
                $gameProcess.Refresh()
                if (-not $gameProcess.HasExited) {
                    $stillRunning += $gameProcess
                }
            } catch {
            }
        }

        if ($stillRunning.Count -eq 0) {
            break
        }
        if ([DateTime]::UtcNow -ge $closeDeadline) {
            foreach ($gameProcess in $stillRunning) {
                try {
                    Stop-Process -Id $gameProcess.Id -Force -ErrorAction Stop
                } catch {
                    Write-Host "Could not close PAYDAY 2 process $($gameProcess.Id): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            break
        }
        Start-Sleep -Milliseconds 500
    }

    foreach ($gameProcess in $gameProcesses) {
        try {
            $gameProcess.WaitForExit(5000)
        } catch {
        }
    }

    $stillOpen = @(
        Get-Process -Name 'PAYDAY2' -ErrorAction SilentlyContinue | Where-Object {
            try {
                $processPath = [System.IO.Path]::GetFullPath($_.Path)
                [string]::Equals($processPath, $gameExecutable, [StringComparison]::OrdinalIgnoreCase)
            } catch {
                $false
            }
        }
    )
    if ($stillOpen.Count -gt 0) {
        throw 'PAYDAY 2 did not close, so Steam was not asked to launch a second copy.'
    }

    Write-Status -Request $Request -State 'restarting' -Percent 65 -Message 'PAYDAY 2 is closed. Waiting 5 seconds before launching it through Steam.'
    Write-HelperHeartbeat -State 'restarting' -Message 'Waiting 5 seconds before the Steam relaunch.'
    Start-Sleep -Seconds 5

    $steamLaunchUri = 'steam://rungameid/218620'
    Start-Process -FilePath $steamLaunchUri -ErrorAction Stop | Out-Null
    Write-Status -Request $Request -State 'complete' -Percent 100 -Message 'Steam was asked to relaunch PAYDAY 2 (App ID 218620).'
    Write-HelperHeartbeat -State 'ready' -Message 'PowerShell helper is running.'
    Write-Host "Launched PAYDAY 2 through Steam: $steamLaunchUri" -ForegroundColor Green
}

function Test-GameRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return (Test-Path -LiteralPath (Join-Path $fullPath 'assets') -PathType Container)
}

function Get-SteamLibraries {
    $libraries = New-Object System.Collections.Generic.List[string]
    $steamRoots = New-Object System.Collections.Generic.List[string]

    foreach ($registryPath in @('HKCU:\Software\Valve\Steam', 'HKCU:\Software\WOW6432Node\Valve\Steam')) {
        try {
            $steam = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            if ($steam.SteamPath) {
                $steamRoots.Add(([string]$steam.SteamPath -replace '/', '\'))
            }
            if ($steam.InstallPath) {
                $steamRoots.Add(([string]$steam.InstallPath -replace '/', '\'))
            }
        } catch {
        }
    }

    foreach ($steamRoot in ($steamRoots | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $steamRoot -PathType Container) {
            $libraries.Add($steamRoot)
        }

        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $libraryFile -ErrorAction SilentlyContinue) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $candidate = $matches[1] -replace '\\\\', '\'
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $libraries.Add($candidate)
                    }
                }
            }
        }
    }

    return $libraries | Select-Object -Unique
}

function Select-GameRoot {
    $selected = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the PAYDAY 2 installation folder (the folder containing the assets directory).'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.SelectedPath
        }
        $dialog.Dispose()
    } catch {
    }

    if (-not $selected) {
        $selected = Read-Host 'Enter the PAYDAY 2 installation folder (the folder containing assets)'
        if ($selected) {
            $selected = $selected.Trim().Trim('"')
        }
    }

    return $selected
}

function Resolve-GameRoot {
    if ($GameRoot -and (Test-GameRoot -Path $GameRoot)) {
        return [System.IO.Path]::GetFullPath($GameRoot)
    }

    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($settings.gameRoot -and (Test-GameRoot -Path ([string]$settings.gameRoot))) {
                return [System.IO.Path]::GetFullPath([string]$settings.gameRoot)
            }
        } catch {
        }
    }

    $modParent = Split-Path -Parent $script:ModRoot
    $localGuess = Split-Path -Parent $modParent
    if (Test-GameRoot -Path $localGuess) {
        return [System.IO.Path]::GetFullPath($localGuess)
    }

    foreach ($library in Get-SteamLibraries) {
        $candidate = Join-Path $library 'steamapps\common\PAYDAY 2'
        if (Test-GameRoot -Path $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $picked = Select-GameRoot
    if (-not (Test-GameRoot -Path $picked)) {
        throw 'The selected folder does not contain an assets directory. The helper needs the PAYDAY 2 install folder.'
    }

    $resolved = [System.IO.Path]::GetFullPath($picked)
    Write-AtomicJson -Path $script:SettingsPath -Value ([ordered]@{ gameRoot = $resolved })
    return $resolved
}

function Invoke-WebDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-HelperHeartbeat -State 'setup' -Message 'Setting up the download tools.'
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download did not create $Destination"
    }
    Write-HelperHeartbeat -State 'setup' -Message 'Download tool setup is continuing.'
}

function Ensure-Tools {
    New-Item -ItemType Directory -Path $script:ToolsDir -Force | Out-Null
    $missing = -not (Test-Path -LiteralPath $script:YtDlpPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $script:DenoPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $script:FfmpegPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $script:ToolsDir 'ffprobe.exe') -PathType Leaf)

    if (-not $missing) {
        return
    }

    Write-Host 'Setting up the audio download tools in:' $script:ToolsDir
    Write-Host 'This first-run setup downloads yt-dlp, Deno, and FFmpeg from their upstream release sources.'
    $setupDir = Join-Path $script:ToolsDir ('.setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null

    try {
        if (-not (Test-Path -LiteralPath $script:YtDlpPath -PathType Leaf)) {
            $ytDlpTemp = Join-Path $setupDir 'yt-dlp.exe'
            $checksums = Join-Path $setupDir 'SHA2-256SUMS'
            Invoke-WebDownload -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -Destination $ytDlpTemp
            Invoke-WebDownload -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS' -Destination $checksums

            $checksumLine = Get-Content -LiteralPath $checksums | Where-Object { $_ -match '\s+\*?yt-dlp\.exe$' } | Select-Object -First 1
            if (-not $checksumLine) {
                throw 'Could not find the yt-dlp.exe checksum in the upstream checksum file.'
            }
            $expectedHash = ($checksumLine -split '\s+')[0].Trim()
            $actualHash = (Get-FileHash -LiteralPath $ytDlpTemp -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                throw 'The yt-dlp download failed its SHA-256 checksum check.'
            }
            Move-Item -LiteralPath $ytDlpTemp -Destination $script:YtDlpPath -Force
        }

        if (-not (Test-Path -LiteralPath $script:DenoPath -PathType Leaf)) {
            $denoZip = Join-Path $setupDir 'deno.zip'
            $denoExtract = Join-Path $setupDir 'deno'
            Invoke-WebDownload -Uri 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' -Destination $denoZip
            Expand-Archive -LiteralPath $denoZip -DestinationPath $denoExtract -Force
            $denoBinary = Get-ChildItem -LiteralPath $denoExtract -Filter 'deno.exe' -File -Recurse | Select-Object -First 1
            if (-not $denoBinary) {
                throw 'The Deno release archive did not contain deno.exe.'
            }
            Copy-Item -LiteralPath $denoBinary.FullName -Destination $script:DenoPath -Force
        }

        $ffprobePath = Join-Path $script:ToolsDir 'ffprobe.exe'
        if (-not (Test-Path -LiteralPath $script:FfmpegPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ffprobePath -PathType Leaf)) {
            $ffmpegZip = Join-Path $setupDir 'ffmpeg.zip'
            $ffmpegChecksum = Join-Path $setupDir 'ffmpeg.sha256'
            $ffmpegExtract = Join-Path $setupDir 'ffmpeg'
            $ffmpegUri = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            Invoke-WebDownload -Uri $ffmpegUri -Destination $ffmpegZip
            Invoke-WebDownload -Uri "$ffmpegUri.sha256" -Destination $ffmpegChecksum
            $expectedFfmpegHash = ((Get-Content -LiteralPath $ffmpegChecksum -Raw).Trim() -split '\s+')[0]
            $actualFfmpegHash = (Get-FileHash -LiteralPath $ffmpegZip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualFfmpegHash -ne $expectedFfmpegHash.ToLowerInvariant()) {
                throw 'The FFmpeg download failed its SHA-256 checksum check.'
            }
            Expand-Archive -LiteralPath $ffmpegZip -DestinationPath $ffmpegExtract -Force
            $ffmpegBinary = Get-ChildItem -LiteralPath $ffmpegExtract -Filter 'ffmpeg.exe' -File -Recurse | Select-Object -First 1
            $ffprobeBinary = Get-ChildItem -LiteralPath $ffmpegExtract -Filter 'ffprobe.exe' -File -Recurse | Select-Object -First 1
            if (-not $ffmpegBinary -or -not $ffprobeBinary) {
                throw 'The FFmpeg release archive did not contain both ffmpeg.exe and ffprobe.exe.'
            }
            $ffmpegBinDirectory = Split-Path -Parent $ffmpegBinary.FullName
            Get-ChildItem -LiteralPath $ffmpegBinDirectory -File | Copy-Item -Destination $script:ToolsDir -Force
        }
    } finally {
        $fullSetup = [System.IO.Path]::GetFullPath($setupDir)
        $fullTools = [System.IO.Path]::GetFullPath($script:ToolsDir)
        if ($fullSetup.StartsWith($fullTools, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullSetup -PathType Container)) {
            Remove-Item -LiteralPath $fullSetup -Recurse -Force
        }
    }

    Write-Host 'Tool setup complete.'
}

function Ensure-Chromium {
    if (Test-Path -LiteralPath $script:ChromiumExe -PathType Leaf) {
        return
    }

    $snapshotRoot = 'https://storage.googleapis.com/chromium-browser-snapshots/Win_x64'
    Write-Host 'Downloading the official Chromium browser snapshot. This is a large first-run download.' -ForegroundColor Cyan
    $buildResponse = Invoke-WebRequest -Uri "$snapshotRoot/LAST_CHANGE" -UseBasicParsing -TimeoutSec 30
    $buildId = ([string]$buildResponse.Content).Trim()
    if ($buildId -notmatch '^\d+$') {
        throw 'The Chromium snapshot service did not return a valid Windows build number.'
    }

    if (Test-Path -LiteralPath $script:ChromiumRoot -PathType Container) {
        throw 'A partial Chromium folder already exists. Remove %LOCALAPPDATA%\PD2MusicImporter\chromium and try again.'
    }
    New-Item -ItemType Directory -Path $script:ChromiumRoot -Force | Out-Null
    $archive = Join-Path $script:UserRoot 'chromium-snapshot.zip'
    $archiveUri = "$snapshotRoot/$buildId/chrome-win.zip"
    Invoke-WebDownload -Uri $archiveUri -Destination $archive
    Write-Host 'Extracting Chromium...' -ForegroundColor Cyan
    Expand-Archive -LiteralPath $archive -DestinationPath $script:ChromiumRoot -Force
    if (-not (Test-Path -LiteralPath $script:ChromiumExe -PathType Leaf)) {
        throw 'The Chromium archive did not contain chrome-win\chrome.exe.'
    }
    Write-AtomicJson -Path (Join-Path $script:UserRoot 'chromium-build.json') -Value ([ordered]@{
        source = $snapshotRoot
        build = $buildId
        installedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
    Remove-Item -LiteralPath $archive -Force
    Write-Host "Chromium $buildId is ready."
}

function Test-YouTubeUrl {
    param([string]$Url)

    $parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) {
        return $false
    }
    if ($parsed.Scheme -ne 'https' -and $parsed.Scheme -ne 'http') {
        return $false
    }
    if ($parsed.UserInfo -or -not $parsed.IsDefaultPort) {
        return $false
    }

    $allowedHosts = @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be')
    return $allowedHosts -contains $parsed.Host.ToLowerInvariant()
}

function ConvertTo-TrackSlug {
    param([string]$Name)

    $normalized = $Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $normalized = $normalized.Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = 'track'
    }
    if ($normalized.Length -gt 48) {
        $normalized = $normalized.Substring(0, 48).TrimEnd('-')
    }
    return $normalized
}

function Get-UniqueModFolder {
    param(
        [string]$OverrideRoot,
        [string]$Slug,
        [string]$Suffix
    )

    $candidate = Join-Path $OverrideRoot "$Slug-$Suffix"
    $counter = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $OverrideRoot "$Slug-$Suffix-$counter"
        $counter++
    }
    return $candidate
}

function Write-MenuMusicFiles {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$OggPath
    )

    $overrideRoot = Join-Path $script:ResolvedGameRoot 'assets\mod_overrides'
    New-Item -ItemType Directory -Path $overrideRoot -Force | Out-Null

    $idMaterial = [string]$Request.id
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($idMaterial))
    $shortId = 'pd2mi_' + ([BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 12).ToLowerInvariant())
    $slug = ConvertTo-TrackSlug -Name ([string]$Request.name)
    $suffix = ([string]$Request.id -replace '[^a-zA-Z0-9]', '')
    if ($suffix.Length -gt 8) {
        $suffix = $suffix.Substring($suffix.Length - 8)
    }
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    $finalFolder = Get-UniqueModFolder -OverrideRoot $overrideRoot -Slug $slug -Suffix $suffix
    $stageFolder = Join-Path $overrideRoot ('.pd2mi-stage-' + [guid]::NewGuid().ToString('N'))
    $soundsFolder = Join-Path $stageFolder 'sounds'
    $locFolder = Join-Path $stageFolder 'loc'
    New-Item -ItemType Directory -Path $soundsFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $locFolder -Force | Out-Null

    try {
        Copy-Item -LiteralPath $OggPath -Destination (Join-Path $soundsFolder "$shortId.ogg")
        $escapedName = [System.Security.SecurityElement]::Escape([string]$Request.name)
        $xml = @"
<table name="$escapedName">
    <Localization directory="loc" default="en.txt" />
    <MenuMusic id="$shortId" source="sounds/$shortId.ogg" />
</table>
"@
        Write-Utf8File -Path (Join-Path $stageFolder 'main.xml') -Text $xml

        $localization = [ordered]@{
            menu_jukebox_menu = [string]$Request.name
            menu_jukebox_screen_menu = [string]$Request.name
        }
        $localization["menu_jukebox_$shortId"] = [string]$Request.name
        $localization["menu_jukebox_screen_$shortId"] = [string]$Request.name
        $localizationJson = ConvertTo-Json -InputObject $localization -Depth 4
        Write-Utf8File -Path (Join-Path $locFolder 'en.txt') -Text $localizationJson

        if (-not (Test-Path -LiteralPath (Join-Path $soundsFolder "$shortId.ogg") -PathType Leaf)) {
            throw 'The staged OGG file could not be verified.'
        }

        Move-Item -LiteralPath $stageFolder -Destination $finalFolder
    } catch {
        if (Test-Path -LiteralPath $stageFolder -PathType Container) {
            Remove-Item -LiteralPath $stageFolder -Recurse -Force
        }
        throw
    }

    return $finalFolder
}

function Invoke-ImportRequest {
    param([Parameter(Mandatory = $true)][string]$RequestFile)

    $requestId = [System.IO.Path]::GetFileNameWithoutExtension($RequestFile)
    if ($requestId -notmatch '^[A-Za-z0-9_-]{1,64}$') {
        throw 'The request file name is not a valid request ID.'
    }

    $processingPath = Join-Path $script:ProcessingDir "$requestId.json"
    try {
        Move-Item -LiteralPath $RequestFile -Destination $processingPath -ErrorAction Stop
    } catch {
        return
    }

    $request = $null
    try {
        $request = Get-Content -LiteralPath $processingPath -Raw | ConvertFrom-Json
        $bodyId = [string]$request.id
        $request.id = $requestId
        if ($bodyId -ne $requestId) {
            throw 'The request ID does not match its file name.'
        }
        if ($request.PSObject.Properties['action'] -and [string]$request.action -eq 'open_picker') {
            Write-Status -Request $request -State 'opening' -Percent $null -Message 'Opening YouTube in the Chromium browser.'
            Start-YouTubePicker
            Write-Status -Request $request -State 'complete' -Percent 100 -Message 'YouTube is open. Choose a video to queue it for download.'
            Move-Item -LiteralPath $processingPath -Destination (Join-Path $script:CompletedDir "$requestId.json") -Force
            return
        }
        if ($request.PSObject.Properties['action'] -and [string]$request.action -eq 'restart_game') {
            Restart-Payday2 -Request $request
            Move-Item -LiteralPath $processingPath -Destination (Join-Path $script:CompletedDir "$requestId.json") -Force
            return
        }
        if (-not $request.PSObject.Properties['name']) {
            throw 'The request is missing its track name.'
        }
        if (-not (Test-YouTubeUrl -Url ([string]$request.url))) {
            throw 'Only standard YouTube video links are supported.'
        }
        $trackName = [string]$request.name
        if ([string]::IsNullOrWhiteSpace($trackName) -or $trackName.Length -gt 100 -or $trackName -match '[\x00-\x1F]') {
            throw 'The track name must contain 1 to 100 printable characters.'
        }

        Write-Status -Request $request -State 'downloading' -Percent 0 -Message 'Downloading and converting audio. See this helper window for details.'
        Write-HelperHeartbeat -State 'processing' -Message "Processing: $trackName"

        $downloadDir = Join-Path $script:UserRoot ('downloads\' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        try {
            $videoTitlePath = Join-Path $downloadDir 'video-title.txt'
            $ytDlpArguments = @(
                '--no-playlist',
                '--newline',
                '--format', 'bestaudio/best',
                '--js-runtimes', "deno:$($script:DenoPath)",
                '--remote-components', 'ejs:github',
                '--print-to-file', 'before_dl:%(title)s', $videoTitlePath,
                '--output', (Join-Path $downloadDir 'source.%(ext)s'),
                [string]$request.url
            )

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $script:YtDlpPath @ytDlpArguments 2>&1 | ForEach-Object {
                    $line = [string]$_
                    Write-Host $line
                    Write-HelperHeartbeat -State 'processing' -Message "Processing: $trackName"
                    if ($line -match '^\[download\]\s+([0-9]+(?:\.[0-9]+)?)%') {
                        $downloadPercent = [Math]::Min(95, [Math]::Max(0, [double]$matches[1]))
                        Write-Status -Request $request -State 'downloading' -Percent $downloadPercent -Message "Downloading audio ($downloadPercent%)."
                    }
                }
                $downloadExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($downloadExitCode -ne 0) {
                throw "yt-dlp exited with code $downloadExitCode. The video may be unavailable or YouTube may require access this helper cannot provide."
            }

            if (Test-Path -LiteralPath $videoTitlePath -PathType Leaf) {
                $videoTitle = (Get-Content -LiteralPath $videoTitlePath -Raw).Trim()
                $videoTitle = [regex]::Replace($videoTitle, '[\x00-\x1F]+', ' ')
                $videoTitle = [regex]::Replace($videoTitle, '\s+', ' ').Trim()
                $isExtensionImport = $request.PSObject.Properties['source'] -and ([string]$request.PSObject.Properties['source'].Value -eq 'extension')
                $useVideoTitle = $isExtensionImport -or ($trackName -match '^YouTube video [A-Za-z0-9_-]+$')
                if ($useVideoTitle -and -not [string]::IsNullOrWhiteSpace($videoTitle)) {
                    if ($videoTitle.Length -gt 100) {
                        $videoTitle = $videoTitle.Substring(0, 100).TrimEnd()
                    }
                    $trackName = $videoTitle
                    $request.name = $trackName
                    Write-Host "Using YouTube video title: $trackName"
                    Write-Status -Request $request -State 'downloading' -Percent 95 -Message "Downloaded: $trackName"
                }
            }

            $sourceFile = Get-ChildItem -LiteralPath $downloadDir -Filter 'source.*' -File | Select-Object -First 1
            if (-not $sourceFile -or $sourceFile.Length -le 0) {
                throw 'The download completed, but yt-dlp did not create an audio file.'
            }

            Write-Status -Request $request -State 'converting' -Percent 96 -Message 'Converting to clean 44.1 kHz stereo OGG audio.'
            $convertedOgg = Join-Path $downloadDir 'menu-track.ogg'
            $ffmpegArguments = @(
                '-hide_banner',
                '-loglevel', 'error',
                '-nostdin',
                '-y',
                '-i', $sourceFile.FullName,
                '-map_metadata', '-1',
                '-vn',
                '-c:a', 'libvorbis',
                '-q:a', '5',
                '-ar', '44100',
                '-ac', '2',
                $convertedOgg
            )
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $script:FfmpegPath @ffmpegArguments 2>&1 | ForEach-Object {
                    Write-Host ([string]$_)
                    Write-HelperHeartbeat -State 'processing' -Message "Converting: $trackName"
                }
                $ffmpegExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $convertedOgg -PathType Leaf) -or (Get-Item -LiteralPath $convertedOgg).Length -le 0) {
                throw "FFmpeg could not convert the source audio (exit code $ffmpegExitCode)."
            }

            Write-Status -Request $request -State 'installing' -Percent 98 -Message 'Audio is ready. Building the PAYDAY 2 menu music folder.'
            $installedFolder = Write-MenuMusicFiles -Request $request -OggPath $convertedOgg
            Write-Status -Request $request -State 'complete' -Percent 100 -Message "Installed to $installedFolder. Restart PAYDAY 2 to load the new track."
            Write-Host "Installed menu music: $installedFolder"
        } finally {
            if (Test-Path -LiteralPath $downloadDir -PathType Container) {
                Remove-Item -LiteralPath $downloadDir -Recurse -Force
            }
        }

        Move-Item -LiteralPath $processingPath -Destination (Join-Path $script:CompletedDir "$requestId.json") -Force
    } catch {
        $failedName = '(unknown track)'
        if ($request -and $request.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$request.name)) {
            $failedName = [string]$request.name
        }
        $request = [pscustomobject]@{ id = $requestId; name = $failedName }
        $message = $_.Exception.Message
        Write-Host "Import failed: $message" -ForegroundColor Red
        try {
            Write-Status -Request $request -State 'failed' -Percent $null -Message $message
        } catch {
            Write-Host "Could not write failure status: $($_.Exception.Message)" -ForegroundColor Red
        }
        if (Test-Path -LiteralPath $processingPath -PathType Leaf) {
            Move-Item -LiteralPath $processingPath -Destination (Join-Path $script:CompletedDir "$requestId.failed.json") -Force
        }
    }
}

function Restore-InterruptedRequests {
    foreach ($interrupted in Get-ChildItem -LiteralPath $script:ProcessingDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $requestBack = Join-Path $script:RequestDir $interrupted.Name
        if (-not (Test-Path -LiteralPath $requestBack)) {
            Move-Item -LiteralPath $interrupted.FullName -Destination $requestBack -Force
        }
    }
}

$script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Local\PD2MusicImporter.Helper')
$script:OwnsInstanceMutex = $false
try {
    $script:OwnsInstanceMutex = $script:InstanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $script:OwnsInstanceMutex = $true
}
if (-not $script:OwnsInstanceMutex) {
    Write-Host 'The PAYDAY 2 Music Importer helper is already running.'
    $script:InstanceMutex.Dispose()
    return
}

try {
    foreach ($directory in @($script:RequestDir, $script:ProcessingDir, $script:CompletedDir, $script:StatusDir, $script:UserRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Write-HelperHeartbeat -State 'starting' -Message 'Starting the PowerShell helper.'
    $script:ResolvedGameRoot = Resolve-GameRoot
    if (-not $GameRoot -and -not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        Write-AtomicJson -Path $script:SettingsPath -Value ([ordered]@{ gameRoot = $script:ResolvedGameRoot })
    }

    Ensure-Tools
    Start-PickerBridge
    Restore-InterruptedRequests
    Write-Host "PAYDAY 2 Music Importer is ready for: $script:ResolvedGameRoot"
    Write-Host 'The helper started with PAYDAY 2. Keep this window open while playing. Press Ctrl+C to stop.'

    while ($true) {
        Write-HelperHeartbeat -State 'ready' -Message 'PowerShell helper is running.'
        $nextRequest = Get-ChildItem -LiteralPath $script:RequestDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -First 1

        if ($nextRequest) {
            Invoke-ImportRequest -RequestFile $nextRequest.FullName
        } else {
            Start-Sleep -Seconds 1
        }
    }
} catch {
    $failure = $_.Exception.Message
    Write-Host "Helper error: $failure" -ForegroundColor Red
    try {
        Write-AtomicJson -Path $script:HelperStatusPath -Value ([ordered]@{
            state = 'error'
            message = $failure
            updatedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        })
    } catch {
    }
    throw
}
