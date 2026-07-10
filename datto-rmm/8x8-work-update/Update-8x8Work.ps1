#Requires -Version 5.1
<#
.SYNOPSIS
    Datto RMM component: silently update 8x8 Work for Desktop (MSI) across endpoints.

.DESCRIPTION
    Attach the target 8x8 Work MSI to this component package.
    Datto RMM runs the script from the package directory, so the MSI is referenced as .\*.msi.

    Component variables (optional, set in Datto RMM):
      $env:TargetVersion  - Minimum version to consider up to date (example: 8.3.1)
      $env:ForceReinstall  - Set to "true" to run MSI even when version already matches

    Recommended Datto RMM settings:
      - Run as: LocalSystem
      - Timeout: 30+ minutes
      - Attach: work-64-msi-*.msi (or your current VOD_*.msi)

.NOTES
    MSI installs machine-wide under Program Files. Per-user EXE installs in AppData are not
    upgraded by this component; those endpoints need the EXE auto-update path or a user-context job.
#>

$ErrorActionPreference = 'Stop'

$DisplayNamePattern = '8x8 Work'
$InstallExePath     = Join-Path ${env:ProgramFiles} '8x8 Inc\8x8 Work\8x8 Work.exe'
$LogDir             = Join-Path $env:ProgramData 'DattoRMM\8x8Work'
$LogFile            = Join-Path $LogDir "8x8-update-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $line

    if (Test-Path $LogDir) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-DattoResult {
    param(
        [string]$Status,
        [int]$ExitCode
    )

    Write-Host '<-Start Result->'
    Write-Host "STATUS=$Status"
    Write-Host '<-End Result->'
    exit $ExitCode
}

function ConvertTo-8x8Version {
    param([string]$VersionString)

    if ([string]::IsNullOrWhiteSpace($VersionString)) {
        return $null
    }

    # Handles values like 8.3.1, 8.3.1-b5, and 8.3.1.10
    $digits = [regex]::Matches($VersionString, '\d+') | ForEach-Object { $_.Value }
    if (-not $digits -or $digits.Count -eq 0) {
        return $null
    }

    while ($digits.Count -lt 4) {
        $digits += '0'
    }

    try {
        return [version]::new(
            [int]$digits[0],
            [int]$digits[1],
            [int]$digits[2],
            [int]$digits[3]
        )
    }
    catch {
        return $null
    }
}

function Get-Installed8x8Version {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $registryPaths) {
        $matches = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayNamePattern*" }

        foreach ($entry in $matches) {
            $version = ConvertTo-8x8Version $entry.DisplayVersion
            if ($version) {
                return [pscustomobject]@{
                    Version     = $version
                    DisplayName = $entry.DisplayName
                    Source      = 'Registry'
                }
            }
        }
    }

    if (Test-Path -LiteralPath $InstallExePath) {
        $fileVersion = (Get-Item -LiteralPath $InstallExePath).VersionInfo.FileVersion
        $version = ConvertTo-8x8Version $fileVersion
        if ($version) {
            return [pscustomobject]@{
                Version     = $version
                DisplayName = $DisplayNamePattern
                Source      = 'File'
            }
        }
    }

    return $null
}

function Stop-8x8WorkProcesses {
    $processNames = @('8x8 Work', '8x8Work', 'VOD', '8x8')

    foreach ($name in $processNames) {
        $processes = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($process in $processes) {
            Write-Log "Stopping $($process.ProcessName) (PID $($process.Id))"
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 3
}

function Get-ComponentMsi {
    $packageDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

    $msi = Get-ChildItem -Path $packageDir -Filter '*.msi' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $msi) {
        throw "No MSI attached in component package directory: $packageDir"
    }

    return $msi
}

try {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Write-Log '8x8 Work update component started'

    $targetVersion = $null
    if ($env:TargetVersion) {
        $targetVersion = ConvertTo-8x8Version $env:TargetVersion
        if (-not $targetVersion) {
            throw "Invalid TargetVersion component variable: $($env:TargetVersion)"
        }
        Write-Log "Target version: $targetVersion"
    }

    $forceReinstall = ($env:ForceReinstall -eq 'true')
    $installed = Get-Installed8x8Version

    if ($installed) {
        Write-Log "Detected $($installed.DisplayName) $($installed.Version) via $($installed.Source)"
    }
    else {
        Write-Log 'No existing MSI-based 8x8 Work installation detected'
    }

    if (-not $forceReinstall -and $targetVersion -and $installed -and $installed.Version -ge $targetVersion) {
        Write-Log 'Endpoint already meets target version; skipping install'
        Write-DattoResult -Status "8x8 Work $($installed.Version) already installed (target $targetVersion)" -ExitCode 0
    }

    $msi = Get-ComponentMsi
    Write-Log "Using installer: $($msi.Name)"

    Stop-8x8WorkProcesses

    $msiLog = Join-Path $LogDir "msiexec-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $msiArgs = @(
        '/i', "`"$($msi.FullName)`"",
        '/qn',
        '/norestart',
        'REBOOT=ReallySuppress',
        'ALLOW_TELEMETRY=0',
        'ALLOW_FEEDBACK=0',
        '/L*v', "`"$msiLog`""
    )

    Write-Log "Running: msiexec.exe $($msiArgs -join ' ')"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    $exitCode = $process.ExitCode

    if ($exitCode -eq 3010) {
        Write-Log 'Install completed successfully; reboot required (3010)' 'WARN'
    }
    elseif ($exitCode -ne 0) {
        throw "msiexec failed with exit code $exitCode. Log: $msiLog"
    }
    else {
        Write-Log "msiexec completed with exit code $exitCode"
    }

    Start-Sleep -Seconds 5
    $updated = Get-Installed8x8Version

    if (-not $updated) {
        throw "Post-install verification failed: 8x8 Work not detected after install. Log: $msiLog"
    }

    if ($targetVersion -and $updated.Version -lt $targetVersion) {
        throw "Post-install verification failed: found $($updated.Version), expected >= $targetVersion. Log: $msiLog"
    }

    Write-Log "Update successful. Installed version: $($updated.Version)"
    Write-DattoResult -Status "8x8 Work updated to $($updated.Version)" -ExitCode 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-DattoResult -Status "ERROR: $($_.Exception.Message)" -ExitCode 1
}
