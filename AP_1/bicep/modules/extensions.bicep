// ============================================================================
//  Module : Extensions de configuration de la VM
//  Chaine d automatisation (ordre garanti par dependsOn) :
//    01-Tailscale  -> rattache la VM au tailnet (acces DC on-prem)
//    02-JoinDomain -> Jonction au domaine redone.local (extension native)
//    03-PromoteDC  -> Installation AD DS + promotion en DC secondaire
//
//  Les scripts sont telecharges depuis le depot GitHub (URL brute) ou un
//  compte de stockage. Les secrets sont transmis en protectedSettings :
//  Azure les chiffre et ne les journalise pas.
// ============================================================================

@description('Nom de la VM cible.')
param vmName string

@description('Identifiant de ressource de la VM (force la dependance de deploiement).')
param vmId string

@description('Region Azure.')
param location string

@description('URL de base des scripts (ex: https://raw.githubusercontent.com/org/repo/main).')
param repositoryRawBaseUrl string

@description('Chemin des scripts dans le depot (ex: AP_1/scripts).')
param scriptsBasePath string = 'AP_1/scripts'

@description('Installe et connecte Tailscale sur la VM.')
param deployTailscale bool = true

@description('Cle d authentification Tailscale.')
@secure()
param tailscaleAuthKey string = ''

@description('IP Tailscale du DC on-prem, utilisee pour la resolution DNS AD.')
param onPremDnsIp string = '100.64.0.10'

@description('IP Tailscale du DC Azure (apres promotion).')
param azureDcTailscaleIp string = '100.64.0.4'

@description('Joint la VM au domaine existant.')
param joinDomain bool = true

@description('Nom FQDN du domaine.')
param domainName string = 'redone.local'

@description('Compte de domaine utilise pour la jonction.')
param domainJoinUser string = 'REDONE\\Administrateur'

@description('Mot de passe du compte de domaine.')
@secure()
param domainJoinPassword string

@description('OU cible de la jonction (vide = conteneur par defaut).')
param domainOuPath string = ''

@description('Promeut la VM en controleur de domaine secondaire.')
param promoteDc bool = true

@description('Mot de passe DSRM.')
@secure()
param safeModePassword string

@description('DC source prefere pour la replication initiale (vide = automatique).')
param replicationSourceDC string = ''

// Reference a la VM deja creee par le module vm-adds.
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: last(split(vmId, '/'))
}

// ---------------------------------------------------------------------------
// 01 - Tailscale (WireGuard mesh VPN)
// ---------------------------------------------------------------------------
resource tailscaleExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (deployTailscale) {
  parent: vm
  name: '01-Tailscale'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        '${repositoryRawBaseUrl}/${scriptsBasePath}/azure-dc/01-setup-tailscale.ps1'
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File 01-setup-tailscale.ps1 -AuthKey "${tailscaleAuthKey}" -Hostname "${vmName}" -OnPremDnsIp "${onPremDnsIp}" -AzureDcTailscaleIp "${azureDcTailscaleIp}" -AcceptRoutes'
    }
  }
}

// ---------------------------------------------------------------------------
// 02 - Jonction au domaine (extension native, reboot gere par Azure)
// ---------------------------------------------------------------------------
resource joinDomainExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (joinDomain) {
  parent: vm
  name: '02-JoinDomain'
  location: location
  dependsOn: [
    tailscaleExtension
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      OUPath: domainOuPath
      User: domainJoinUser
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}

// ---------------------------------------------------------------------------
// 03 - Promotion en controleur de domaine secondaire
// ---------------------------------------------------------------------------
resource promoteDcExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (promoteDc) {
  parent: vm
  name: '03-PromoteDC'
  location: location
  dependsOn: [
    joinDomainExtension
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        '${repositoryRawBaseUrl}/${scriptsBasePath}/azure-dc/03-promote-dc.ps1'
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File 03-promote-dc.ps1 -DomainName "${domainName}" -DomainAdminUser "${domainJoinUser}" -DomainAdminPasswordB64 "${base64(domainJoinPassword)}" -SafeModePasswordB64 "${base64(safeModePassword)}" -ReplicationSourceDC "${replicationSourceDC}"'
    }
  }
}

@description('Indique si l extension Tailscale est deployee.')
output tailscaleDeployed bool = deployTailscale

@description('Indique si la jonction de domaine est declenchee.')
output domainJoinDeployed bool = joinDomain

@description('Indique si la promotion AD DS est declenchee.')
output promotionDeployed bool = promoteDc
