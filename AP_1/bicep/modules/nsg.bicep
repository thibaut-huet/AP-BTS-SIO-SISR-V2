// ============================================================================
//  Module : Network Security Group du sous-reseau AD
//  Objectif : limiter les flux entrants aux seuls besoins Active Directory
//             et a l'administration via le reseau prive / Tailscale.
// ============================================================================

@description('Nom du NSG.')
param nsgName string

@description('Region Azure.')
param location string

@description('Etiquettes des ressources.')
param tags object = {}

@description('Sources autorisees en RDP (LAN, VPN, Tailscale).')
param allowedAdminSourcePrefixes array = [
  '10.2.41.0/24'
  '100.64.0.0/10'
]

@description('Sources autorisees pour les flux de replication AD.')
param allowedOnPremSourcePrefixes array = [
  '10.2.41.0/24'
  '100.64.0.0/10'
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-Admin'
        properties: {
          description: 'RDP restreint aux reseaux d administration (VPN site-a-site ou Tailscale).'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: allowedAdminSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '3389'
          ]
        }
      }
      {
        name: 'Allow-AD-Replication-TCP'
        properties: {
          description: 'Flux Active Directory : DNS, Kerberos, LDAP, SMB, GC, RPC dynamique.'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: allowedOnPremSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '53'
            '88'
            '135'
            '139'
            '389'
            '445'
            '464'
            '636'
            '3268'
            '3269'
            '49152-65535'
          ]
        }
      }
      {
        name: 'Allow-AD-Replication-UDP'
        properties: {
          description: 'Flux Active Directory UDP : DNS, Kerberos, NTP, LDAP.'
          priority: 111
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefixes: allowedOnPremSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '53'
            '88'
            '123'
            '389'
            '464'
          ]
        }
      }
      {
        name: 'Allow-ICMP-Diagnostics'
        properties: {
          description: 'Tests de connectivite (ping) depuis les reseaux internes.'
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourceAddressPrefixes: allowedOnPremSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

@description('Identifiant de ressource du NSG.')
output nsgId string = nsg.id
