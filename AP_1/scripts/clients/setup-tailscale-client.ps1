#Requires -Version 5.1
<#
.SYNOPSIS
    Installe Tailscale sur un poste client Windows et le connecte au tailnet.

.DESCRIPTION
    Utile pour les postes clients distants qui doivent acceder aux partages
    TrueNAS ou administrer le DC Azure sans VPN site-a-site.

    Ce script est identique dans son principe a
    scripts/azure-dc/01-setup-tailscale.ps1, mais sans les options de routage.

.EXAMPLE
    .\setup-tailscale-client.ps1 -AuthKey 'tskey-auth-...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuthKey,

    [string]$Hostname = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'tailscale-client.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir 'tailscale-client-transcript.log') -Append | Out-Null

    $tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $tailscaleExe)) {
        $installer = Join-Path $env:TEMP 'tailscale-setup-latest.exe'
        Write-Log 'Telechargement et installation de Tailscale...'
        Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $installer -UseBasicParsing
        $process = Start-Process -FilePath $installer -ArgumentList '/quiet' -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installateur Tailscale : code $($process.ExitCode)."
        }
    }

    Write-Log "Connexion au tailnet sous le nom $Hostname..."
    & $tailscaleExe up "--authkey=$AuthKey" "--hostname=$Hostname" '--unattended' '--accept-dns=false'
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up a echoue (code $LASTEXITCODE)."
    }

    & $tailscaleExe status
    Write-Log 'Connexion Tailscale terminee.'
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
