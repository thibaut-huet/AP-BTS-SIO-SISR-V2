#Requires -Version 5.1
<#
.SYNOPSIS
    Verifie (par defaut) ou realise (option) la retrogradation d'un controleur
    de domaine, a executer sur le DC Proxmox.

.DESCRIPTION
    Par defaut, ce script ne modifie RIEN : il controle l'etat du serveur, liste
    les roles FSMO qu'il detient encore et affiche la marche a suivre. C'est le
    mode "verification", sans risque.

    La retrogradation reelle (desinstallation d'AD DS, passage en serveur
    membre, redemarrage) n'a lieu qu'avec -ExecuteDemotion. Ce choix permet de
    rejouer la migration plusieurs fois (demonstration, soutenance) sans
    detruire l'infrastructure Proxmox de reference : l'ancien DC reste
    operationnel, il suffit de supprimer le DC Azure et de redeployer.

    Ce script refuse de demettre le serveur si des roles FSMO y sont encore
    actifs, sauf avec -Force.

    A ne PAS executer sur le DC Azure tant que la migration n'est pas validee.

.EXAMPLE
    # Mode verification (aucune modification) - recommande
    .\06-demote-onprem-dc.ps1

.EXAMPLE
    # Simulation detaillee de la retrogradation
    .\06-demote-onprem-dc.ps1 -ExecuteDemotion -WhatIf

.EXAMPLE
    # Retrogradation reelle : action irreversible
    .\06-demote-onprem-dc.ps1 -ExecuteDemotion
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [alias('Demote')]
    [switch]$ExecuteDemotion,

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

    # Idempotence : si NTDS n'existe pas, le serveur n'est pas (ou plus) un DC.
    $isDc = (Get-Service -Name NTDS -ErrorAction SilentlyContinue) -ne $null
    if (-not $isDc) {
        Write-Log "Ce serveur n'heberge pas AD DS (service NTDS absent) : rien a retrogarder."
        exit 0
    }

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

    Write-Log "Etat du serveur $me :"
    Write-Log "  Roles FSMO detenus localement : $(if ($localFsmo.Count -gt 0) { $localFsmo -join ', ' } else { 'aucun' })"
    Write-Log "  PDC Emulator : $($domain.PDCEmulator)"
    Write-Log "  RID Master   : $($domain.RIDMaster)"
    Write-Log "  Schema Master: $($forest.SchemaMaster)"

    # Mode par defaut : audit seul, aucune modification.
    if (-not $ExecuteDemotion) {
        Write-Log 'MODE VERIFICATION : aucune modification appliquee.'
        Write-Log 'Avant une retrogradation reelle, verifier sur le DC Azure :'
        Write-Log '  repadmin /replsummary   (0 echec)'
        Write-Log '  dcdiag /test:replications /test:dns'
        Write-Log '  \\redone.local\SYSVOL accessible'
        Write-Log 'Pour retrograder reellement : .\06-demote-onprem-dc.ps1 -ExecuteDemotion'
        Write-Log 'Rappel : la retrogradation est irreversible et empeche de rejouer la migration.'
        exit 0
    }

    if ($localFsmo.Count -gt 0) {
        $message = "Ce serveur detient encore les roles FSMO : $($localFsmo -join ', ')."
        if (-not $Force) {
            throw "$message Transfert les roles vers SRV-AD-AZ01 (script 05) avant de continuer, ou utilise -Force en connaissance de cause."
        }
        Write-Warning "$message -Force demande : poursuite de la retrogradation."
    }

    Write-Log "Retrogradation de $me. Le serveur deviendra un simple serveur membre."

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
