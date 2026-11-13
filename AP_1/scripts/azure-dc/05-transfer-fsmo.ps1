#Requires -Version 5.1
<#
.SYNOPSIS
    Verifie (par defaut) ou realise (option) le transfert des 5 roles FSMO vers
    le controleur de domaine Azure.

.DESCRIPTION
    Par defaut, ce script ne deplace RIEN : il affiche qui detient les roles
    FSMO et lesquels seraient transferes. C'est le mode "verification".

    Le transfert reel n'a lieu qu'avec -ExecuteTransfer. Ce choix permet de
    rejouer la migration en boucle (demonstration, soutenance) sans modifier
    l'annuaire de reference : les FSMO restent sur le DC Proxmox, on supprime le
    DC Azure et on redeploie.

    Le transfert est propre : les roles sont deplaces, pas saisis (seized).
    Le script est idempotent : il ne deplace que les roles qui ne sont pas deja
    sur le DC cible.

    A executer DEPUIS le DC Azure, apres validation de la replication
    (script 04).

.EXAMPLE
    # Mode verification (aucune modification) - recommande
    .\05-transfer-fsmo.ps1

.EXAMPLE
    # Simulation detaillee du transfert
    .\05-transfer-fsmo.ps1 -ExecuteTransfer -WhatIf

.EXAMPLE
    # Transfert reel vers le DC courant
    .\05-transfer-fsmo.ps1 -ExecuteTransfer

.EXAMPLE
    # Transfert reel vers un DC explicite
    .\05-transfer-fsmo.ps1 -ExecuteTransfer -TargetDC SRV-AD-AZ01
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [alias('Transfer')]
    [switch]$ExecuteTransfer,

    [string]$TargetDC = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir '05-transfer-fsmo.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir '05-transfer-fsmo-transcript.log') -Append | Out-Null
    Import-Module ActiveDirectory -ErrorAction Stop

    $target = Get-ADDomainController -Identity $TargetDC -ErrorAction Stop
    Write-Log "Cible du transfert : $($target.Name) ($($target.HostName))"

    $domain = Get-ADDomain
    $forest = Get-ADForest
    Write-Log "Etat actuel - PDC : $($domain.PDCEmulator), RID : $($domain.RIDMaster), Infrastructure : $($domain.InfrastructureMaster)"
    Write-Log "Etat actuel - Schema : $($forest.SchemaMaster), DomainNaming : $($forest.DomainNamingMaster)"

    # Ne deplacer que les roles encore detenus par un autre DC (idempotence).
    $rolesToMove = @()
    if ($forest.SchemaMaster -ne $target.HostName) { $rolesToMove += 'SchemaMaster' }
    if ($forest.DomainNamingMaster -ne $target.HostName) { $rolesToMove += 'DomainNamingMaster' }
    if ($domain.PDCEmulator -ne $target.HostName) { $rolesToMove += 'PDCEmulator' }
    if ($domain.RIDMaster -ne $target.HostName) { $rolesToMove += 'RIDMaster' }
    if ($domain.InfrastructureMaster -ne $target.HostName) { $rolesToMove += 'InfrastructureMaster' }

    if ($rolesToMove.Count -eq 0) {
        Write-Log 'Tous les roles FSMO sont deja detenus par le DC cible.'
        exit 0
    }

    # Mode par defaut : audit seul, aucune modification.
    if (-not $ExecuteTransfer) {
        Write-Log "MODE VERIFICATION : aucune modification appliquee."
        Write-Log "Roles qui seraient transferes vers $($target.Name) : $($rolesToMove -join ', ')"
        Write-Log 'Avant un transfert reel, verifier la replication : repadmin /replsummary (0 echec).'
        Write-Log 'Pour transferer reellement : .\05-transfer-fsmo.ps1 -ExecuteTransfer'
        Write-Log 'Rappel : pour une demonstration rejouable, laisser les FSMO sur le DC Proxmox.'
        exit 0
    }

    if ($PSCmdlet.ShouldProcess($target.Name, "Transferer les roles FSMO : $($rolesToMove -join ', ')")) {
        Move-ADDirectoryServerOperationMasterRole `
            -Identity $target.Name `
            -OperationMasterRole $rolesToMove `
            -Confirm:$false

        Write-Log 'Transfert effectue.'
    }

    $domain = Get-ADDomain
    $forest = Get-ADForest
    Write-Log "Apres transfert - PDC : $($domain.PDCEmulator), RID : $($domain.RIDMaster), Infrastructure : $($domain.InfrastructureMaster)"
    Write-Log "Apres transfert - Schema : $($forest.SchemaMaster), DomainNaming : $($forest.DomainNamingMaster)"

    Write-Log 'Verifier que les 5 roles pointent bien vers le DC Azure.'
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
