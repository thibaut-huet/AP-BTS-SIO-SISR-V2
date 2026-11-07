// ============================================================================
//  Module : Virtual Network Azure
//  Objectif : creer le VNet, le sous-reseau AD (avec NSG) et, en option,
//             le GatewaySubnet reserve a une passerelle VPN.
// ============================================================================

@description('Nom du Virtual Network.')
param vnetName string

@description('Region Azure.')
param location string

@description('Etiquettes des ressources.')
param tags object = {}

@description('Plage d adressage du VNet (ex: 10.3.0.0/16).')
param vnetAddressPrefix string

@description('Plage du sous-reseau snet-adds (ex: 10.3.1.0/24).')
param subnetAddsPrefix string

@description('Plage du GatewaySubnet (ex: 10.3.255.0/27).')
param gatewaySubnetPrefix string

@description('Cree le GatewaySubnet pour une passerelle VPN IPsec.')
param deployVpnGateway bool = false

@description('Identifiant du NSG a associer au sous-reseau AD.')
param nsgId string

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource subnetAdds 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: vnet
  name: 'snet-adds'
  properties: {
    addressPrefix: subnetAddsPrefix
    networkSecurityGroup: {
      id: nsgId
    }
  }
}

// Le nom GatewaySubnet est reserve par Azure : il ne doit pas etre renomme.
resource subnetGateway 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = if (deployVpnGateway) {
  parent: vnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: gatewaySubnetPrefix
  }
}

@description('Identifiant du VNet.')
output vnetId string = vnet.id

@description('Identifiant du sous-reseau snet-adds.')
output subnetAddsId string = subnetAdds.id

@description('Identifiant du GatewaySubnet (vide si non deploye).')
output gatewaySubnetId string = deployVpnGateway ? subnetGateway.id : ''
