targetScope = 'resourceGroup'

// ============================================================================
//  AP_1 - Migration AD DS RedOne (Proxmox) vers Azure
//  BTS SIO option SISR - Infrastructure as Code avec Bicep
// ----------------------------------------------------------------------------
//  Point d'entree du deploiement :
//    1. Network Security Group (regles AD / administration)
//    2. Virtual Network + sous-reseaux
//    3. Machine virtuelle Windows Server 2022 (futur DC secondaire)
//    4. Extensions : Tailscale -> jonction de domaine -> promotion AD DS
//    5. Key Vault optionnel (stockage des secrets pour rotation / audit)
//
//  Les secrets ne sont JAMAIS ecrits dans ce fichier : ils sont passes par
//  le pipeline GitHub Actions (GitHub Secrets) et marques @secure().
// ============================================================================

@description('Region Azure ciblee.')
param location string = resourceGroup().location

@description('Nom court du projet, utilise dans les noms de ressources.')
@minLength(3)
@maxLength(12)
param workloadName string = 'redone'

@description('Environnement logique (lab, dev, recette, prod).')
@minLength(2)
@maxLength(8)
param environment string = 'lab'

@description('Etiquettes appliquees a toutes les ressources.')
param tags object = {
  project: 'AP-BTS-SIO-SISR'
  owner: 'Thibaut HUET'
  domain: 'redone.local'
  managedBy: 'Bicep'
}

// ---------------------------------------------------------------------------
// Reseau
// ---------------------------------------------------------------------------

@description('Prefixe d\'adressage du VNet Azure. Ne doit PAS chevaucher le LAN Proxmox 10.2.41.0/24.')
param vnetAddressPrefix string = '10.3.0.0/16'

@description('Sous-reseau dedie au controleur de domaine Azure.')
param subnetAddsPrefix string = '10.3.1.0/24'

@description('Sous-reseau reserve a une passerelle VPN (utilise uniquement si deployVpnGateway = true).')
param gatewaySubnetPrefix string = '10.3.255.0/27'

@description('Deploie un GatewaySubnet pour une architecture VPN IPsec classique. false = mode Tailscale.')
param deployVpnGateway bool = false

@description('Sources autorisees a administrer la VM en RDP (VPN / Tailscale / LAN).')
param allowedAdminSourcePrefixes array = [
  '10.2.41.0/24'
  '100.64.0.0/10'
]

@description('Sources autorisees pour les flux de replication Active Directory.')
param allowedOnPremSourcePrefixes array = [
  '10.2.41.0/24'
  '100.64.0.0/10'
]

// ---------------------------------------------------------------------------
// Machine virtuelle
// ---------------------------------------------------------------------------

@description('Nom de la VM Azure. Doit rester <= 15 caracteres (contrainte NetBIOS).')
@maxLength(15)
param vmName string = 'SRV-AD-AZ01'

@description('Taille de la VM Azure.')
param vmSize string = 'Standard_B2ms'

@description('Adresse IP privee fixe du futur DC dans snet-adds.')
param privateIpAddress string = '10.3.1.4'

@description('Taille du disque OS en Go.')
@minValue(64)
@maxValue(2048)
param osDiskSizeGb int = 127

@description('SKU de l\'image Windows Server. 2022-datacenter-g2 = Generation 2.')
param imageSku string = '2022-datacenter-g2'

@description('Compte administrateur local de la VM.')
@minLength(3)
param adminUsername string = 'azureadmin'

@description('Mot de passe administrateur local (fourni par GitHub Secrets).')
@secure()
@minLength(12)
param adminPassword string

@description('Expose une IP publique pour le trafic sortant. L\'acces RDP reste filtre par le NSG.')
param deployPublicIp bool = true

// ---------------------------------------------------------------------------
// Active Directory
// ---------------------------------------------------------------------------

@description('Nom FQDN du domaine existant.')
param domainName string = 'redone.local'

@description('Nom NetBIOS du domaine.')
param domainNetbiosName string = 'REDONE'

@description('Compte de domaine utilise pour la jonction et la promotion.')
param domainJoinUser string = 'REDONE\\Administrateur'

@description('Mot de passe du compte de domaine (fourni par GitHub Secrets).')
@secure()
@minLength(8)
param domainJoinPassword string

@description('Mot de passe du mode de restauration des services d\'annuaire (DSRM).')
@secure()
@minLength(8)
param safeModePassword string

@description('OU cible de la jonction. Vide = conteneur Computers par defaut.')
param domainOuPath string = ''

@description('Adresse du DC on-prem (SRV-AD) joignable depuis Azure, via Tailscale ou VPN.')
param onPremDnsIp string = '100.64.0.10'

@description('Adresse Tailscale fixe du DC Azure (a declarer dans la console Tailscale).')
param azureDcTailscaleIp string = '100.64.0.4'

@description('DNS de la plateforme Azure, utilise pour Internet avant Tailscale.')
param azurePlatformDnsIp string = '168.63.129.16'

// ---------------------------------------------------------------------------
// Automatisation / extensions
// ---------------------------------------------------------------------------

@description('Active l\'installation de Tailscale sur la VM Azure.')
param deployTailscale bool = true

