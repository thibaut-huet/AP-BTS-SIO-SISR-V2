#Requires -Version 5.1
<#
.SYNOPSIS
    Joint un poste client Windows au domaine redone.local.

.DESCRIPTION
    Script idempotent autant que possible :
      - verifie la resolution DNS du domaine ;
      - verifie la joignabilite d'un DC ;
      - joint la machine si elle n'est pas deja membre du domaine ;
      - redemarre (optionnel).

    A deployer sur CLIENT01, CLIENT02 et CLIENT03 (ou via GPO / Intune).

.EXAMPLE
    .\join-domain-client.ps1 -DomainAdminPassword '********'
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'redone.local',

    [string]$DomainAdminUser = 'REDONE\Administrateur',

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminPassword,

    [string]$OUPath = '',

    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'join-domain-client.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir 'join-domain-client-transcript.log') -Append | Out-Null

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.PartOfDomain -and $computerSystem.Domain -eq $DomainName) {
        Write-Log "La machine est deja membre de $DomainName. Rien a faire."
        exit 0
    }

    Write-Log 'Verification du DNS (le DC doit etre le serveur DNS du client)...'
    $dnsResult = Resolve-DnsName -Name $DomainName -Type A -ErrorAction SilentlyContinue
    if (-not $dnsResult) {
        throw "Resolution DNS de $DomainName impossible. Configurer le client avec le DNS 10.2.41.10 (ou 10.2.41.11)."
    }
    Write-Log ($dnsResult | Format-Table -AutoSize | Out-String)

    Write-Log 'Verification de la joignabilite du DC...'
    $dcCheck = & nltest.exe "/dsgetdc:$DomainName" 2>&1
    Write-Log ($dcCheck | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Aucun DC joignable pour $DomainName."
    }

    $securePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $securePassword)

    $params = @{
        DomainName = $DomainName
        Credential = $credential
        Force      = $true
        Restart    = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($OUPath)) {
        $params.OUPath = $OUPath
    }

    Write-Log "Jonction de $env:COMPUTERNAME a $DomainName..."
    Add-Computer @params

    Write-Log 'Jonction reussie. Redemarrage necessaire.'
    if (-not $NoRestart) {
        shutdown.exe /r /t 10 /c 'Jonction au domaine redone.local'
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
