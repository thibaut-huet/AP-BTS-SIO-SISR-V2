# Runbook de déploiement et de migration - AP_1

Ce document décrit la procédure complète, de la préparation jusqu'à la
rétrogradation du contrôleur de domaine Proxmox.

> **Règle d'or :** on ne coupe jamais l'ancien DC avant d'avoir vérifié la
> réplication, les rôles FSMO et le partage `SYSVOL` sur le nouveau DC.

---

## 0. Vue d'ensemble des phases

| Phase | Objectif | Action principale |
|---|---|---|
| 0 | Préparer Tailscale, Azure et GitHub | comptes, OIDC, secrets |
| 1 | Déployer l'infrastructure et joindre le domaine | `promoteDc=false` |
| 2 | Promouvoir le DC Azure | `promoteDc=true` |
| 3 | Valider AD, DNS et réplication | `repadmin`, `dcdiag` |
| 4 | Transférer les rôles FSMO | script `05` |
| 5 | Rétrograder l'ancien DC et ajuster le réseau | script `06` |
| 6 | Nettoyer / arrêter les coûts | désallouer ou supprimer |

---

## 1. Prérequis

### 1.1. Côté Proxmox

- [ ] `SRV-AD` est opérationnel, DNS et DHCP fonctionnels.
- [ ] `SRV-AD2` est répliqué et sain (`repadmin /replsummary`).
- [ ] Le nom `redone.local` résout correctement.
- [ ] L'heure est synchronisée (NTP).
- [ ] Un accès console/RDP à `SRV-AD` est disponible.

### 1.2. Côté Azure

- [ ] Abonnement Azure actif.
- [ ] Azure CLI 2.50+ et Bicep CLI.
- [ ] Droits pour créer un resource group et attribuer un rôle.
- [ ] Quota suffisant pour une `Standard_B2ms` dans la région choisie.
- [ ] **Quota vCPU régional vérifié** :
  `az vm list-usage --location westeurope -o table | grep -i "Total Regional"`.
  Un abonnement gratuit est typiquement limité à 4 vCPU : c'est suffisant pour
  le DC (`B2ms`, 2 vCPU), pas pour un DC + un client Windows (voir `README.md`
  §4.2).

### 1.3. Côté GitHub

- [ ] Dépôt `AP-BTS-SIO-SISR-V2` (ou dépôt dédié `AP_1`).
- [ ] Droits d'administration pour créer secrets, variables et environnement.
- [ ] Branche `main` protégée (recommandé).

---

## 2. Préparer Tailscale

### 2.1. Installer Tailscale sur `SRV-AD`

Depuis une session administrateur de `SRV-AD` :

```powershell
$installer = Join-Path $env:TEMP 'tailscale-setup-latest.exe'
Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $installer
Start-Process -FilePath $installer -ArgumentList '/quiet' -Wait

$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
& $tailscale up --hostname=srv-ad --advertise-routes=10.2.41.0/24 --accept-routes --accept-dns=false
& $tailscale ip -4
& $tailscale status

# Autoriser DNS/AD/RDP sur l'interface Tailscale
Get-NetConnectionProfile |
    Where-Object InterfaceAlias -like '*Tailscale*' |
    Set-NetConnectionProfile -NetworkCategory Private
```

> Taguer aussi `srv-ad` avec `tag:dc-onprem` dans la console Tailscale
> (`Machines > srv-ad > Edit > Tags`) : les ACL de l'AP s'appuient sur ce tag.

> `--advertise-routes=10.2.41.0/24` est **optionnel** : il permet au DC Azure
> d'atteindre le NAS et les clients du LAN. Il faut ensuite approuver la route
> dans la console Tailscale (`Machines > srv-ad > Edit route settings`).
> Sans cette option, seul le DC `SRV-AD` est joignable via son IP Tailscale.

### 2.2. Fixer les IP Tailscale

Dans la console Tailscale :

1. **Machines** > `srv-ad` > **Edit** > **IPv4 address** > `100.64.0.10`.
2. Plus tard, faire de même pour `SRV-AD-AZ01` > `100.64.0.4`.

