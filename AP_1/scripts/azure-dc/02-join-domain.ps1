#Requires -Version 5.1
<#
.SYNOPSIS
    Jonction manuelle / de secours de la VM Azure au domaine redone.local.

.DESCRIPTION
    Le deploiement standard utilise l'extension native Azure
    Microsoft.Compute/JsonADDomainExtension (02-JoinDomain).
    Ce script est fourni :
      - comme solution de secours si l'extension echoue ;
      - pour une execution manuelle via Azure Run Command / RDP ;
      - pour comprendre la commande effectuee.

.EXAMPLE
    .\02-join-domain.ps1 -DomainName redone.local `
        -DomainAdminUser 'REDONE\Administrateur' `
        -DomainAdminPassword '********'
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
$logFile = Join-Path $logDir '02-join-domain.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir '02-join-domain-transcript.log') -Append | Out-Null

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.PartOfDomain -and $computerSystem.Domain -eq $DomainName) {
        Write-Log "La machine est deja membre de $DomainName. Aucune jonction necessaire."
        exit 0
    }

    Write-Log "Verification de l'acces au domaine $DomainName..."
    $dc = & nltest.exe "/dsgetdc:$DomainName" 2>&1
    Write-Log ($dc | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Le DC du domaine $DomainName est injoignable. Verifier Tailscale/VPN et le DNS."
    }

    $securePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $securePassword)

    $addComputerParams = @{
        DomainName = $DomainName
        Credential = $credential
        Force      = $true
        Restart    = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($OUPath)) {
        $addComputerParams.OUPath = $OUPath
    }

    Write-Log "Jonction de $env:COMPUTERNAME au domaine $DomainName..."
    Add-Computer @addComputerParams

    Write-Log 'Jonction reussie.'
    if (-not $NoRestart) {
        Write-Log 'Redemarrage de la machine dans 10 secondes...'
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