@description('Cle d\'authentification Tailscale (fournie par GitHub Secrets).')
@secure()
param tailscaleAuthKey string = ''

@description('Jonction automatique de la VM au domaine existant.')
param joinDomain bool = true

@description('Promotion automatique de la VM en controleur de domaine secondaire.')
param promoteDc bool = true

@description('DC source prefere pour la replication initiale. Vide = selection automatique.')
param replicationSourceDC string = ''

@description('URL de base des scripts bruts (depot GitHub public ou compte de stockage).')
param repositoryRawBaseUrl string = 'https://raw.githubusercontent.com/thibaut-huet/AP-BTS-SIO-SISR-V2/main'

@description('Chemin des scripts dans le depot.')
param scriptsBasePath string = 'AP_1/scripts'

// ---------------------------------------------------------------------------
// Key Vault (optionnel)
// ---------------------------------------------------------------------------

@description('Cree un Key Vault et y stocke les secrets pour audit / rotation. Necessite des droits sur le plan de donnees.')
param deployKeyVault bool = false

@description('Nom du Key Vault. Vide = nom unique genere automatiquement.')
param keyVaultNameOverride string = ''

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var vnetName = 'vnet-${workloadName}-${environment}'
var nsgName = 'nsg-adds-${environment}'
var keyVaultName = empty(keyVaultNameOverride) ? 'kv-${uniqueString(resourceGroup().id)}' : keyVaultNameOverride

// Tailscale n'est lance que si la fonctionnalite est activee ET si une cle est fournie.
var useTailscale = deployTailscale && !empty(tailscaleAuthKey)

// DNS de la carte reseau : Azure pour Internet. La resolution de redone.local
// passe par une regle NRPT configuree par le script Tailscale (DC on-prem).
var nicDnsServers = [
  azurePlatformDnsIp
]

// ============================================================================
// Deploiements
// ============================================================================

module nsg 'modules/nsg.bicep' = {
  name: 'nsg-adds'
  params: {
    nsgName: nsgName
    location: location
    tags: tags
    allowedAdminSourcePrefixes: allowedAdminSourcePrefixes
    allowedOnPremSourcePrefixes: allowedOnPremSourcePrefixes
  }
}

module vnet 'modules/vnet.bicep' = {
  name: 'vnet-adds'
  params: {
    vnetName: vnetName
    location: location
    tags: tags
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddsPrefix: subnetAddsPrefix
    gatewaySubnetPrefix: gatewaySubnetPrefix
    deployVpnGateway: deployVpnGateway
    nsgId: nsg.outputs.nsgId
  }
}

module vm 'modules/vm-adds.bicep' = {
  name: 'vm-adds'
  params: {
    vmName: vmName
    location: location
    tags: tags
    vmSize: vmSize
    osDiskSizeGb: osDiskSizeGb
    imageSku: imageSku
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: vnet.outputs.subnetAddsId
    privateIpAddress: privateIpAddress
    dnsServers: nicDnsServers
    deployPublicIp: deployPublicIp
  }
}

module extensions 'modules/extensions.bicep' = if (joinDomain || promoteDc || useTailscale) {
  name: 'vm-extensions'
  params: {
    vmName: vmName
    vmId: vm.outputs.vmId
    location: location
    repositoryRawBaseUrl: repositoryRawBaseUrl
    scriptsBasePath: scriptsBasePath
    deployTailscale: useTailscale
    tailscaleAuthKey: tailscaleAuthKey
    onPremDnsIp: onPremDnsIp
    azureDcTailscaleIp: azureDcTailscaleIp
    joinDomain: joinDomain
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: domainJoinPassword
    domainOuPath: domainOuPath
    promoteDc: promoteDc
    safeModePassword: safeModePassword
    replicationSourceDC: replicationSourceDC
  }
}

module keyVault 'modules/keyvault.bicep' = if (deployKeyVault) {
  name: 'keyvault-secrets'
  params: {
    keyVaultName: keyVaultName
    location: location
    tags: tags
    adminPassword: adminPassword
    domainJoinPassword: domainJoinPassword
    safeModePassword: safeModePassword
    tailscaleAuthKey: tailscaleAuthKey
  }
}

// ============================================================================
// Sorties
// ============================================================================

@description('Nom du domaine Active Directory cible.')
output domainName string = domainName

@description('Nom NetBIOS du domaine.')
output domainNetbiosName string = domainNetbiosName

@description('Nom de la VM Azure.')
output vmName string = vm.outputs.vmName

@description('Adresse IP privee de la VM dans le VNet Azure.')
output vmPrivateIp string = privateIpAddress

@description('Adresse IP publique de la VM (vide si deployPublicIp = false).')
output vmPublicIp string = vm.outputs.publicIp

@description('Identifiant du sous-reseau snet-adds.')
output subnetAddsId string = vnet.outputs.subnetAddsId

@description('Identifiant du VNet Azure.')
output vnetId string = vnet.outputs.vnetId

@description('Nom DNS Tailscale a utiliser pour joindre la VM.')
output tailscaleHostname string = vmName

@description('Rappel du DC on-prem utilise comme source de replication.')
output onPremDcIp string = onPremDnsIp

@description('Key Vault cree (vide si deployKeyVault = false).')
output keyVaultName string = deployKeyVault ? keyVaultName : ''