> L'IP statique doit être définie **avant** le déploiement Azure, car la règle
> NRPT de la VM Azure pointe `*.redone.local` vers `100.64.0.10` via Tailscale.
> La NIC Azure conserve `168.63.129.16` pour la résolution Internet.

### 2.3. Créer une clé d'authentification

Console Tailscale > **Settings** > **Keys** > **Generate auth key** :

- clé **pré-autorisée** ;
- expiration courte (1 jour) ;
- taguée `tag:dc-azure` (nécessaire pour les ACL Tailscale).

Copier la clé `tskey-auth-...` : elle sera stockée dans GitHub Secrets.

### 2.4. Vérifier la connectivité

Depuis un poste également connecté au tailnet :

```bash
tailscale ping 100.64.0.10
nslookup redone.local 100.64.0.10
```

---

## 3. Configurer Azure et GitHub (OIDC)

### 3.1. Créer le resource group

```bash
az login
az account show --query "{subscriptionId:id, tenantId:tenantId}" -o table
az group create --name rg-redone-adds-lab --location westeurope
```

### 3.2. Créer l'app registration et le service principal

```bash
APP_NAME="ap1-bicep-deploy"
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID"
echo "APP_ID=$APP_ID"
```

### 3.3. Ajouter la fédération OIDC

Le job utilise `environment: azure-lab`. Le sujet du jeton est donc
`repo:<owner>/<repo>:environment:azure-lab`.

```bash
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-env-azure-lab",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:thibaut-huet/AP-BTS-SIO-SISR-V2:environment:azure-lab",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

> Si vous n'utilisez pas d'environnement GitHub, le sujet devient
> `repo:<owner>/<repo>:ref:refs/heads/main`. Vous pouvez ajouter les deux
> fédérations pour couvrir le push et l'exécution manuelle.

### 3.4. Attribuer le rôle Contributor

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-redone-adds-lab"
```

> Pour activer `deployKeyVault=true`, `Contributor` suffit pour créer le coffre
> et sa politique d'accès. En entreprise, préférer un rôle personnalisé limité
> aux types de ressources déployés.

### 3.5. Renseigner GitHub

**Settings > Secrets and variables > Actions > Variables** :

| Variable | Valeur |
|---|---|
| `AZURE_CLIENT_ID` | `$APP_ID` |
| `AZURE_TENANT_ID` | tenant Azure |
| `AZURE_SUBSCRIPTION_ID` | ID de l'abonnement |
| `AZURE_RESOURCE_GROUP` | `rg-redone-adds-lab` |
| `AZURE_LOCATION` | `westeurope` |

**Secrets** :

| Secret | Valeur |
|---|---|
| `VM_ADMIN_PASSWORD` | mot de passe fort généré |
| `DOMAIN_JOIN_PASSWORD` | mot de passe de `REDONE\Administrateur` |
| `DSRM_PASSWORD` | mot de passe DSRM fort |
| `TAILSCALE_AUTH_KEY` | `tskey-auth-...` |

**Settings > Environments** : créer `azure-lab`. Ajouter si possible une règle
de protection (reviewers) pour le déploiement.

---

## 4. Préparer les sites Active Directory (sur `SRV-AD`)

À faire **avant** la promotion du DC Azure.

```powershell
# Vérifier les sites existants
Get-ADReplicationSite -Filter * | Select-Object Name

# Créer le site Azure (si le site Proxmox s'appelle autrement, adapter)
New-ADReplicationSite -Name 'Site-Azure'
New-ADReplicationSubnet -Name '10.3.1.0/24' -Site 'Site-Azure'
New-ADReplicationSubnet -Name '100.64.0.0/10' -Site 'Site-Azure'

# Relier les sites (adapter Site-Proxmox au nom réel)
New-ADReplicationSiteLink -Name 'LINK-Proxmox-Azure' `
    -SitesIncluded 'Site-Proxmox','Site-Azure' `
    -Cost 10 -ReplicationFrequencyInMinutes 15 `
    -InterSiteTransportProtocol IP
