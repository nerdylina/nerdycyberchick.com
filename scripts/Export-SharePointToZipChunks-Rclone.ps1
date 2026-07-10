# Export-SharePointToZipChunks-Rclone.ps1
# PowerShell 5.1+ (PowerShell 7 recommended for large libraries)
# Requires rclone remote already configured for SharePoint.
# Example remote name below: ha-sp

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# =========================
# SETTINGS
# =========================

$RcloneExe = 'C:\Tools\rclone\rclone.exe'

$SourceRemote = 'ha-sp:'
$OutputRoot   = 'D:\SharePoint_ZIP_Export'
$TempRoot     = 'D:\SharePoint_ZIP_Export_Temp'

$MaxChunkGB = 20

$CompletedLog = Join-Path $OutputRoot 'completed-files.txt'
$ErrorLog     = Join-Path $OutputRoot 'errors.txt'

# =========================
# SETUP
# =========================

if (-not (Test-Path -LiteralPath $RcloneExe)) {
    throw "rclone.exe not found at $RcloneExe"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

if (-not ('System.IO.Compression.ZipFile' -as [type])) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

$MaxChunkBytes = [int64]$MaxChunkGB * 1GB

$completed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

if (Test-Path -LiteralPath $CompletedLog) {
    Get-Content -LiteralPath $CompletedLog | ForEach-Object {
        if ($_ -and $_.Trim().Length -gt 0) {
            [void]$completed.Add($_.Trim())
        }
    }
}

# =========================
# FUNCTIONS
# =========================

function Get-RcloneRemotePath {
    param(
        [string]$Remote,
        [string]$RelativePath
    )

    $remoteRoot = if ($Remote.EndsWith(':')) { $Remote } else { "$Remote:" }
    $relative = ($RelativePath -replace '\\', '/').TrimStart('/')

    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $remoteRoot
    }

    return $remoteRoot + $relative
}

function Get-SafeName {
    param([string]$Name)

    if (-not $Name -or $Name.Trim().Length -eq 0) {
        return '_blank_'
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()

    foreach ($char in $invalidChars) {
        $Name = $Name.Replace($char, '_')
    }

    return $Name
}

function Get-SafeZipPath {
    param([string]$Path)

    $parts = ($Path -replace '\\', '/') -split '/'

    $safeParts = foreach ($part in $parts) {
        Get-SafeName $part
    }

    return ($safeParts -join '/')
}

function Start-NewChunk {
    param([int]$Number)

    $chunkName = 'SharePoint_Export_Part_{0:D4}.zip' -f $Number
    $chunkPath = Join-Path $OutputRoot $chunkName

    Write-Host ''
    Write-Host "Starting ZIP chunk: $chunkName" -ForegroundColor Yellow

    if (Test-Path -LiteralPath $chunkPath) {
        Remove-Item -LiteralPath $chunkPath -Force
    }

    return $chunkPath
}

function Close-CurrentZip {
    param(
        [ref]$Zip,
        [ref]$ZipPath
    )

    if ($null -ne $Zip.Value) {
        $Zip.Value.Dispose()
        $Zip.Value = $null
    }

    $ZipPath.Value = $null
}

function Get-RcloneFileList {
    param(
        [string]$Remote
    )

    $listFile = Join-Path $TempRoot ("rclone-lsjson-{0}.json" -f ([Guid]::NewGuid().ToString()))

    try {
        & $RcloneExe lsjson $Remote --recursive --files-only --outfile $listFile

        if ($LASTEXITCODE -ne 0) {
            throw 'rclone lsjson failed.'
        }

        if (-not (Test-Path -LiteralPath $listFile)) {
            return @()
        }

        $raw = Get-Content -LiteralPath $listFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        return @($raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $listFile) {
            Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# =========================
# VERIFY RCLONE REMOTE
# =========================

Write-Host 'Checking rclone remote...' -ForegroundColor Cyan

& $RcloneExe lsd $SourceRemote | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Could not access rclone remote $SourceRemote"
}

# =========================
# GET FILE LIST
# =========================

Write-Host 'Reading SharePoint file list from rclone...' -ForegroundColor Cyan

$items = Get-RcloneFileList -Remote $SourceRemote

Write-Host "Files found: $($items.Count)" -ForegroundColor Green

if ($items.Count -eq 0) {
    Write-Host 'No files found. Nothing to export.' -ForegroundColor Yellow
    return
}

# =========================
# EXPORT
# =========================

$chunkNumber = 1
$currentChunkBytes = 0
$zipPath = $null
$zip = $null

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

        $size = 0
        if ($null -ne $item.Size) {
            $size = [int64]$item.Size
        }

        $needsNewChunk = (
            $null -eq $zip -or
            ($currentChunkBytes -gt 0 -and ($currentChunkBytes + $size) -gt $MaxChunkBytes)
        )

        if ($needsNewChunk) {
            Close-CurrentZip -Zip ([ref]$zip) -ZipPath ([ref]$zipPath)

            $zipPath = Start-NewChunk -Number $chunkNumber
            $chunkNumber++
            $currentChunkBytes = 0

            $zip = [System.IO.Compression.ZipFile]::Open(
                $zipPath,
                [System.IO.Compression.ZipArchiveMode]::Create
            )
        }

        $zipEntryPath = Get-SafeZipPath $remotePath
        $safeLeafName = Get-SafeName ([System.IO.Path]::GetFileName($remotePath))
        $tempFileName = ([Guid]::NewGuid().ToString()) + '_' + $safeLeafName
        $tempFilePath = Join-Path $TempRoot $tempFileName
        $sourcePath = Get-RcloneRemotePath -Remote $SourceRemote -RelativePath $remotePath

        try {
            Write-Host "Downloading: $remotePath" -ForegroundColor Cyan

            & $RcloneExe copyto $sourcePath $tempFilePath --retries 10 --low-level-retries 30 --stats-one-line

            if ($LASTEXITCODE -ne 0) {
                throw "rclone copyto failed for $remotePath"
            }

            if (-not (Test-Path -LiteralPath $tempFilePath)) {
                throw "Download completed but temp file is missing: $tempFilePath"
            }

            $actualSize = (Get-Item -LiteralPath $tempFilePath).Length
            if ($size -gt 0 -and $actualSize -ne $size) {
                Write-Host "WARN size mismatch for $remotePath (listed $size, downloaded $actualSize)" -ForegroundColor Yellow
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

            $currentChunkBytes += $(if ($actualSize -gt 0) { $actualSize } else { $size })
        }
        catch {
            $msg = "$(Get-Date -Format s) ERROR: $remotePath :: $($_.Exception.Message)"
            Add-Content -LiteralPath $ErrorLog -Value $msg
            Write-Host $msg -ForegroundColor Red
        }
        finally {
            if (Test-Path -LiteralPath $tempFilePath) {
                Remove-Item -LiteralPath $tempFilePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
finally {
    Close-CurrentZip -Zip ([ref]$zip) -ZipPath ([ref]$zipPath)

    if (Test-Path -LiteralPath $TempRoot) {
        Get-ChildItem -LiteralPath $TempRoot -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'DONE.' -ForegroundColor Green
Write-Host "ZIP files are in: $OutputRoot"
Write-Host "Completed log: $CompletedLog"
Write-Host "Error log: $ErrorLog"
