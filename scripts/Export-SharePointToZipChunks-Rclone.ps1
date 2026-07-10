# Export-SharePointToZipChunks-Rclone.ps1
# PowerShell 7+
# Requires rclone remote already configured for SharePoint.
# Example remote name below: ha-sp

#Requires -Version 7.0

$ErrorActionPreference = "Stop"

# =========================
# SETTINGS
# =========================

$RcloneExe = "C:\Tools\rclone\rclone.exe"

$SourceRemote = "ha-sp:"
$OutputRoot   = "D:\SharePoint_ZIP_Export"
$TempRoot     = "D:\SharePoint_ZIP_Export_Temp"

$MaxChunkGB = 20

$CompletedLog = Join-Path $OutputRoot "completed-files.txt"
$ErrorLog     = Join-Path $OutputRoot "errors.txt"
$StateFile    = Join-Path $OutputRoot "export-state.json"

# =========================
# SETUP
# =========================

if (-not (Test-Path $RcloneExe)) {
    throw "rclone.exe not found at $RcloneExe"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

$MaxChunkBytes = [int64]($MaxChunkGB * 1GB)

$completed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

if (Test-Path $CompletedLog) {
    Get-Content -LiteralPath $CompletedLog | ForEach-Object {
        if ($_ -and $_.Trim().Length -gt 0) {
            [void]$completed.Add($_.Trim())
        }
    }
}

# =========================
# FUNCTIONS
# =========================

function Join-RclonePath {
    param(
        [string]$Remote,
        [string]$Path
    )

    $remoteName = $Remote.TrimEnd(':')
    $normalizedPath = $Path.Trim().TrimStart('/', '\').Replace('\', '/')

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return "${remoteName}:"
    }

    return "${remoteName}:$normalizedPath"
}

function Get-SafeName {
    param([string]$Name)

    if (-not $Name -or $Name.Trim().Length -eq 0) {
        return "_blank_"
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()

    foreach ($char in $invalidChars) {
        $Name = $Name.Replace($char, "_")
    }

    return $Name
}

function Get-SafeZipPath {
    param([string]$Path)

    $parts = $Path.Trim().TrimStart('/', '\').Replace('\', '/') -split "/"

    $safeParts = foreach ($part in $parts) {
        Get-SafeName $part
    }

    return ($safeParts -join "/")
}

function Save-ExportState {
    param(
        [int]$ChunkNumber,
        [int64]$CurrentChunkBytes,
        [string]$ZipPath
    )

    $state = [ordered]@{
        ChunkNumber       = $ChunkNumber
        CurrentChunkBytes = $CurrentChunkBytes
        ZipPath           = $ZipPath
        UpdatedAt         = (Get-Date).ToString("s")
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Clear-ExportState {
    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force
    }
}

function Get-NextChunkNumber {
    $existingParts = Get-ChildItem -LiteralPath $OutputRoot -Filter "SharePoint_Export_Part_*.zip" -File -ErrorAction SilentlyContinue

    if (-not $existingParts -or $existingParts.Count -eq 0) {
        return 1
    }

    $maxPart = 0

    foreach ($part in $existingParts) {
        if ($part.BaseName -match 'SharePoint_Export_Part_(\d+)$') {
            $number = [int]$Matches[1]
            if ($number -gt $maxPart) {
                $maxPart = $number
            }
        }
    }

    return $maxPart + 1
}

function Open-ZipChunk {
    param(
        [string]$ChunkPath,
        [switch]$CreateNew
    )

    if ($CreateNew) {
        if (Test-Path -LiteralPath $ChunkPath) {
            Remove-Item -LiteralPath $ChunkPath -Force
        }

        return [System.IO.Compression.ZipFile]::Open(
            $ChunkPath,
            [System.IO.Compression.ZipArchiveMode]::Create
        )
    }

    if (-not (Test-Path -LiteralPath $ChunkPath)) {
        throw "ZIP chunk not found: $ChunkPath"
    }

    return [System.IO.Compression.ZipFile]::Open(
        $ChunkPath,
        [System.IO.Compression.ZipArchiveMode]::Update
    )
}

function Start-NewChunk {
    param([int]$Number)

    $chunkName = "SharePoint_Export_Part_{0:D4}.zip" -f $Number
    $chunkPath = Join-Path $OutputRoot $chunkName

    Write-Host ""
    Write-Host "Starting ZIP chunk: $chunkName" -ForegroundColor Yellow

    return @{
        Path = $chunkPath
        Zip  = Open-ZipChunk -ChunkPath $chunkPath -CreateNew
    }
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & $RcloneExe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "exit code $exitCode"
        }

        throw $details
    }

    return $output
}

function Initialize-ChunkState {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $savedState = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json

            if ($savedState.ZipPath -and (Test-Path -LiteralPath $savedState.ZipPath)) {
                Write-Host "Resuming open ZIP chunk: $($savedState.ZipPath)" -ForegroundColor Yellow

                return @{
                    ChunkNumber       = [int]$savedState.ChunkNumber
                    CurrentChunkBytes = [int64]$savedState.CurrentChunkBytes
                    ZipPath           = [string]$savedState.ZipPath
                    Zip               = Open-ZipChunk -ChunkPath $savedState.ZipPath
                }
            }
        }
        catch {
            Write-Warning "Could not resume from state file. Starting a new chunk. $($_.Exception.Message)"
        }
    }

    $nextChunkNumber = Get-NextChunkNumber
    $chunk = Start-NewChunk -Number $nextChunkNumber

    return @{
        ChunkNumber       = $nextChunkNumber
        CurrentChunkBytes = [int64]0
        ZipPath           = $chunk.Path
        Zip               = $chunk.Zip
    }
}

