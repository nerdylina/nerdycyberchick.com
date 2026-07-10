#Requires -Version 5.1
<#
.SYNOPSIS
    Datto RMM monitor/detection script for 8x8 Work version compliance.

.DESCRIPTION
    Exit 0 = compliant (version meets or exceeds target)
    Exit 1 = non-compliant (missing, outdated, or check error)

    Component variable:
      $env:TargetVersion  - Required minimum version (example: 8.3.1)
#>

$ErrorActionPreference = 'Stop'

$DisplayNamePattern = '8x8 Work'
$InstallExePath     = Join-Path ${env:ProgramFiles} '8x8 Inc\8x8 Work\8x8 Work.exe'

function ConvertTo-8x8Version {
    param([string]$VersionString)

    if ([string]::IsNullOrWhiteSpace($VersionString)) {
        return $null
    }

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
                return $version
            }
        }
    }

    if (Test-Path -LiteralPath $InstallExePath) {
        return ConvertTo-8x8Version (Get-Item -LiteralPath $InstallExePath).VersionInfo.FileVersion
    }

    return $null
}

try {
    if (-not $env:TargetVersion) {
        throw 'TargetVersion component variable is required'
    }

    $targetVersion = ConvertTo-8x8Version $env:TargetVersion
    if (-not $targetVersion) {
        throw "Invalid TargetVersion: $($env:TargetVersion)"
    }

    $installedVersion = Get-Installed8x8Version

    if (-not $installedVersion) {
        Write-Host '<-Start Result->'
        Write-Host 'STATUS=8x8 Work is not installed (MSI)'
        Write-Host '<-End Result->'
        exit 1
    }

    if ($installedVersion -ge $targetVersion) {
        Write-Host '<-Start Result->'
        Write-Host "STATUS=8x8 Work $installedVersion is compliant (target $targetVersion)"
        Write-Host '<-End Result->'
        exit 0
    }

    Write-Host '<-Start Result->'
    Write-Host "STATUS=8x8 Work $installedVersion is below target $targetVersion"
    Write-Host '<-End Result->'
    exit 1
}
catch {
    Write-Host '<-Start Result->'
    Write-Host "STATUS=ERROR: $($_.Exception.Message)"
    Write-Host '<-End Result->'
    exit 1
}
