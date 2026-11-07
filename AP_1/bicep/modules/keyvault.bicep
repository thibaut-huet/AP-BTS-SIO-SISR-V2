// ============================================================================
//  Module : Azure Key Vault (optionnel)
//  Objectif : conserver les secrets de deploiement pour audit et rotation.
//
//  IMPORTANT : la VM recoit ses secrets via les parametres @secure() du
//  pipeline, et non via Key Vault, afin d eviter le probleme "poule et oeuf"
//  (le deploiement doit lire le secret avant que la VM n existe, et le
//  principal de deploiement doit avoir les droits sur le plan de donnees).
//  Ce coffre sert de reference pour la rotation et la tracabilite.
// ============================================================================

@description('Nom globalement unique du Key Vault (<= 24 caracteres).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Region Azure.')
param location string

@description('Etiquettes des ressources.')
param tags object = {}

@description('Mot de passe administrateur de la VM.')
@secure()
param adminPassword string

@description('Mot de passe du compte de domaine.')
@secure()
param domainJoinPassword string

@description('Mot de passe DSRM.')
@secure()
param safeModePassword string

@description('Cle d authentification Tailscale.')
@secure()
param tailscaleAuthKey string = ''

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: false
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    accessPolicies: [
      {
        tenantId: tenant().tenantId
        objectId: deployer().objectId
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
            'delete'
            'recover'
            'backup'
            'restore'
            'purge'
          ]
        }
      }
    ]
  }
}

resource vmAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'vm-admin-password'
  properties: {
    value: adminPassword
    contentType: 'text/plain'
  }
}

resource domainJoinPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'domain-join-password'
  properties: {
    value: domainJoinPassword
    contentType: 'text/plain'
  }
}

resource dsrmPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'dsrm-password'
  properties: {
    value: safeModePassword
    contentType: 'text/plain'
  }
}

resource tailscaleAuthKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(tailscaleAuthKey)) {
  parent: keyVault
  name: 'tailscale-auth-key'
  properties: {
    value: tailscaleAuthKey
    contentType: 'text/plain'
  }
}

@description('Identifiant du Key Vault.')
output keyVaultId string = keyVault.id

@description('Nom du Key Vault.')
output keyVaultName string = keyVault.name