# =========================
# VERIFY RCLONE REMOTE
# =========================

Write-Host "Checking rclone remote..." -ForegroundColor Cyan

Invoke-Rclone -Arguments @("lsd", $SourceRemote) | Out-Null

# =========================
# GET FILE LIST
# =========================

Write-Host "Reading SharePoint file list from rclone..." -ForegroundColor Cyan

$jsonLines = Invoke-Rclone -Arguments @(
    "lsjson",
    $SourceRemote,
    "--recursive",
    "--files-only",
    "--fast-list"
)

$jsonText = ($jsonLines | Out-String).Trim()

if ([string]::IsNullOrWhiteSpace($jsonText)) {
    $items = @()
}
else {
    $items = $jsonText | ConvertFrom-Json
}

$items = @($items)
Write-Host "Files found: $($items.Count)" -ForegroundColor Green

if ($items.Count -eq 0) {
    Write-Host "No files to export." -ForegroundColor Yellow
    return
}

# =========================
# EXPORT
# =========================

$chunkState = Initialize-ChunkState
$chunkNumber = $chunkState.ChunkNumber
$currentChunkBytes = $chunkState.CurrentChunkBytes
$zipPath = $chunkState.ZipPath
$zip = $chunkState.Zip

Save-ExportState -ChunkNumber $chunkNumber -CurrentChunkBytes $currentChunkBytes -ZipPath $zipPath

try {
    foreach ($item in $items) {
        $remotePath = [string]$item.Path

        if ([string]::IsNullOrWhiteSpace($remotePath)) {
            continue
        }

        if ($completed.Contains($remotePath)) {
            Write-Host "SKIP completed: $remotePath" -ForegroundColor DarkGray
            continue
        }

        $size = [int64]0
        if ($null -ne $item.Size) {
            $size = [int64]$item.Size
        }

        if ($size -gt $MaxChunkBytes) {
            $msg = "$(Get-Date -Format s) WARNING: $remotePath is larger than MaxChunkGB ($MaxChunkGB GB). It will be placed in its own ZIP chunk."
            Add-Content -LiteralPath $ErrorLog -Value $msg
            Write-Host $msg -ForegroundColor Yellow
        }

        if ($null -eq $zip -or ($currentChunkBytes -gt 0 -and ($currentChunkBytes + $size) -gt $MaxChunkBytes)) {
            if ($null -ne $zip) {
                $zip.Dispose()
                $zip = $null
            }

            $chunkNumber = Get-NextChunkNumber
            $chunk = Start-NewChunk -Number $chunkNumber
            $zipPath = $chunk.Path
            $zip = $chunk.Zip
            $currentChunkBytes = 0

            Save-ExportState -ChunkNumber $chunkNumber -CurrentChunkBytes $currentChunkBytes -ZipPath $zipPath
        }

        $zipEntryPath = Get-SafeZipPath $remotePath
        $safeLeafName = Get-SafeName ([System.IO.Path]::GetFileName($remotePath.Replace('/', '\')))
        $tempFileName = ([System.Guid]::NewGuid().ToString()) + "_" + $safeLeafName
        $tempFilePath = Join-Path $TempRoot $tempFileName
        $remoteSource = Join-RclonePath -Remote $SourceRemote -Path $remotePath

        try {
            Write-Host "Downloading: $remotePath" -ForegroundColor Cyan

            Invoke-Rclone -Arguments @(
                "copyto",
                $remoteSource,
                $tempFilePath,
                "--retries", "10",
                "--low-level-retries", "30"
            ) | Out-Null

            if (-not (Test-Path -LiteralPath $tempFilePath)) {
                throw "rclone copyto completed but temp file was not created: $tempFilePath"
            }

            $actualSize = (Get-Item -LiteralPath $tempFilePath).Length
            if ($actualSize -gt 0) {
                $size = $actualSize
            }

            Write-Host "Compressing: $zipEntryPath" -ForegroundColor Green

            $existingEntry = $zip.GetEntry($zipEntryPath)
            if ($null -ne $existingEntry) {
                $existingEntry.Delete()
            }

            $entry = $zip.CreateEntry(
                $zipEntryPath,
                [System.IO.Compression.CompressionLevel]::Optimal
            )

            $entryStream = $entry.Open()
            $fileStream = [System.IO.File]::OpenRead($tempFilePath)

            try {
                $fileStream.CopyTo($entryStream)
            }
            finally {
                $fileStream.Dispose()
                $entryStream.Dispose()
            }

            Add-Content -LiteralPath $CompletedLog -Value $remotePath
            [void]$completed.Add($remotePath)

            $currentChunkBytes += $size
            Save-ExportState -ChunkNumber $chunkNumber -CurrentChunkBytes $currentChunkBytes -ZipPath $zipPath
        }
        catch {
            $msg = "$(Get-Date -Format s) ERROR: $remotePath :: $($_.Exception.Message)"
            Add-Content -LiteralPath $ErrorLog -Value $msg
            Write-Host $msg -ForegroundColor Red
        }
        finally {
            if (Test-Path -LiteralPath $tempFilePath) {
                Remove-Item -LiteralPath $tempFilePath -Force
            }
        }
    }
}
finally {
    if ($null -ne $zip) {
        $zip.Dispose()
        $zip = $null
    }

    Clear-ExportState
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "DONE." -ForegroundColor Green
Write-Host "ZIP files are in: $OutputRoot"
Write-Host "Completed log: $CompletedLog"
Write-Host "Error log: $ErrorLog"
