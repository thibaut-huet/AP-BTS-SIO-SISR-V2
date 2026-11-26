#Requires -Version 5.1
<#
.SYNOPSIS
    Nettoie les metadonnees AD et les enregistrements DNS laisses par un DC
    Azure decommissionne (par defaut : SRV-AD-AZ01).

.DESCRIPTION
    A executer sur un DC Proxmox restant (SRV-AD), APRES que la VM Azure a ete
    supprimee ou retrogradee. Le script traite le "cas B" du runbook : la VM
    avait ete promue controleur de domaine, mais son objet DC et ses
    enregistrements DNS subsistent dans l'annuaire.

    Par defaut, ce script ne modifie RIEN : il inspecte l'annuaire, liste les
    objets et enregistrements DNS qui seraient supprimes, puis s'arrete. C'est
    le mode "verification", sans risque.

    Le nettoyage reel n'a lieu qu'avec -ExecuteCleanup.

    Le script refuse de continuer si :
      - la machine est encore un DC actif (il faut d'abord la retrograder) ;
      - elle detient encore des roles FSMO (les transferer ou les saisir
        d'abord), sauf avec -Force.

    Ce qu'il fait avec -ExecuteCleanup, dans cet ordre :
      1. supprime l'objet NTDS Settings (c'est lui qui declenche le nettoyage
         des liens de replication et des references croisees) ;
      2. supprime l'objet serveur du site dans CN=Sites,CN=Configuration ;
      3. supprime l'objet ordinateur restant et ses enfants eventuels ;
      4. supprime les enregistrements DNS (A, SRV, CNAME, NS, PTR...) qui
         pointent vers ce nom, y compris le CNAME nomme par le GUID du
         NTDS Settings ;
      5. affiche l'etat final (liste des DC + repadmin /replsummary).

    La suppression directe de l'objet ordinateur avec Remove-ADObject -Recursive
    ne suffit pas toujours : l'ordre ci-dessus reproduit ce que fait la console
    ADUC et garantit le nettoyage des metadonnees DC.

.EXAMPLE
    # Mode verification (aucune modification) - recommande
    .\07-cleanup-azure-dc.ps1

.EXAMPLE
    # Simulation detaillee du nettoyage
    .\07-cleanup-azure-dc.ps1 -ExecuteCleanup -WhatIf

.EXAMPLE
    # Nettoyage reel
    .\07-cleanup-azure-dc.ps1 -ExecuteCleanup

.EXAMPLE
    # Cas d'un nom suffixe par Tailscale lors d'une relance
    .\07-cleanup-azure-dc.ps1 -ComputerName 'SRV-AD-AZ01-1' -ExecuteCleanup
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ComputerName = 'SRV-AD-AZ01',

    [alias('Cleanup')]
    [switch]$ExecuteCleanup,

    # Contourne les controles FSMO. Ne pas utiliser sans comprendre l'impact.
    [switch]$Force,

    # Zones DNS a nettoyer. Par defaut : domaine + _msdcs.<domaine>.
    [string[]]$DnsZones
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\WindowsAzure\Logs\CustomScript'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir '07-cleanup-azure-dc.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

# Un enregistrement DNS appartient-il au DC a supprimer ?
function Test-RecordForComputer {
    param(
        [object]$Record,
        [string]$Name
    )

    $pattern = [regex]::Escape($Name)
    $values = @(
        $Record.HostName
        $Record.RecordData.NameServer
        $Record.RecordData.DomainName
        $Record.RecordData.HostNameAlias
        $Record.RecordData.Exchange
        $Record.RecordData.PtrDomainName
    )

    foreach ($value in $values) {
        if ($value -and ($value -match $pattern)) { return $true }
    }
    return $false
}

function Clear-AccidentalDeletionProtection {
    param([string]$DistinguishedName)

    try {
        Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
    }
    catch {
        Write-Log "Impossible de retirer la protection de $DistinguishedName : $($_.Exception.Message)"
    }
}

# Un objet DC encore liste dans AD est-il joignable (LDAP 389) ?
# Indispensable : un DC supprime reste dans Get-ADDomainController tant que
# ses metadonnees n'ont pas ete nettoyees.
function Test-DcReachable {
    param([string]$HostName)

    try {
        $ldap = Test-NetConnection -ComputerName $HostName -Port 389 `
            -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        if ($ldap) { return $true }
    }
    catch { }

    try {
        return [bool](Test-Connection -ComputerName $HostName -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

try {
    Start-Transcript -Path (Join-Path $logDir '07-cleanup-azure-dc-transcript.log') -Append | Out-Null

    Import-Module ActiveDirectory -ErrorAction Stop

    $domain = Get-ADDomain
    $forest = Get-ADForest
    if (-not $DnsZones -or $DnsZones.Count -eq 0) {
        $DnsZones = @($domain.DNSRoot, "_msdcs.$($domain.DNSRoot)")
    }

    Write-Log "Nettoyage du DC Azure decommissionne : $ComputerName"
    Write-Log "Domaine : $($domain.DNSRoot) / zones DNS : $($DnsZones -join ', ')"

    # --- 1. Etat de l'objet dans AD -------------------------------------
    $computer = Get-ADComputer -Filter "Name -eq '$ComputerName'" `
        -Properties DNSHostName, LastLogonDate, Enabled `
        -ErrorAction SilentlyContinue

    if (-not $computer) {
        Write-Log "Aucun objet ordinateur '$ComputerName' dans AD : le nettoyage AD est peut-etre deja fait."
    }
    else {
        Write-Log "Objet trouve : $($computer.DistinguishedName)"
        Write-Log "  Derniere connexion : $($computer.LastLogonDate)"
    }

    # --- 2. Securite : DC encore actif ou detenteur de FSMO -------------
    $activeDc = Get-ADDomainController -Filter * |
        Where-Object { $_.Name -eq $ComputerName -or $_.HostName -like "$ComputerName.*" }

    if ($activeDc) {
        foreach ($dc in @($activeDc)) {
            if (Test-DcReachable -HostName $dc.HostName) {
                throw "La machine '$ComputerName' est encore joignable sur le reseau ($($dc.HostName), port LDAP 389). Elle est donc encore en service : retrogradez-la d'abord (Uninstall-ADDSDomainController depuis la VM). Le nettoyage des metadonnees ne doit jamais viser un DC actif."
            }
        }
        Write-Log "Objet DC encore present dans AD mais machine injoignable : consideree hors service, nettoyage autorise."
    }

    if ($computer) {
        $dcHost = $computer.DNSHostName
        $fsmo = @()
        if ($domain.PDCEmulator -eq $dcHost) { $fsmo += 'PDCEmulator' }
        if ($domain.RIDMaster -eq $dcHost) { $fsmo += 'RIDMaster' }
        if ($domain.InfrastructureMaster -eq $dcHost) { $fsmo += 'InfrastructureMaster' }
        if ($forest.SchemaMaster -eq $dcHost) { $fsmo += 'SchemaMaster' }
        if ($forest.DomainNamingMaster -eq $dcHost) { $fsmo += 'DomainNamingMaster' }

        if ($fsmo.Count -gt 0) {
            $message = "'$ComputerName' detient encore les roles FSMO : $($fsmo -join ', ')."
            if (-not $Force) {
                throw "$message Ramenez-les sur SRV-AD (script 05) ou saisissez-les (Move-ADDirectoryServerOperationMasterRole) avant tout nettoyage."
            }
            Write-Warning "$message -Force demande : poursuite du nettoyage."
        }
    }

    # --- 3. Objets de metadonnees a supprimer ---------------------------
    $ntdsSettings = $null
    $serverObject = $null
    $computerChildren = @()
    $ntdsGuid = $null

    if ($computer) {
        $ntdsSettings = Get-ADObject -SearchBase $computer.DistinguishedName `
            -Filter "objectClass -eq 'nTDSDSA'" -SearchScope OneLevel `
            -Properties objectGUID -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($ntdsSettings) {
            $ntdsGuid = $ntdsSettings.ObjectGUID.Guid
            Write-Log "NTDS Settings : $($ntdsSettings.DistinguishedName)"
            Write-Log "  GUID (utilise pour le CNAME DNS) : $ntdsGuid"
        }
        else {
            Write-Log 'Aucun objet NTDS Settings : la machine n''est pas (ou plus) un DC.'
        }

        $sitesDn = "CN=Sites,CN=Configuration,$($forest.RootDomain)"
        $serverObject = Get-ADObject -Filter "Name -eq '$ComputerName'" `
            -SearchBase $sitesDn -SearchScope Subtree `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.ObjectClass -contains 'server' } |
            Select-Object -First 1

        if ($serverObject) {
            Write-Log "Objet serveur du site : $($serverObject.DistinguishedName)"
        }

        $computerChildren = Get-ADObject -SearchBase $computer.DistinguishedName `
            -Filter * -SearchScope OneLevel -ErrorAction SilentlyContinue
    }

    # --- 4. Enregistrements DNS candidats -------------------------------
    $zonesToScan = @($DnsZones)
    try {
        $reverseZones = Get-DnsServerZone |
            Where-Object { $_.IsReverseLookupZone } |
            Select-Object -ExpandProperty ZoneName
        $zonesToScan = @($zonesToScan + $reverseZones | Select-Object -Unique)
    }
    catch {
        Write-Log "Impossible de lister les zones DNS inverses : $($_.Exception.Message)"
    }

    $dnsTargets = @()
    foreach ($zone in $zonesToScan) {
        try {
            $records = Get-DnsServerResourceRecord -ZoneName $zone -ErrorAction Stop
        }
        catch {
            Write-Log "Zone DNS '$zone' introuvable ou illisible : ignoree."
            continue
        }

        $zoneMatches = $records | Where-Object {
            (Test-RecordForComputer -Record $_ -Name $ComputerName) -or
            ($ntdsGuid -and $_.HostName -eq $ntdsGuid)
        }

        if ($zoneMatches) {
            Write-Log "Enregistrements DNS a supprimer dans '$zone' :"
            foreach ($record in $zoneMatches) {
                Write-Log ("  - {0} [{1}]" -f $record.HostName, $record.RecordType)
                $dnsTargets += [pscustomobject]@{
                    Zone   = $zone
                    Record = $record
                }
            }
        }
    }
    if ($dnsTargets.Count -eq 0) {
        Write-Log 'Aucun enregistrement DNS residuel trouve.'
    }

    # --- 5. Mode verification ------------------------------------------
    if (-not $ExecuteCleanup) {
        Write-Log 'MODE VERIFICATION : aucune modification appliquee.'
        Write-Log "Pour nettoyer reellement : .\07-cleanup-azure-dc.ps1 -ComputerName '$ComputerName' -ExecuteCleanup"
        exit 0
    }

    # --- 6. Suppression des metadonnees DC, dans le bon ordre -----------
    # 6a. NTDS Settings : c'est cette suppression qui declenche le nettoyage
    #     des liens de replication et des references croisees.
    if ($ntdsSettings) {
        if ($PSCmdlet.ShouldProcess($ntdsSettings.DistinguishedName, 'Supprimer NTDS Settings et ses connexions de replication')) {
            $ntdsChildren = Get-ADObject -SearchBase $ntdsSettings.DistinguishedName `
                -Filter * -SearchScope Subtree -ErrorAction SilentlyContinue
            foreach ($dn in @($ntdsSettings.DistinguishedName) + @($ntdsChildren.DistinguishedName)) {
                if ($dn) { Clear-AccidentalDeletionProtection -DistinguishedName $dn }
            }
            Remove-ADObject -Identity $ntdsSettings.DistinguishedName -Recursive -Confirm:$false
            Write-Log "NTDS Settings supprime : $($ntdsSettings.DistinguishedName)"
        }
    }

    # 6b. Objet serveur du site (peut rester apres le 6a).
    if ($serverObject) {
        $stillThere = Get-ADObject -Identity $serverObject.DistinguishedName -ErrorAction SilentlyContinue
        if ($stillThere) {
            if ($PSCmdlet.ShouldProcess($serverObject.DistinguishedName, 'Supprimer l''objet serveur du site AD')) {
                Clear-AccidentalDeletionProtection -DistinguishedName $serverObject.DistinguishedName
                Remove-ADObject -Identity $serverObject.DistinguishedName -Recursive -Confirm:$false
                Write-Log "Objet serveur supprime : $($serverObject.DistinguishedName)"
            }
        }
    }

    # 6c. Objet ordinateur et enfants restants (serviceConnectionPoint...).
    if ($computer) {
        $stillThere = Get-ADObject -Identity $computer.DistinguishedName -ErrorAction SilentlyContinue
        if ($stillThere) {
            if ($PSCmdlet.ShouldProcess($computer.DistinguishedName, 'Supprimer l''objet ordinateur et ses enfants')) {
                $objectsToUnprotect = @($computer.DistinguishedName)
                if ($computerChildren) { $objectsToUnprotect += $computerChildren.DistinguishedName }
                foreach ($dn in $objectsToUnprotect) {
                    Clear-AccidentalDeletionProtection -DistinguishedName $dn
                }

                Remove-ADObject -Identity $computer.DistinguishedName -Recursive -Confirm:$false
                Write-Log "Objet ordinateur supprime : $($computer.DistinguishedName)"
            }
        }
        else {
            Write-Log 'Objet ordinateur deja supprime par le nettoyage des metadonnees.'
        }
    }

    # --- 7. Suppression des enregistrements DNS -------------------------
    foreach ($target in $dnsTargets) {
        if ($PSCmdlet.ShouldProcess("$($target.Zone)/$($target.Record.HostName)", 'Supprimer l''enregistrement DNS')) {
            try {
                Remove-DnsServerResourceRecord -ZoneName $target.Zone `
                    -InputObject $target.Record -Force -Confirm:$false
                Write-Log "DNS supprime : $($target.Zone)/$($target.Record.HostName) [$($target.Record.RecordType)]"
            }
            catch {
                Write-Log "Echec de suppression DNS $($target.Zone)/$($target.Record.HostName) : $($_.Exception.Message)"
            }
        }
    }

    # --- 8. Verification finale ----------------------------------------
    Write-Log 'Etat final des controleurs de domaine :'
    $dcTable = Get-ADDomainController -Filter * |
        Sort-Object Name |
        Format-Table Name, Site, IPv4Address |
        Out-String
    Write-Log $dcTable.TrimEnd()

    Write-Log 'Resume de replication (repadmin /replsummary) :'
    & repadmin.exe /replsummary 2>&1 | ForEach-Object { Write-Log ([string]$_) }

    Write-Log 'Nettoyage termine. Verifier aussi le device Tailscale et le resource group Azure.'
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
