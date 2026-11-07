#Requires -Version 5.1
<#
.SYNOPSIS
    Installe Tailscale sur la VM Windows Server Azure et la raccorde au tailnet.

.DESCRIPTION
    Executee par l'extension Azure CustomScriptExtension (01-Tailscale).
    Tailscale (WireGuard) remplace le tunnel VPN IPsec site-a-site :
      - pas de passerelle VPN Azure facturee a l'heure ;
      - traversee de NAT automatique ;
      - le DC on-prem (SRV-AD) et le DC Azure se joignent via leurs IP 100.x.

.NOTES
    Le parametre -AuthKey est transmis dans protectedSettings : Azure chiffre
    la valeur et ne la journalise pas. En production, prevoir une cle
    ephemere / pre-autorisee et la faire tourner regulierement.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuthKey,

    [string]$Hostname = $env:COMPUTERNAME,

    [string]$OnPremDnsIp = '100.64.0.10',

    [string]$AzureDcTailscaleIp = '100.64.0.4',

    [switch]$AcceptRoutes
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir '01-tailscale.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

try {
    Start-Transcript -Path (Join-Path $logDir '01-tailscale-transcript.log') -Append | Out-Null

    Write-Log "Installation de Tailscale sur '$env:COMPUTERNAME' (hostname Tailscale : $Hostname)."

    $tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

    if (-not (Test-Path $tailscaleExe)) {
        $installer = Join-Path $env:TEMP 'tailscale-setup-latest.exe'
        $downloadUrl = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe'

        Write-Log "Telechargement de l'installateur : $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing

        Write-Log 'Installation silencieuse...'
        $process = Start-Process -FilePath $installer -ArgumentList '/quiet' -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "L'installateur Tailscale a retourne le code $($process.ExitCode)."
        }
    }
    else {
        Write-Log 'Tailscale est deja installe.'
    }

    if (-not (Test-Path $tailscaleExe)) {
        throw "tailscale.exe introuvable apres installation : $tailscaleExe"
    }

    # Connexion au tailnet. --unattended permet a la session SYSTEM du service
    # de rester connectee sans session utilisateur ouverte.
    $arguments = @(
        'up'
        "--authkey=$AuthKey"
        "--hostname=$Hostname"
        '--unattended'
        '--accept-dns=false'
    )
    if ($AcceptRoutes) {
        $arguments += '--accept-routes'
    }

    # Ne jamais journaliser la cle d'authentification en clair.
    $safeArguments = $arguments | ForEach-Object {
        if ($_ -like '--authkey=*') { '--authkey=***' } else { $_ }
    }
    Write-Log "Connexion au tailnet : tailscale $($safeArguments -join ' ')"
    & $tailscaleExe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up a echoue avec le code $LASTEXITCODE."
    }

    Start-Sleep -Seconds 5
    & $tailscaleExe status
    if ($LASTEXITCODE -ne 0) {
        throw 'tailscale status a echoue : la VM ne semble pas connectee au tailnet.'
    }

    $tailscaleIp = (& $tailscaleExe ip -4 | Select-Object -First 1)
    Write-Log "Adresse Tailscale IPv4 : $tailscaleIp"
    if ($tailscaleIp -ne $AzureDcTailscaleIp) {
        Write-Log "AVERTISSEMENT : IP Tailscale $tailscaleIp differente de l'IP statique attendue $AzureDcTailscaleIp. La fixer dans la console Tailscale."
    }

    # -----------------------------------------------------------------------
    # Resolution DNS de redone.local
    # La NIC Azure garde le DNS de la plateforme (168.63.129.16) pour Internet.
    # Une regle NRPT force les requetes *.redone.local vers le DC on-prem via
    # Tailscale : cela evite le probleme "poule et oeuf" au premier boot.
    # -----------------------------------------------------------------------
    $nrptNamespace = '.redone.local'
    Write-Log "Configuration NRPT : $nrptNamespace -> $OnPremDnsIp"
    try {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Namespace -contains $nrptNamespace } |
            Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue

        Add-DnsClientNrptRule `
            -Namespace $nrptNamespace `
            -NameServers $OnPremDnsIp `
            -DisplayName 'AP1 - redone.local via Tailscale' `
            -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "AVERTISSEMENT : configuration NRPT impossible ($($_.Exception.Message))."
    }

    # Priorite de l'interface Tailscale : la resolution Internet reste assuree
    # par la NIC Azure (168.63.129.16), la regle NRPT route uniquement le
    # domaine AD vers le DC on-prem.
    $tailscaleAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like '*Tailscale*' -or $_.Name -eq 'Tailscale' } |
        Select-Object -First 1
    if ($tailscaleAdapter) {
        Set-NetIPInterface -InterfaceIndex $tailscaleAdapter.ifIndex -InterfaceMetric 1 -ErrorAction SilentlyContinue
        try {
            Set-NetConnectionProfile -InterfaceIndex $tailscaleAdapter.ifIndex -NetworkCategory Private -ErrorAction Stop
            Write-Log 'Profil reseau Tailscale passe en Private (pare-feu Windows).'
        }
        catch {
            Write-Log "AVERTISSEMENT : profil reseau Tailscale inchange ($($_.Exception.Message))."
        }
        Write-Log "Interface Tailscale configuree (index $($tailscaleAdapter.ifIndex), priorite 1)."
    }
    else {
        Write-Log "AVERTISSEMENT : interface Tailscale non trouvee, la regle NRPT reste active."
    }

    Write-Log "Verification DNS : Resolve-DnsName redone.local"
    try {
        Resolve-DnsName -Name 'redone.local' -ErrorAction Stop | Out-String | Write-Log
    }
    catch {
        Write-Log "AVERTISSEMENT : resolution de redone.local impossible pour l'instant ($($_.Exception.Message)). Verifier que le DC on-prem annonce son IP Tailscale comme serveur DNS."
    }

    Write-Log 'Installation Tailscale terminee avec succes.'
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
