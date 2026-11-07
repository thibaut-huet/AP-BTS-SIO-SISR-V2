#Requires -Version 5.1
<#
.SYNOPSIS
    Retrograde proprement un controleur de domaine (a executer sur le DC
    Proxmox, apres transfert des roles FSMO vers le DC Azure).

.DESCRIPTION
    Ce script refuse de demettre le serveur si des roles FSMO y sont encore
    actifs, sauf avec -Force. Il desinstalle AD DS, DNS et demote le serveur
    en simple serveur membre, puis redemarre.

    A ne PAS executer sur le DC Azure tant que la migration n'est pas validee.

.EXAMPLE
    .\06-demote-onprem-dc.ps1 -WhatIf
    .\06-demote-onprem-dc.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir '06-demote-dc.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir '06-demote-dc-transcript.log') -Append | Out-Null
    Import-Module ActiveDirectory -ErrorAction Stop

    # Les proprietes FSMO de Get-ADDomain/Get-ADForest renvoient un FQDN :
    # comparer avec HostName (FQDN) et non avec Name (NetBIOS).
    $me = (Get-ADDomainController -Identity $env:COMPUTERNAME).HostName
    $domain = Get-ADDomain
    $forest = Get-ADForest

    $localFsmo = @()
    if ($domain.PDCEmulator -eq $me) { $localFsmo += 'PDCEmulator' }
    if ($domain.RIDMaster -eq $me) { $localFsmo += 'RIDMaster' }
    if ($domain.InfrastructureMaster -eq $me) { $localFsmo += 'InfrastructureMaster' }
    if ($forest.SchemaMaster -eq $me) { $localFsmo += 'SchemaMaster' }
    if ($forest.DomainNamingMaster -eq $me) { $localFsmo += 'DomainNamingMaster' }

    if ($localFsmo.Count -gt 0) {
        $message = "Ce serveur detient encore les roles FSMO : $($localFsmo -join ', ')."
        if (-not $Force) {
            throw "$message Transfert les roles vers SRV-AD-AZ01 (script 05) avant de continuer, ou utilise -Force en connaissance de cause."
        }
        Write-Warning "$message -Force demande : poursuite de la retrogradation."
    }

    Write-Log "Retrogradation de $me. Le serveur deviendra un simple serveur membre."
    Write-Log 'Verifier au prealable que le DC Azure est sain : repadmin /replsummary, dcdiag, SYSVOL partage.'

    if ($PSCmdlet.ShouldProcess($me, 'Desinstaller AD DS et retrograder le controleur de domaine')) {
        # -DemoteOperationMasterRole:$false : refuse de saisir les roles FSMO
        # de force pendant la retrogradation (protection contre une coupure).
        Uninstall-ADDSDomainController `
            -DemoteOperationMasterRole:$false `
            -Force:$true `
            -Confirm:$false

        Write-Log 'Retrogradation terminee. Redemarrage...'
        shutdown.exe /r /t 10 /c 'Retrogradation AD DS terminee'
    }

    exit 0
}
catch {
    Write-Log "ERREUR : $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