```

Vérification :

```powershell
Get-ADReplicationSubnet -Filter * | Select-Object Name, Site
Get-ADReplicationSiteLink -Filter * | Select-Object Name, SitesIncluded, Cost
```

> Si `Site-Proxmox` n'existe pas encore, renommer `Default-First-Site-Name` ou
> utiliser ce nom dans les commandes. L'important est que `10.3.1.0/24` et
> `100.64.0.0/10` soient rattachés à `Site-Azure`.

---

## 5. Phase 1 - Déployer l'infrastructure et joindre le domaine

### 5.1. Lancer un `what-if`

GitHub > **Actions** > **AP_1 - Deploy Azure AD Infrastructure** >
**Run workflow** :

| Champ | Valeur |
|---|---|
| `action` | `what-if` |
| `promoteDc` | `false` |
| `joinDomain` | `true` |

Le `what-if` doit montrer :

- `Microsoft.Network/networkSecurityGroups` ;
- `Microsoft.Network/virtualNetworks` + `snet-adds` ;
- `Microsoft.Network/publicIPAddresses`, `networkInterfaces` ;
- `Microsoft.Compute/virtualMachines` ;
- `Microsoft.Compute/virtualMachines/extensions` (`01-Tailscale`, `02-JoinDomain`).

### 5.2. Déployer

Relancer avec `action = deploy`, `promoteDc = false`.

> Un push sur `main` déclenche aussi le déploiement automatique, mais avec
> `promoteDc=false` par sécurité. La promotion du DC reste une action manuelle
> explicite (`workflow_dispatch`).

En CLI (équivalent) :

```bash
export VM_ADMIN_PASSWORD='<mot de passe admin VM>'
export DOMAIN_JOIN_PASSWORD='<mot de passe REDONE\Administrateur>'
export DSRM_PASSWORD='<mot de passe DSRM>'
export TAILSCALE_AUTH_KEY='tskey-auth-...'

az deployment group create \
  --resource-group rg-redone-adds-lab \
  --name adds-phase1 \
  --parameters AP_1/bicep/main.bicepparam \
    promoteDc=false \
    joinDomain=true
```

### 5.3. Vérifier le déploiement Azure

```bash
az deployment group show -g rg-redone-adds-lab -n adds-phase1 \
  --query properties.provisioningState -o tsv

az vm list -g rg-redone-adds-lab -o table
az vm extension list -g rg-redone-adds-lab --vm-name SRV-AD-AZ01 -o table
```

Statuts attendus :

| Extension | Statut attendu |
|---|---|
| `01-Tailscale` | `Provisioning succeeded` |
| `02-JoinDomain` | `Provisioning succeeded` |

### 5.4. Vérifier Tailscale et la jonction

Dans la console Tailscale, la machine `SRV-AD-AZ01` doit apparaître avec
l'IP `100.64.0.4`.

Se connecter en RDP à `100.64.0.4` (ou via `mstsc /v:100.64.0.4`), puis :

```powershell
tailscale status
tailscale ping 100.64.0.10
Get-DnsClientNrptRule | Where-Object Namespace -contains '.redone.local'
Resolve-DnsName redone.local
Resolve-DnsName pkgs.tailscale.com
nltest /dsgetdc:redone.local
(Get-CimInstance Win32_ComputerSystem).Domain
```

Résultat attendu : domaine = `redone.local` et règle NRPT
`.redone.local -> 100.64.0.10`.

> La NIC Azure doit conserver `168.63.129.16` comme DNS (Internet). C'est la
> règle NRPT qui dirige `redone.local` vers le DC on-prem via Tailscale.

Si la jonction a échoué :

```powershell
# Sur la VM Azure, en admin
nltest /dsgetdc:redone.local
ipconfig /all
Get-Content C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.JsonADDomainExtension\*\*.log -Tail 100
```

---

## 6. Phase 2 - Promouvoir le DC Azure

### 6.1. Vérifier une dernière fois les prérequis

- [ ] `SRV-AD-AZ01` est jointe au domaine.
- [ ] `redone.local` résout depuis la VM Azure.
- [ ] `Site-Azure` existe et contient `10.3.1.0/24` + `100.64.0.0/10`.
- [ ] Le compte `REDONE\Administrateur` fonctionne.
- [ ] Le mot de passe DSRM est disponible.

### 6.2. Lancer le déploiement avec promotion

GitHub > Actions > Run workflow :

| Champ | Valeur |
|---|---|
| `action` | `deploy` |
| `promoteDc` | `true` |
| `joinDomain` | `true` |

En CLI :

```bash
export VM_ADMIN_PASSWORD='<mot de passe admin VM>'
export DOMAIN_JOIN_PASSWORD='<mot de passe REDONE\Administrateur>'
export DSRM_PASSWORD='<mot de passe DSRM>'
export TAILSCALE_AUTH_KEY='tskey-auth-...'

