$steamLibrary    = 'D:\Games\SteamLibrary'
$downloadingPath = "$steamLibrary\steamapps\downloading"

# How many seconds to wait after folder empties before triggering shutdown
# This window lets a queued game start downloading before we commit
$confirmSeconds  = 60

# ─── Helpers ────────────────────────────────────────────────────────────────

function Get-FolderSize($path) {
    if (-not (Test-Path $path)) { return 0 }
    $files = Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 } else { return $sum }
}

function Format-Bytes($bytes) {
    if ($null -eq $bytes -or $bytes -eq 0) { return "0 KB" }
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    return "{0:N2} KB" -f ($bytes / 1KB)
}

function Format-Time($seconds) {
    if ($null -eq $seconds -or $seconds -le 0) { return "Calculating..." }
    $ts = [TimeSpan]::FromSeconds([math]::Round($seconds))
    if ($ts.TotalHours -ge 1) { return "{0}h {1:D2}m {2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
    return "{0:D2}m {1:D2}s" -f $ts.Minutes, $ts.Seconds
}

function Get-ActiveAppId {
    $dirs = Get-ChildItem $downloadingPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } |
            Sort-Object LastWriteTime -Descending
    if ($dirs) { return $dirs[0].Name } else { return $null }
}

function Get-AllAppIds {
    $dirs = Get-ChildItem $downloadingPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } |
            Sort-Object LastWriteTime -Descending
    if ($dirs) { return $dirs.Name } else { return @() }
}

function Get-AppManifest($appId) {
    $acfPath = "$steamLibrary\steamapps\appmanifest_$appId.acf"
    if (-not (Test-Path $acfPath)) { return $null }
    $acf = Get-Content $acfPath -Raw -ErrorAction SilentlyContinue
    if (-not $acf) { return $null }
    $name       = [regex]::Match($acf, '"name"\s+"([^"]+)"').Groups[1].Value
    $installdir = [regex]::Match($acf, '"installdir"\s+"([^"]+)"').Groups[1].Value
    return @{
        Name       = if ($name)       { $name }       else { "App $appId" }
        InstallDir = if ($installdir) { $installdir } else { "" }
    }
}

function Get-SteamAppSize($appId) {
    try {
        $url   = "https://store.steampowered.com/api/appdetails?appids=$appId"
        $resp  = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
        $size  = $resp.$appId.data.size_on_disk
        if ($size -and [long]$size -gt 0) { return [long]$size }
    } catch { }
    return 0
}

function Draw-Bar($percent, $width = 32) {
    $clamped = [math]::Max(0, [math]::Min(100, $percent))
    $filled  = [math]::Max(0, [math]::Min($width, [int]($clamped / 100 * $width)))
    return "[" + ("#" * $filled) + ("-" * ($width - $filled)) + "]"
}

$script:lineCount = 0
function WL($text, $color = "Yellow") {
    Write-Host $text -ForegroundColor $color
    $script:lineCount++
}

function Clear-Display($count) {
    if ($count -le 0) { return }
    $y = [Console]::CursorTop - $count
    if ($y -lt 0) { $y = 0 }
    for ($i = 0; $i -lt $count; $i++) {
        [Console]::SetCursorPosition(0, $y + $i)
        Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
    }
    [Console]::SetCursorPosition(0, $y)
}

# ─── Startup ────────────────────────────────────────────────────────────────

Clear-Host
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "        Steam Download Watcher" -ForegroundColor Cyan
Write-Host "  Queue-aware: waits for all games done" -ForegroundColor DarkCyan
Write-Host "  2FA: download done + game size verified" -ForegroundColor DarkCyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Detecting active download..." -ForegroundColor Gray

# Per-appId cache: size fetched from API
$appSizeCache    = @{}
$appManifCache   = @{}
$cachedAppId     = $null
$peakDLSize      = 0
$prevDLBytes     = 0
$startTime       = Get-Date
$firstRun        = $true

# Queue state
# "watching"    = normal, download in progress
# "confirming"  = folder empty, waiting to see if new game starts
# "shutdown"    = confirmed done, triggering shutdown
$state           = "watching"
$emptyDetectedAt = $null

