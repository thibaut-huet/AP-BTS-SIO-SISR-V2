#Requires -Version 5.1
<#
.SYNOPSIS
    Installe le role AD DS et promeut la VM Azure en controleur de domaine
    secondaire du domaine redone.local.

.DESCRIPTION
    Executee par l'extension Azure CustomScriptExtension (03-PromoteDC).
    La VM doit :
      - etre jointe au domaine (extension 02-JoinDomain) ;
      - resoudre redone.local via le DC on-prem (Tailscale ou VPN) ;
      - disposer d'un DNS fonctionnel.

    La promotion installe egalement le role DNS et replique la zone integree.
    Le redemarrage est declenche par Install-ADDSDomainController.

.NOTES
    L'extension Azure peut afficher un statut "failed" lorsque la VM redemarre
    pendant la promotion : c'est un comportement connu. Verifier ensuite
    Get-Service NTDS et repadmin /replsummary (script 04).
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'redone.local',

    [string]$DomainAdminUser = 'REDONE\Administrateur',

    [string]$DomainAdminPasswordB64 = '',

    [string]$SafeModePasswordB64 = '',

    [string]$DomainAdminPassword = '',

    [string]$SafeModePassword = '',

    [string]$ReplicationSourceDC = '',

    [string]$SiteName = ''
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir '03-promote-dc.log'

# Les secrets sont transmis en Base64 par protectedSettings (chiffre par Azure).
# Cela evite toute interpretation de caracteres speciaux par le shell.
if (-not [string]::IsNullOrWhiteSpace($DomainAdminPasswordB64)) {
    $DomainAdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($DomainAdminPasswordB64))
}
if (-not [string]::IsNullOrWhiteSpace($SafeModePasswordB64)) {
    $SafeModePassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($SafeModePasswordB64))
}
if ([string]::IsNullOrWhiteSpace($DomainAdminPassword)) {
    throw 'Mot de passe du compte de domaine manquant (-DomainAdminPassword ou -DomainAdminPasswordB64).'
}
if ([string]::IsNullOrWhiteSpace($SafeModePassword)) {
    throw 'Mot de passe DSRM manquant (-SafeModePassword ou -SafeModePasswordB64).'
}

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir '03-promote-dc-transcript.log') -Append | Out-Null

    Write-Log "Verification de la jonction au domaine $DomainName..."
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.Domain -ne $DomainName) {
        throw "La machine n'est pas jointe a $DomainName (domaine actuel : $($computerSystem.Domain))."
    }

    # Idempotence : DomainRole 4/5 = controleur de domaine (backup/primary).
    if ($computerSystem.DomainRole -ge 4) {
        Write-Log 'La machine est deja controleur de domaine : aucune promotion necessaire.'
        exit 0
    }

    Write-Log 'Verification de la joignabilite du DC source...'
    $dcCheck = & nltest.exe "/dsgetdc:$DomainName" 2>&1
    Write-Log ($dcCheck | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Aucun DC joignable pour $DomainName. Verifier Tailscale/VPN, le DNS et le pare-feu."
    }

    Write-Log "Installation du role AD-Domain-Services..."
    $feature = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
    if (-not $feature.Success) {
        throw "Echec de l'installation du role AD DS (code $($feature.ExitCode))."
    }

    Import-Module ADDSDeployment -ErrorAction Stop

    $secureDomainPassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    $domainCredential = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $secureDomainPassword)
    $secureDsrmPassword = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force

    $promotionParams = @{
        DomainName                    = $DomainName
        Credential                    = $domainCredential
        SafeModeAdministratorPassword = $secureDsrmPassword
        InstallDns                    = $true
        NoGlobalCatalog               = $false
        CreateDnsDelegation           = $false
        Force                         = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ReplicationSourceDC)) {
        $promotionParams.ReplicationSourceDC = $ReplicationSourceDC
        Write-Log "DC source de replication initial : $ReplicationSourceDC"
    }

    if (-not [string]::IsNullOrWhiteSpace($SiteName)) {
        $promotionParams.SiteName = $SiteName
        Write-Log "Site AD cible : $SiteName"
    }

    Write-Log 'Lancement de la promotion en controleur de domaine secondaire...'
    Install-ADDSDomainController @promotionParams

    Write-Log 'Promotion terminee. La machine va redemarrer.'
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