az deployment group create \
  --resource-group rg-redone-adds-lab \
  --name adds-phase2 \
  --parameters AP_1/bicep/main.bicepparam \
    promoteDc=true \
    joinDomain=true
```

> La promotion installe AD DS, le rôle DNS et redémarre la VM. L'extension
> `03-PromoteDC` peut apparaître en `failed` dans Azure à cause du redémarrage :
> vérifier que `NTDS` tourne avant de conclure à un échec.

### 6.3. Vérifier la promotion

Après redémarrage, se reconnecter à `100.64.0.4` :

```powershell
Get-Service NTDS, DNS, Netlogon, KDC
Get-ADDomainController -Filter * | Format-Table Name, Site, IPv4Address
```

Si la promotion n'a pas eu lieu, exécuter le script manuellement :

```powershell
cd C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\*
# ou copier le script depuis le depot
.\03-promote-dc.ps1 `
  -DomainName 'redone.local' `
  -DomainAdminUser 'REDONE\Administrateur' `
  -DomainAdminPassword '<mot de passe>' `
  -SafeModePassword '<mot de passe DSRM>' `
  -SiteName 'Site-Azure'
```

Consulter les journaux :

```text
C:\Windows\NTDS\dcpromo.log
C:\Windows\debug\dcpromo.log
C:\Windows\Azure\Logs\CustomScript\03-promote-dc.log
```

---

## 7. Phase 3 - Valider AD, DNS et réplication

Sur le DC Azure :

```powershell
# 1. Contrôleurs de domaine
Get-ADDomainController -Filter * | Format-Table Name, Site, IPv4Address, IsGlobalCatalog

# 2. Réplication
repadmin /replsummary
repadmin /showrepl

# 3. Santé globale
dcdiag /test:replications /test:advertising /test:dns /v

# 4. SYSVOL et NETLOGON
net share
Test-Path '\\redone.local\SYSVOL'
Test-Path '\\redone.local\NETLOGON'

# 5. DNS
Resolve-DnsName _ldap._tcp.dc._msdcs.redone.local -Type SRV
Resolve-DnsName srv-ad.redone.local
Resolve-DnsName srv-ad-az01.redone.local
Get-DnsClientNrptRule | Where-Object Namespace -contains '.redone.local'

# 6. Heure
w32tm /query /status
```

Ou lancer le script complet :

```powershell
.\04-validate-replication.ps1
```

> Le script bascule également la règle NRPT vers `100.64.0.4` : le DC Azure
> devient sa propre référence DNS. Vérifier ensuite avec
> `Get-DnsClientNrptRule`.

Résultats attendus :

- `repadmin /replsummary` : **0 échec** ;
- `dcdiag` : tous les tests passent (ou seuls des avertissements mineurs) ;
- `SYSVOL` et `NETLOGON` sont partagés ;
- les enregistrements `_msdcs` et `_sites` sont visibles ;
- le DC Azure apparaît dans le site `Site-Azure`.

---

## 8. Phase 4 - Transférer les rôles FSMO

À exécuter depuis le **DC Azure**, après validation de la réplication.

```powershell
# Simulation
.\05-transfer-fsmo.ps1 -WhatIf

# Transfert réel
.\05-transfer-fsmo.ps1
```

Vérifier :

```powershell
Get-ADDomain | Select-Object PDCEmulator, RIDMaster, InfrastructureMaster
Get-ADForest | Select-Object SchemaMaster, DomainNamingMaster
```

Les 5 rôles doivent pointer vers `SRV-AD-AZ01`.

> Attendre la réplication et vérifier de nouveau `repadmin /replsummary` et
> l'accès à `\\redone.local\SYSVOL` avant de passer à la phase 5.

