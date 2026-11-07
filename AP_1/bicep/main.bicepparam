// ============================================================================
//  Parametres NON SENSIBLES du deploiement AP_1
//  Les secrets (mots de passe, cle Tailscale) sont injectes par le pipeline
//  GitHub Actions a partir des GitHub Secrets.
// ============================================================================
using './main.bicep'

param location = 'westeurope'
param workloadName = 'redone'
param environment = 'lab'

// Reseau Azure : 10.3.0.0/16 (aucun chevauchement avec le LAN 10.2.41.0/24)
param vnetAddressPrefix = '10.3.0.0/16'
param subnetAddsPrefix = '10.3.1.0/24'
param gatewaySubnetPrefix = '10.3.255.0/27'

// Mode retenu : Tailscale (pas de passerelle VPN facturee a l heure)
param deployVpnGateway = false
param deployTailscale = true

// VM
param vmName = 'SRV-AD-AZ01'
param vmSize = 'Standard_B2ms'
param privateIpAddress = '10.3.1.4'
param osDiskSizeGb = 127
param imageSku = '2022-datacenter-g2'
param adminUsername = 'azureadmin'
param deployPublicIp = true

// Active Directory existant
param domainName = 'redone.local'
param domainNetbiosName = 'REDONE'
param domainJoinUser = 'REDONE\\Administrateur'
param domainOuPath = ''
param onPremDnsIp = '100.64.0.10'
param azureDcTailscaleIp = '100.64.0.4'

// Automatisation
param joinDomain = true
param promoteDc = true
param replicationSourceDC = ''

// Secrets : lus depuis l'environnement du pipeline (GitHub Secrets).
// Aucune valeur sensible n'est ecrite dans ce fichier.
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')
param domainJoinPassword = readEnvironmentVariable('DOMAIN_JOIN_PASSWORD')
param safeModePassword = readEnvironmentVariable('DSRM_PASSWORD')
param tailscaleAuthKey = readEnvironmentVariable('TAILSCALE_AUTH_KEY', '')

// Depot GitHub utilise par les extensions Azure
param repositoryRawBaseUrl = 'https://raw.githubusercontent.com/thibaut-huet/AP-BTS-SIO-SISR-V2/main'
param scriptsBasePath = 'AP_1/scripts'

// Key Vault : false par defaut (activer apres avoir valide les droits RBAC)
param deployKeyVault = false
param keyVaultNameOverride = ''