while ($true) {
    if (-not $firstRun) { Start-Sleep -Seconds 10 }
    $firstRun = $false

    $elapsed = (Get-Date) - $startTime
    $dlSize  = Get-FolderSize $downloadingPath
    $appId   = Get-ActiveAppId
    $allIds  = Get-AllAppIds

    if ($dlSize -gt $peakDLSize) { $peakDLSize = $dlSize }

    # Fetch manifest + API size when app ID changes
    if ($appId -and -not $appManifCache.ContainsKey($appId)) {
        $appManifCache[$appId] = Get-AppManifest $appId
        Write-Host ("  Fetching size for " + ($appManifCache[$appId].Name) + "...") -ForegroundColor Gray
        $appSizeCache[$appId]  = Get-SteamAppSize $appId
        $fetchedSize = $appSizeCache[$appId]
        if ($fetchedSize -gt 0) {
            Write-Host ("  Size: " + (Format-Bytes ([long]$fetchedSize))) -ForegroundColor Green
        } else {
            Write-Host "  Could not fetch size. Will use folder tracking." -ForegroundColor DarkYellow
        }
        if ($appId -ne $cachedAppId) {
            $peakDLSize  = $dlSize
            $prevDLBytes = 0
            $cachedAppId = $appId
        }
        Start-Sleep -Seconds 1
    }

    # ── State machine ─────────────────────────────────────────────────────

    if ($dlSize -gt 0) {
        # Downloads active — always return to watching
        if ($state -ne "watching") {
            $state           = "watching"
            $emptyDetectedAt = $null
        }
    } else {
        # Folder is empty
        if ($state -eq "watching" -and $elapsed.TotalSeconds -gt 20) {
            $state           = "confirming"
            $emptyDetectedAt = Get-Date
        }
    }

    # In confirming state — check if new download started
    if ($state -eq "confirming") {
        $waited = ((Get-Date) - $emptyDetectedAt).TotalSeconds
        if ($dlSize -gt 0) {
            # New download detected — reset to watching
            $state           = "watching"
            $emptyDetectedAt = $null
        } elseif ($waited -ge $confirmSeconds) {
            $state = "shutdown"
        }
    }

    # ── Current game display info ─────────────────────────────────────────
    $manifest     = if ($appId -and $appManifCache.ContainsKey($appId)) { $appManifCache[$appId] } else { $null }
    $gameName     = if ($manifest -and $manifest.Name)       { $manifest.Name }       else { if ($appId) { "App $appId" } else { "Detecting..." } }
    $installDir   = if ($manifest -and $manifest.InstallDir) { $manifest.InstallDir } else { "" }
    $gamePath     = if ($installDir) { "$steamLibrary\steamapps\common\$installDir" } else { "" }
    $expectedSize = if ($appId -and $appSizeCache.ContainsKey($appId)) { $appSizeCache[$appId] } else { 0 }

    $gameFolderExists = ($gamePath -ne "" -and (Test-Path $gamePath))
    $gameSize         = if ($gameFolderExists) { Get-FolderSize $gamePath } else { 0 }
    $threshold        = if ($expectedSize -gt 0) { [long]($expectedSize * 0.80) } else { 0 }
    $use2FA           = ($gameFolderExists -and $gameSize -gt 0 -and $threshold -gt 0)

    $dlPercent = if ($peakDLSize -gt 0) {
        [math]::Max(0, [math]::Min(100, [math]::Round($dlSize / $peakDLSize * 100, 1)))
    } else { 0 }

    $installPercent = if ($use2FA -and $expectedSize -gt 0) {
        [math]::Max(0, [math]::Min(100, [math]::Round($gameSize / $expectedSize * 100, 1)))
    } else { 0 }

    $speedBps  = if ($prevDLBytes -gt 0) { [math]::Max(0, ($dlSize - $prevDLBytes) / 10) } else { 0 }
    $speedMBs  = $speedBps / 1MB
    $remaining = if ($peakDLSize -gt 0 -and $dlSize -lt $peakDLSize) { $peakDLSize - $dlSize } else { 0 }
    $etaSec    = if ($speedBps -gt 0 -and $remaining -gt 0) { $remaining / $speedBps } else { -1 }

    $check1    = ($dlSize -eq 0)
    $check2    = if ($use2FA) { $gameSize -ge $threshold } else { $true }

    # ── Shutdown sequence ─────────────────────────────────────────────────
    if ($state -eq "shutdown") {
        Clear-Display $script:lineCount
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "  All done! No new games queued." -ForegroundColor Green
        Write-Host "  Shutting down in 60 seconds..." -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Start a new Steam download to cancel automatically." -ForegroundColor DarkYellow
        Write-Host "  Or run 'shutdown /a' in any CMD window." -ForegroundColor Red
        Write-Host ""

        $cancelled = $false
        for ($i = 60; $i -ge 0; $i--) {
            # Check if a new download started during countdown
            $checkSize = Get-FolderSize $downloadingPath
            if ($checkSize -gt 0) {
                Write-Host ""
                Write-Host ""
                Write-Host "  New download detected! Cancelling shutdown." -ForegroundColor Cyan
                Write-Host "  Resuming watch mode..." -ForegroundColor Cyan
                Start-Sleep -Seconds 2
                $state           = "watching"
                $emptyDetectedAt = $null
                $peakDLSize      = $checkSize
                $prevDLBytes     = 0
                $cachedAppId     = $null
                $script:lineCount = 0
                $cancelled       = $true
                break
            }
            Write-Host ("  Shutting down in: " + $i + " seconds...   ") -ForegroundColor Red -NoNewline
            Write-Host "`r" -NoNewline
            Start-Sleep -Seconds 1
        }

        if (-not $cancelled) {
            shutdown /s /t 0
            break
        }
        continue
    }

    # ── Draw display ──────────────────────────────────────────────────────
    Clear-Display $script:lineCount
    $script:lineCount = 0

    $modeLabel = if ($use2FA) { "2FA  (download + install check)" } else { "1FA  (download only)" }
    $modeColor = if ($use2FA) { "Cyan" } else { "DarkYellow" }
    $dlColor   = if ($check1) { "Green" } else { "DarkYellow" }
    $gameColor = if ($use2FA) { if ($check2) { "Green" } else { "DarkYellow" } } else { "DarkGray" }

    # State banner
    if ($state -eq "confirming") {
        $waited      = [math]::Round(((Get-Date) - $emptyDetectedAt).TotalSeconds)
        $waitLeft    = $confirmSeconds - $waited
        WL ("  !! Download folder empty - confirming for " + $waitLeft + "s before shutdown...") "Magenta"
        WL ("     Start a new Steam download to cancel automatically.") "DarkYellow"
        WL ""
    }

    WL ("  Active Game : " + $gameName)
    WL ("  App ID      : " + $(if ($appId) { $appId } else { "None active" }))
    if ($allIds.Count -gt 1) {
        WL ("  Also queued : " + (($allIds | Where-Object { $_ -ne $appId }) -join ", ")) "DarkGray"
    }
    WL ("  Mode        : " + $modeLabel) $modeColor
    WL ""
    WL "  -- Download Progress --" "Cyan"
    WL ("  DL Folder   : " + (Format-Bytes $dlSize) + " / " + $(if ($peakDLSize -gt 0) { Format-Bytes $peakDLSize } else { "Waiting..." }))
    WL ("  DL Progress : " + (Draw-Bar $dlPercent) + " " + $dlPercent + "%")
    WL ("  Speed       : " + ("{0:N2}" -f $speedMBs) + " MB/s")
    WL ("  ETA         : " + (Format-Time $etaSec))

    if ($gameFolderExists) {
        WL ""
        WL "  -- Install Progress --" "Cyan"
        WL ("  Game Folder : " + $gamePath)
        WL ("  Installed   : " + (Format-Bytes $gameSize) + " / " + $(if ($expectedSize -gt 0) { Format-Bytes $expectedSize } else { "Fetching..." }))
        if ($use2FA) {
            WL ("  IN Progress : " + (Draw-Bar $installPercent) + " " + $installPercent + "%")
            WL ("  Threshold   : 80% of expected = " + (Format-Bytes $threshold)) "DarkGray"
        }
    }

    WL ""
    WL "  -- Shutdown Checks --" "Cyan"
    WL ("  Check 1 - Downloading empty : " + $(if ($check1) { "[PASS]" } else { "[WAIT]" })) $dlColor
    WL ("  Check 2 - Game size reached : " + $(if ($use2FA) { if ($check2) { "[PASS]" } else { "[WAIT]" } } else { "[SKIP]" })) $gameColor
    WL ""
    WL ("  Elapsed     : " + (Format-Time $elapsed.TotalSeconds))
    WL ("  Last Update : " + (Get-Date -Format "HH:mm:ss"))
    WL "--------------------------------------------" "DarkGray"

    $prevDLBytes = $dlSize
}