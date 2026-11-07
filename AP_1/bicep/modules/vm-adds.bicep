// ============================================================================
//  Module : Machine virtuelle Windows Server 2022 (futur DC Azure)
//  Objectif : carte reseau a IP fixe, DNS vers le DC on-prem, VM Gen2,
//             disque manage SSD, sans exposition RDP non maitrisee.
// ============================================================================

@description('Nom de la VM (<= 15 caracteres).')
@maxLength(15)
param vmName string

@description('Region Azure.')
param location string

@description('Etiquettes des ressources.')
param tags object = {}

@description('Taille de la VM.')
param vmSize string = 'Standard_B2ms'

@description('Taille du disque OS en Go.')
param osDiskSizeGb int = 127

@description('SKU de l image Windows Server.')
param imageSku string = '2022-datacenter-g2'

@description('Compte administrateur local.')
param adminUsername string

@description('Mot de passe administrateur local.')
@secure()
param adminPassword string

@description('Identifiant du sous-reseau cible.')
param subnetId string

@description('Adresse IP privee fixe de la VM.')
param privateIpAddress string

@description('Serveurs DNS de la carte reseau (DC on-prem puis DC Azure).')
param dnsServers array

@description('Cree et associe une IP publique (trafic sortant / extensions Azure).')
param deployPublicIp bool = true

// ---------------------------------------------------------------------------
// IP publique (optionnelle)
// ---------------------------------------------------------------------------
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (deployPublicIp) {
  name: '${vmName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// ---------------------------------------------------------------------------
// Carte reseau
// ---------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnetId
          }
          publicIPAddress: deployPublicIp ? {
            id: publicIp.id
          } : null
        }
      }
    ]
    dnsSettings: {
      dnsServers: dnsServers
    }
    enableAcceleratedNetworking: false
  }
}

// ---------------------------------------------------------------------------
// Machine virtuelle
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        osType: 'Windows'
        deleteOption: 'Delete'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Sorties
// ---------------------------------------------------------------------------
@description('Identifiant de la VM.')
output vmId string = vm.id

@description('Nom de la VM.')
output vmName string = vm.name

@description('Identifiant de la carte reseau.')
output nicId string = nic.id

@description('Adresse IP publique (vide si non demandee).')
output publicIp string = deployPublicIp ? publicIp!.properties.ipAddress : ''
