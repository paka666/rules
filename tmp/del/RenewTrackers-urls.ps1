# 配置文件路径和下载链接
$ConfigFilePath = "aria2.conf"

$TrackersDownloadUrls = @(
    "http://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt",
    "https://cf.trackerslist.com/all.txt",
    "https://cf.trackerslist.com/best.txt",
    "https://cf.trackerslist.com/http.txt",
    "https://cf.trackerslist.com/nohttp.txt",
    "https://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt",
    "https://newtrackon.com/api/10",
    "https://newtrackon.com/api/all",
    "https://newtrackon.com/api/http",
    "https://newtrackon.com/api/live",
    "https://newtrackon.com/api/stable",
    "https://newtrackon.com/api/udp",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_http.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_https.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_ip.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_udp.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_ws.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_bad.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_best.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_best_ip.txt",
    "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt",
    "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_http.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_https.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_i2p.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_udp.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ws.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best_ip.txt",
    "https://torrends.to/torrent-tracker-list/?download=latest",
    "https://trackerslist.com/all.txt",
    "https://trackerslist.com/best.txt",
    "https://trackerslist.com/http.txt"
)

try {
    # 收集所有 trackers 的集合（使用 HashSet 去重）
    $AllTrackers = New-Object System.Collections.Generic.HashSet[string]

    # 第一步：从 aria2.conf 读取已有的 bt-tracker 配置作为本地源
    Write-Host "Reading existing trackers from $ConfigFilePath..."
    $ConfigContent = Get-Content -Path $ConfigFilePath -Encoding UTF8 -ErrorAction Stop
    $ExistingTrackerLine = $ConfigContent | Where-Object { $_ -match "^bt-tracker=" }
    if ($ExistingTrackerLine) {
        $ExistingTrackers = $ExistingTrackerLine -replace "^bt-tracker=", "" -split ","
        foreach ($tracker in $ExistingTrackers) {
            $tracker = $tracker.Trim()
            if ($tracker -ne "") {
                [void]$AllTrackers.Add($tracker)
            }
        }
        Write-Host "Added $($ExistingTrackers.Count) existing trackers from config."
    } else {
        Write-Host "No existing bt-tracker found in config."
    }

    # 第二步：从多个 URL 下载 trackers 并添加到集合
    $TempFiles = @()
    foreach ($url in $TrackersDownloadUrls) {
        $TrackersFileName = [System.IO.Path]::GetFileName($url)
        $TempTrackersFilePath = Join-Path -Path $env:TEMP -ChildPath $TrackersFileName
        $TempFiles += $TempTrackersFilePath

        Write-Host "Downloading trackers from $url..."
        Invoke-WebRequest -Uri $url -OutFile $TempTrackersFilePath -ErrorAction Stop

        Write-Host "Formatting trackers from $url..."
        $TrackersContent = Get-Content -Path $TempTrackersFilePath -Raw -ErrorAction Stop
        # 处理内容：替换空行，分割为 trackers 列表
        $TrackersList = $TrackersContent -split "\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        foreach ($tracker in $TrackersList) {
            [void]$AllTrackers.Add($tracker)
        }
        Write-Host "Added $($TrackersList.Count) trackers from $url (before dedup)."
    }

    # 第三步：将去重后的 trackers 拼接为字符串
    $FormattedTrackers = "bt-tracker=" + ($AllTrackers -join ",")

    # 第四步：更新或添加 bt-tracker 到 aria2.conf
    $TrackerLineNumber = ($ConfigContent | Select-String -SimpleMatch "bt-tracker=").LineNumber
    if ($TrackerLineNumber) {
        Write-Host "Updating existing bt-tracker line..."
        $ConfigContent[$TrackerLineNumber - 1] = $FormattedTrackers
    } else {
        Write-Host "Adding new bt-tracker line to $ConfigFilePath..."
        $ConfigContent += $FormattedTrackers
    }

    # 写入更新后的内容
    Set-Content -Path $ConfigFilePath -Value $ConfigContent -Encoding UTF8 -ErrorAction Stop
    Write-Host "Trackers merged, deduplicated, and updated successfully in $ConfigFilePath! Total unique trackers: $($AllTrackers.Count)"

} catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
} finally {
    # 清理所有临时文件
    foreach ($tempFile in $TempFiles) {
        if (Test-Path -Path $tempFile) {
            Remove-Item -Path $tempFile -Force
            Write-Host "Temporary file $tempFile cleaned up."
        }
    }
}

# 等待用户按键
#Write-Host "Press any key to exit..."
#Read-Host
