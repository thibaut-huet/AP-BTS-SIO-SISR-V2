#Requires -Version 5.1
<#
.SYNOPSIS
    Valide la sante d'Active Directory et de la replication apres promotion.

.DESCRIPTION
    A executer sur le DC Azure apres le redemarrage de promotion.
    Produit un rapport texte dans C:\WindowsAzure\Logs\CustomScript
    et retourne un code non nul si une verification critique echoue.

.EXAMPLE
    .\04-validate-replication.ps1
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'redone.local',

    [string]$DcIp = '100.64.0.4'
)

$ErrorActionPreference = 'Continue'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$reportFile = Join-Path $logDir '04-replication-report.txt'
$failed = $false

function Add-Report {
    param([string]$Title, [string]$Content)
    $block = @(
        ''
        ('=' * 78)
        $Title
        ('=' * 78)
        $Content
    ) -join [Environment]::NewLine
    Write-Host $block
    Add-Content -Path $reportFile -Value $block
}

Set-Content -Path $reportFile -Value "Rapport de validation AD - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $env:COMPUTERNAME"

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    Add-Report 'Controleurs de domaine du domaine' ((Get-ADDomainController -Filter * |
        Select-Object Name, HostName, Site, IPv4Address, IsGlobalCatalog, OperationMasterRoles |
        Format-Table -AutoSize | Out-String))

    Add-Report 'Roles FSMO - domaine' ((Get-ADDomain |
        Select-Object PDCEmulator, RIDMaster, InfrastructureMaster |
        Format-List | Out-String))

    Add-Report 'Roles FSMO - foret' ((Get-ADForest |
        Select-Object SchemaMaster, DomainNamingMaster |
        Format-List | Out-String))

    Add-Report 'Services critiques' ((Get-Service NTDS, DNS, Netlogon, KDC, W32Time -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String))

    $ntds = Get-Service NTDS -ErrorAction SilentlyContinue
    if (-not $ntds -or $ntds.Status -ne 'Running') {
        $failed = $true
        Add-Report 'ERREUR' 'Le service NTDS ne fonctionne pas.'
    }

    $replSummary = & repadmin.exe /replsummary 2>&1 | Out-String
    Add-Report 'repadmin /replsummary' $replSummary
    if ($replSummary -match 'error|erreur|failed|echec' -and $replSummary -notmatch '0 error|0 erreur') {
        Write-Warning 'repadmin signale potentiellement des erreurs, verifier le rapport detaille.'
    }

    Add-Report 'repadmin /showrepl' ((& repadmin.exe /showrepl 2>&1 | Out-String))

    $dcdiagOutput = & dcdiag.exe /test:replications /test:advertising /test:dns /v 2>&1 | Out-String
    $dcdiagExit = $LASTEXITCODE
    Add-Report 'dcdiag - replication / advertising / DNS' $dcdiagOutput
    if ($dcdiagExit -ne 0) {
        $failed = $true
        Add-Report 'ERREUR' "dcdiag a retourne le code $dcdiagExit."
    }

    Add-Report 'Synchronisation horaire' ((& w32tm.exe /query /status 2>&1 | Out-String))

    # Bascule de la resolution DNS : le DC Azure devient sa propre reference.
    # Ne basculer que si son service DNS repond, pour ne pas casser la resolution.
    $dnsReachable = Test-NetConnection -ComputerName $DcIp -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $dnsReachable) {
        Add-Report 'NRPT - AVERTISSEMENT' "Le DNS ${DcIp}:53 ne repond pas : regle NRPT inchangee."
    }
    else {
        try {
            $nrptRules = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Namespace -contains '.redone.local' }
            if ($nrptRules) {
                foreach ($rule in $nrptRules) {
                    Set-DnsClientNrptRule -Name $rule.Name -NameServers $DcIp -ErrorAction Stop
                }
                Add-Report 'NRPT' "Regle .redone.local basculee vers $DcIp."
            }
            else {
                Add-DnsClientNrptRule -Namespace '.redone.local' -NameServers $DcIp -DisplayName 'AP1 - redone.local via Tailscale' -ErrorAction Stop | Out-Null
                Add-Report 'NRPT' "Regle .redone.local creee vers $DcIp."
            }
        }
        catch {
            Add-Report 'NRPT - AVERTISSEMENT' "Impossible de mettre a jour la regle NRPT : $($_.Exception.Message)"
        }
    }

    $domainResolution = Resolve-DnsName -Name $DomainName -ErrorAction SilentlyContinue
    Add-Report 'Resolution DNS du domaine' (($domainResolution | Format-Table -AutoSize | Out-String))
    if (-not $domainResolution) {
        $failed = $true
        Add-Report 'ERREUR' "La resolution de $DomainName a echoue apres la validation."
    }

    Add-Report 'Test de resolution du DC on-prem' ((Resolve-DnsName -Name 'srv-ad.redone.local' -ErrorAction SilentlyContinue |
        Format-Table -AutoSize | Out-String))

    if ($failed) {
        Write-Error "Validation terminee avec des erreurs. Rapport : $reportFile"
        exit 1
    }

    Write-Host "Validation terminee. Rapport : $reportFile"
    exit 0
}
catch {
    Write-Error "Echec de la validation : $($_.Exception.Message)"
    exit 1
}
