#Requires -Version 5.1
<#
.SYNOPSIS
    Mappe le partage SMB TrueNAS pour l'utilisateur courant.

.DESCRIPTION
    Solution de secours si la GPO de mappage de lecteur ne s'applique pas.
    A executer sur un poste client Windows joint au domaine redone.local.

.EXAMPLE
    .\map-smb-shares.ps1
    .\map-smb-shares.ps1 -SharePath '\\10.2.41.12\Partage' -DriveLetter Z
#>
[CmdletBinding()]
param(
    [string]$SharePath = '\\10.2.41.12\Partage',

    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'Z'
)

$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -Path $SharePath)) {
        throw "Le partage $SharePath est inaccessible. Verifier le reseau, le DNS et les ACL."
    }

    $existing = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Le lecteur $DriveLetter`: est deja mappe vers $($existing.DisplayRoot)."
        exit 0
    }

    New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $SharePath -Persist -Scope Global | Out-Null
    Write-Host "Lecteur $DriveLetter`: mappe vers $SharePath."
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