---

## 9. Phase 5 - Rétrograder l'ancien DC

### 9.1. Sauvegarder l'état système de `SRV-AD`

```powershell
# Sur SRV-AD, avec un disque de sauvegarde disponible
wbadmin start systemstatebackup -backupTarget:E: -quiet
```

### 9.2. Vérifier que les FSMO ne sont plus sur `SRV-AD`

```powershell
Get-ADDomain | Select-Object PDCEmulator, RIDMaster, InfrastructureMaster
Get-ADForest | Select-Object SchemaMaster, DomainNamingMaster
```

### 9.3. Rétrograder

```powershell
# Simulation
.\06-demote-onprem-dc.ps1 -WhatIf

# Rétrogradation réelle
.\06-demote-onprem-dc.ps1
```

Le serveur redevient un simple serveur membre et redémarre.

### 9.4. Ajuster DHCP et DNS

- Sur le DHCP (avant ou après la rétrogradation), modifier l'option 006 pour
  inclure le DC Azure si les clients peuvent le joindre.
- Si les clients restent sur le LAN Proxmox sans VPN, conserver `SRV-AD2`
  comme DNS local et ajouter le DC Azure uniquement lorsque le routage est en
  place.
- Vérifier que les clients résolvent `redone.local` et appliquent les GPO :

```cmd
gpupdate /force
nltest /dsgetdc:redone.local
```

---

## 10. Phase 6 - Nettoyage et coûts

```bash
# Arrêter la VM sans la supprimer
az vm deallocate -g rg-redone-adds-lab -n SRV-AD-AZ01

# Supprimer tout le laboratoire
az group delete --name rg-redone-adds-lab --yes --no-wait
```

Avant suppression :

- [ ] sauvegarde de l'état système du DC Azure ;
- [ ] export des journaux de validation (`04-replication-report.txt`) ;
- [ ] révocation de la clé Tailscale utilisée ;
- [ ] suppression de l'app registration OIDC si elle n'est plus utilisée.

---

## 11. Rollback

### 11.1. La jonction échoue

1. Vérifier Tailscale : `tailscale status`, `tailscale ping 100.64.0.10`.
2. Vérifier le DNS : `Resolve-DnsName redone.local`.
3. Vérifier les identifiants et l'heure.
4. Relancer l'extension ou le script `02-join-domain.ps1`.

### 11.2. La promotion échoue

1. Lire `C:\Windows\NTDS\dcpromo.log` et le journal du script.
2. Corriger DNS / sites AD / droits.
3. Si le serveur est partiellement promu, utiliser
   `Uninstall-ADDSDomainController` pour revenir à un serveur membre, puis
   relancer la promotion.
4. En dernier recours (laboratoire), supprimer le resource group et redéployer.

### 11.3. L'ancien DC a été rétrogradé trop tôt

- Ne pas paniquer : `SRV-AD2` peut encore assurer le service.
- Si les FSMO étaient sur `SRV-AD` et qu'il n'est plus joignable, il peut être
  nécessaire de **saisir** les rôles (`Seize`), opération risquée.
- Le plus sûr est de restaurer l'état système sauvegardé ou de reconstruire un
  DC et de laisser la réplication converger.
- Documenter l'incident : c'est un excellent retour d'expérience pour le jury.

---

## 12. Checklist finale pour la soutenance

- [ ] `what-if` et déploiement verts dans GitHub Actions.
- [ ] Historique Git avec plusieurs commits (infra, scripts, docs).
- [ ] VM Azure visible dans le portail, NSG appliqué.
- [ ] `tailscale status` connecté des deux côtés.
- [ ] `Get-ADDomainController -Filter *` affiche 3 DC.
- [ ] `repadmin /replsummary` : 0 échec.
- [ ] `dcdiag` : tests de réplication/DNS OK.
- [ ] Sites AD `Site-Proxmox` et `Site-Azure` configurés.
- [ ] `SYSVOL` et `NETLOGON` partagés.
- [ ] Transfert FSMO vérifié.
- [ ] Rétrogradation documentée avec captures.
- [ ] Rapport `04-replication-report.txt` archivé.
