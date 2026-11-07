#Requires -Version 5.1
<#
.SYNOPSIS
    Transfere les 5 roles FSMO vers le controleur de domaine Azure.

.DESCRIPTION
    A executer DEPUIS le DC Azure, apres validation de la replication
    (script 04) et avant la retrogradation du DC Proxmox (script 06).

    Le transfert est propre : les roles sont deplaces, pas saisis (seized).

.EXAMPLE
    .\05-transfer-fsmo.ps1
    .\05-transfer-fsmo.ps1 -TargetDC SRV-AD-AZ01
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
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
    Write-Log "Avant transfert - PDC : $($domain.PDCEmulator), RID : $($domain.RIDMaster), Infrastructure : $($domain.InfrastructureMaster)"
    Write-Log "Avant transfert - Schema : $($forest.SchemaMaster), DomainNaming : $($forest.DomainNamingMaster)"

    # Ne deplacer que les roles encore detenus par un autre DC (idempotence).
    $rolesToMove = @()
    if ($forest.SchemaMaster -ne $target.HostName) { $rolesToMove += 'SchemaMaster' }
    if ($forest.DomainNamingMaster -ne $target.HostName) { $rolesToMove += 'DomainNamingMaster' }
    if ($domain.PDCEmulator -ne $target.HostName) { $rolesToMove += 'PDCEmulator' }
    if ($domain.RIDMaster -ne $target.HostName) { $rolesToMove += 'RIDMaster' }
    if ($domain.InfrastructureMaster -ne $target.HostName) { $rolesToMove += 'InfrastructureMaster' }

    if ($rolesToMove.Count -eq 0) {
        Write-Log 'Tous les roles FSMO sont deja detenus par le DC cible.'
    }
    elseif ($PSCmdlet.ShouldProcess($target.Name, "Transferer les roles FSMO : $($rolesToMove -join ', ')")) {
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
