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
| 4 | Transférer les rôles FSMO (optionnel) | script `05` |
| 5 | Rétrograder l'ancien DC (optionnel) et ajuster le réseau | script `06` |
| 6 | Nettoyer / arrêter les coûts | désallouer ou supprimer |

> Les phases 4 et 5 sont **optionnelles** et s'exécutent **en mode vérification
> par défaut** (aucune modification sans `-ExecuteTransfer` / `-ExecuteDemotion`).
> Pour rejouer la démonstration en boucle, ne pas les exécuter : voir §11.4.
>
> **Relance rapide** (reset avant chaque nouvelle démonstration) : le résumé de
> ce qui se supprime et de ce qui se refait est en **§11.4.1**. En bref :
> supprimer le resource group, le device Tailscale et le compte ordinateur AD ;
> conserver l'app registration OIDC et la clé Tailscale si elle est *Reusable*.

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
- [ ] Quota suffisant pour une `Standard_D2as_v4` dans la région choisie.
- [ ] **Région éligible pour l'abonnement** (voir `troubleshooting.md` §2.8) :
  certaines régions refusent les nouveaux abonnements (`RequestDisallowedByAzure`).
- [ ] **Quota vCPU régional vérifié** :
  `az vm list-usage --location polandcentral -o table | grep -i "Total Regional"`.
  Un abonnement gratuit est typiquement limité à 4 vCPU : c'est suffisant pour
  le DC (`D2as_v4`, 2 vCPU), pas pour un DC + un client Windows (voir `README.md`
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

#### Approuver la route `10.2.41.0/24` (indispensable)

`--advertise-routes` **ne suffit pas** : la route doit être **approuvée** par un
administrateur du tailnet. Tant qu'elle ne l'est pas, `tailscale status` affiche :

```text
# Health check:
#     - Some peers are advertising routes but not approved
1 route is advertised but not approved
```

Comment cela casse la jonction : la VM Azure interroge `SRV-AD` (via NRPT,
`100.64.0.10`), qui répond avec son **IP LAN `10.2.41.x`**. Sans la route
approuvée, cette adresse est injoignable depuis Azure, et l'extension
`02-JoinDomain` échoue avec `0x54b` (`ERROR_NO_SUCH_DOMAIN`).

Approbation dans la console : **Machines > `srv-ad` > Subnet routes** (ou
**⋯ > Edit route settings**) > cocher `10.2.41.0/24` > **Save**.

Vérifier ensuite sur `SRV-AD` :

```powershell
tailscale status        # plus de "not approved"
```

> **L'approbation peut être perdue** après la recréation du device, un changement
> de clé ou une nouvelle annonce de route. La revérifier à chaque relance.
>
> Pour ne plus y penser, l'auto-approbation se configure dans la politique ACL
> Tailscale :
>
> ```json
> "autoApprovers": {
>   "routes": {
>     "10.2.41.0/24": ["tag:dc-onprem"]
>   }
> }
> ```


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
- **Reusable** (obligatoire pour relancer le déploiement : une clé non
  réutilisable est consommée au premier usage) ;
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
az group create --name rg-redone-adds-lab --location polandcentral
```

> Remplacer `polandcentral` par une région éligible pour votre abonnement si
> nécessaire. La valeur doit être **identique** à la variable GitHub
> `AZURE_LOCATION`, car le workflow écrase `main.bicepparam` avec cette
> variable. Voir `troubleshooting.md` §2.8.

### 3.2. Créer l'app registration et le service principal

```bash
APP_NAME="ap1-bicep-deploy"
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID"
echo "APP_ID=$APP_ID"
```

### 3.3. Ajouter la fédération OIDC

Le job utilise `environment: azure-lab`. Le sujet du jeton est donc
`repo:thibaut-huet@286593076/AP-BTS-SIO-SISR-V2@1387710223:environment:azure-lab`.

> **Attention aux identifiants immuables.** Ce dépôt utilise le format de
> sujet immuable de GitHub (identifiants numériques du propriétaire et du
> dépôt, séparés par `@`). Le sujet doit être **copié exactement** depuis
> l'erreur `AADSTS700213` ou depuis
> `GET /repos/{owner}/{repo}/actions/oidc/customization/sub`
> (champ `sub_claim_prefix`). Un sujet sans les identifiants ne correspondra
> plus.

```bash
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-env-azure-lab",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:thibaut-huet@286593076/AP-BTS-SIO-SISR-V2@1387710223:environment:azure-lab",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

> Si vous n'utilisez pas d'environnement GitHub, le sujet devient
> `repo:thibaut-huet@286593076/AP-BTS-SIO-SISR-V2@1387710223:ref:refs/heads/main`.
> Vous pouvez ajouter les deux fédérations pour couvrir le push et l'exécution
> manuelle.

### 3.4. Attribuer le rôle Contributor

Le rôle peut être attribué à **deux portées**. Le choix est un compromis entre
moindre privilège et facilité de relance.

#### 3.4.1. Portée resource group — le plus sûr (recommandé en production)

```bash
az group create --name rg-redone-adds-lab --location polandcentral
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-redone-adds-lab"
```

C'est la portée la plus restrictive : le service principal ne peut agir que
dans ce groupe de ressources. **C'est le choix à privilégier par défaut**, et
celui qui correspond à un contexte professionnel.

> **Limite pour une démo rejouable.** L'attribution de rôle fait partie des
> objets **supprimés avec le resource group**. Or le workflow commence par
> `az group create` : un `Contributor` limité au RG ne peut pas recréer un RG
> qui n'existe plus (et la recréation du RG nécessite un droit au niveau
> abonnement). Après chaque `az group delete`, il faut donc recréer le groupe
> **et** l'attribution à la main avant de relancer le pipeline.

#### 3.4.2. Portée abonnement — choix retenu pour ce livrable

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

> **Pourquoi ce choix malgré un périmètre plus large ?** Le TP est une
> démonstration de migration **rejouée plusieurs fois** : à chaque reset, le
> resource group est supprimé puis recréé par le pipeline. Une attribution au
> niveau abonnement **n'est pas supprimée avec le resource group**, ce qui
> permet d'enchaîner les déploiements sans rejouer manuellement les commandes
> de rôle et sans risquer un `AuthorizationFailed` sur l'étape
> « Ensure resource group exists ».
>
> Ce n'est **pas** la configuration recommandée en production : `Contributor`
> au niveau abonnement donne au service principal des droits sur **toutes** les
> ressources de l'abonnement. En entreprise, revenir à la portée resource group
> (§3.4.1) ou à un rôle personnalisé limité aux types de ressources déployés.

> Dans les deux cas, il faut que **le compte exécutant la commande** possède
> `Owner` ou `User Access Administrator` sur la portée visée.

Vérifier l'attribution (propagation : quelques minutes) :

```bash
az role assignment list --assignee "$APP_ID" --all -o table
```

> Pour activer `deployKeyVault=true`, `Contributor` suffit pour créer le coffre
> et sa politique d'accès. En entreprise, préférer un rôle personnalisé limité
> aux types de ressources déployés.

### 3.5. Renseigner GitHub

> **Ne jamais recopier `$APP_ID` tel quel dans GitHub.** Les champs GitHub ne
> sont pas un shell : ils n'interprètent ni `$APP_ID`, ni les guillemets, ni
> les espaces. Il faut coller la **valeur GUID** affichée par la commande
> `echo`, par exemple `4f2a9c1e-8b3d-4c5a-9e7f-1a2b3c4d5e6f`.
>
> - `AZURE_CLIENT_ID` = **appId** (client ID) de l'app registration.
> - Ne pas confondre avec l'**object ID** (`az ad app show --query id`), qui
>   sert dans les commandes `az ad app federated-credential ...`.
> - Ne pas ajouter de guillemets ni de `$` dans le champ GitHub.

Récupérer les valeurs à copier :

```bash
APP_ID=$(az ad app list --display-name "ap1-bicep-deploy" --query "[0].appId" -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
```

Vérifier que l'appId est bien un GUID valide (8-4-4-4-12 caractères
hexadécimaux) :

```bash
[[ "$APP_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] \
  && echo "appId valide" || echo "ERREUR : appId invalide"
```

**Settings > Environments > `azure-lab` > Environment variables** (recommandé,
car le job déclare `environment: azure-lab`) — ou à défaut
**Settings > Secrets and variables > Actions > Variables** :

| Variable | Valeur à coller | Exemple |
|---|---|---|
| `AZURE_CLIENT_ID` | appId de l'app registration | `4f2a9c1e-8b3d-4c5a-9e7f-1a2b3c4d5e6f` |
| `AZURE_TENANT_ID` | tenant Azure | `11111111-2222-3333-4444-555555555555` |
| `AZURE_SUBSCRIPTION_ID` | ID de l'abonnement | `66666666-7777-8888-9999-000000000000` |
| `AZURE_RESOURCE_GROUP` | nom du resource group (pas un ID) | `rg-redone-adds-lab` |
| `AZURE_LOCATION` | région Azure **éligible** pour l'abonnement | `polandcentral` |

> Le workflow utilise `AZURE_LOCATION: ${{ vars.AZURE_LOCATION || 'polandcentral' }}` :
> si la variable GitHub est absente, la région `polandcentral` s'applique par
> défaut. `main.bicepparam` contient également `param location = 'polandcentral'`,
> mais le paramètre passé par le workflow reste prioritaire.

**Secrets** (même niveau : environnement `azure-lab` ou dépôt) :

| Secret | Portée | Valeur / contrainte |
|---|---|---|
| `VM_ADMIN_PASSWORD` | **Compte administrateur local de la VM Azure** (`azureadmin`), pas le compte de domaine | **12 caractères minimum**, majuscule + minuscule + chiffre + caractère spécial |
| `DOMAIN_JOIN_PASSWORD` | Compte de domaine `REDONE\Administrateur` (maquette Proxmox : `ServeurAzure2022`) | 8 caractères minimum, **doit correspondre au mot de passe réel du compte sur `SRV-AD`** |
| `DSRM_PASSWORD` | Mot de passe DSRM (restauration AD) | 8 caractères minimum |
| `TAILSCALE_AUTH_KEY` | Clé Tailscale | `tskey-auth-...` |

> **`VM_ADMIN_PASSWORD` ne sert qu'à Azure** : c'est le mot de passe du compte
> local `azureadmin` créé dans la VM, pas celui de `REDONE\Administrateur`.
>
> Le paramètre Bicep impose `@minLength(12)`. Comme `main.bicepparam` lit la
> valeur avec `readEnvironmentVariable('VM_ADMIN_PASSWORD')` **au moment de la
> compilation**, un secret de 11 caractères ou moins fait échouer le pipeline
> dès le `what-if` avec :
>
> ```text
> Error BCP333: The provided value (whose length will always be less than or
> equal to 11) is too short to assign to a target for which the minimum
> allowable length is 12.
> ```
>
> Utiliser un mot de passe d'au moins 12 caractères (idéalement 16+).

**Settings > Environments** : créer `azure-lab`. Ajouter si possible une règle
de protection (reviewers) pour le déploiement.

> **Contrôle avant de relancer le workflow** : dans l'onglet Actions, le run
> doit afficher un `client-id` sous forme de GUID, jamais `$APP_ID`. En cas de
> doute, comparer avec `az ad app show --id "$APP_ID" --query appId -o tsv`.

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
export DOMAIN_JOIN_PASSWORD='ServeurAzure2022'   # maquette Proxmox
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
- [ ] Le secret `DOMAIN_JOIN_PASSWORD` correspond au mot de passe réel de
      `REDONE\Administrateur` sur `SRV-AD` (maquette : `ServeurAzure2022`).
- [ ] Le mot de passe DSRM est disponible.
- [ ] Le secret `VM_ADMIN_PASSWORD` fait **au moins 12 caractères** (compte
      local `azureadmin` de la VM Azure, pas le compte de domaine).

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
export DOMAIN_JOIN_PASSWORD='ServeurAzure2022'   # maquette Proxmox
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

## 8. Phase 4 - Transférer les rôles FSMO (optionnelle)

> **Étape optionnelle, désactivée par défaut.** Le script `05` s'exécute en
> **mode vérification** : il affiche les détenteurs actuels et les rôles qui
> seraient transférés, sans rien modifier. Le transfert réel exige
> `-ExecuteTransfer`. Pour une démonstration rejouable, laisser les FSMO sur le
> DC Proxmox et passer directement au nettoyage (§11.4).

À exécuter depuis le **DC Azure**, après validation de la réplication.

```powershell
# Mode vérification : audit seul, aucune modification (défaut)
.\05-transfer-fsmo.ps1

# Simulation du transfert réel
.\05-transfer-fsmo.ps1 -ExecuteTransfer -WhatIf

# Transfert réel
.\05-transfer-fsmo.ps1 -ExecuteTransfer
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

## 9. Phase 5 - Rétrograder l'ancien DC (optionnelle)

> **Étape optionnelle, désactivée par défaut.** La rétrogradation est
> irréversible et empêche de rejouer la migration : elle convient à une
> fermeture réelle du site Proxmox, pas à une démonstration. Pour rejouer la
> migration, s'arrêter après la phase 4, supprimer le resource group Azure et
> redéployer. Les scripts de cette phase ne modifient rien sans
> `-ExecuteDemotion`.

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

### 9.3. Contrôler, puis rétrograder

```powershell
# Mode vérification : audit seul, aucune modification (défaut)
.\06-demote-onprem-dc.ps1

# Simulation de la rétrogradation réelle
.\06-demote-onprem-dc.ps1 -ExecuteDemotion -WhatIf

# Rétrogradation réelle : action irréversible
.\06-demote-onprem-dc.ps1 -ExecuteDemotion
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

# Supprimer tout le laboratoire (attendre la fin avant un reset)
az group delete --name rg-redone-adds-lab --yes
```

Avant suppression :

- [ ] sauvegarde de l'état système du DC Azure **si la VM a été promue** ;
- [ ] export des journaux de validation (`04-replication-report.txt`) ;
- [ ] **rôles FSMO ramenés sur `SRV-AD`** si un transfert réel a eu lieu
  (voir 11.4) ;
- [ ] suppression du **compte ordinateur AD** `SRV-AD-AZ01`, ou des
  métadonnées DC s'il a été promu (voir 11.4) ;
- [ ] suppression du **device Tailscale** `SRV-AD-AZ01` et note de l'IP
  statique `100.64.0.4` à réassigner après redéploiement ;
- [ ] clé Tailscale : la **conserver** si un redéploiement est prévu, la
  révoquer seulement en cas d'arrêt définitif ;
- [ ] suppression de l'app registration OIDC **seulement** si elle n'est plus
  utilisée (la conserver pour un reset) ;
- [ ] attribution de rôle : avec une portée **abonnement** (§3.4.2), elle n'est
  **pas** supprimée avec le resource group et rien à refaire ; avec une portée
  resource group (§3.4.1), elle disparaît avec le groupe et doit être recréée.

> Supprimer le resource group sans ramener les FSMO laisserait le domaine avec
> des rôles pointant vers un DC disparu : il faudrait alors les **saisir**
> (`Seize`), opération risquée. C'est précisément ce qu'évite la procédure 11.4.

> Le resource group ne contient **pas** le compte ordinateur AD ni le device
> Tailscale : ces deux identités sont externes à Azure et doivent être
> nettoyées séparément pour un reset complet.

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

### 11.4. Relancer / rejouer la démonstration (reset)

Objectif : refaire la migration plusieurs fois sans toucher à l'infrastructure
Proxmox de référence. **Ne jamais rétrograder `SRV-AD`** dans ce cas.

#### 11.4.1. Résumé : ce qui se supprime et ce qui se refait

Supprimer le resource group ne suffit pas : trois identités vivent **en dehors
d'Azure** et doivent être nettoyées séparément.

| Élément | Où | Action à chaque relance |
|---|---|---|
| Resource group `rg-redone-adds-lab` | Azure | **Supprimer** |
| Device `SRV-AD-AZ01` | Tailscale | **Supprimer** (+ réaffecter l'IP `100.64.0.4` après) |
| Compte ordinateur `SRV-AD-AZ01` | AD Proxmox | **Supprimer** |
| Clé `TAILSCALE_AUTH_KEY` | Tailscale + GitHub | **Garder** si elle est *Reusable* et non expirée, sinon **régénérer** |
| App registration + SP + fédération OIDC | Entra ID | **Garder** (survit à la suppression du RG) |
| Attribution de rôle `Contributor` | Abonnement (§3.4.2) | **Garder** (survit à la suppression du RG) |
| Site AD `Site-Azure` + sous-réseaux | AD Proxmox | **Garder** (réutilisables) |

> **Checklist express**
> 1. Supprimer le resource group
> 2. Supprimer le device Tailscale
> 3. Supprimer le compte ordinateur AD
> 4. Vérifier la clé Tailscale (la régénérer si besoin)
> 5. Redéployer, puis réaffecter `100.64.0.4`

#### 11.4.2. FSMO — seulement si un transfert réel a eu lieu

Les étapes 4 et 5 étant optionnelles et en mode vérification par défaut, les
rôles FSMO restent normalement sur `SRV-AD`. **Ne pas transférer les FSMO est le
bon choix pour une démo rejouable** : aucun rôle ne pointe vers le DC Azure
éphémère.

Si `05-transfer-fsmo.ps1` a quand même été lancé **avec** `-ExecuteTransfer`,
ramener les rôles sur `SRV-AD` :

```powershell
Move-ADDirectoryServerOperationMasterRole `
    -Identity 'SRV-AD' `
    -OperationMasterRole SchemaMaster, DomainNamingMaster, PDCEmulator, RIDMaster, InfrastructureMaster `
    -Confirm:$false
```

Vérifier :

```powershell
Get-ADDomain | Select-Object PDCEmulator, RIDMaster, InfrastructureMaster
Get-ADForest | Select-Object SchemaMaster, DomainNamingMaster
```

Les 5 rôles doivent pointer vers `SRV-AD`.

#### 11.4.3. Supprimer le resource group

```bash
az group delete --name rg-redone-adds-lab --yes
az group exists --name rg-redone-adds-lab   # doit retourner false
```

Attendre la fin de la suppression avant de redéployer : `az group create` peut
échouer si le groupe est encore en cours de suppression.

> L'app registration, son service principal et la fédération OIDC vivent dans
> **Entra ID (tenant)** : ils ne sont **pas** supprimés avec le resource group.
> En revanche, une attribution de rôle **scopée sur le RG** disparaît avec lui ;
> une attribution **scopée sur l'abonnement** (§3.4.2) survit. C'est tout
> l'intérêt du choix retenu pour ce livrable : aucun `AuthorizationFailed` ni
> `No subscriptions found` au run suivant.

#### 11.4.4. Supprimer le device Tailscale

Dans la console Tailscale, **Machines** :

1. supprimer tous les devices `SRV-AD-AZ01` et `SRV-AD-AZ01-1`, `-2`, …
   (créés par les relances précédentes) ;
2. **avant** de redéployer, sinon la nouvelle VM sera enregistrée sous un nom
   suffixé ;
3. après redéploiement, ouvrir le nouveau device > **Edit** > **IPv4 address**
   > saisir `100.64.0.4` > **Save** ;
4. vérifier que la route `10.2.41.0/24` annoncée par `SRV-AD` est toujours
   **approuvée** (`SRV-AD > Subnet routes`). Une recréation de device ou un
   changement de clé peut faire perdre l'approbation — voir
   `troubleshooting.md` §3.2.1.

> L'IP `100.64.0.4` n'est **jamais** attribuée automatiquement : Tailscale
> donne une IP aléatoire dans `100.64.0.0/10`. Le script
> `01-setup-tailscale.ps1` ne fait que **signaler** l'écart dans son journal.
> L'affectation se fait à la main (ou via l'API Tailscale), et une IP ne peut
> pas être portée par deux devices : supprimer les anciens d'abord.

En phase 1, une IP différente n'empêche pas la jonction (elle passe par
`SRV-AD`, `100.64.0.10`). Elle devient critique pour le RDP et pour la phase 3
(bascule de la règle NRPT vers `100.64.0.4`).

#### 11.4.5. Supprimer le compte ordinateur AD

Depuis `SRV-AD`. Choisir le cas selon la phase atteinte.

**Cas A — phase 1 seule (serveur membre)**, le cas normal :

```powershell
# 1. Inspecter
Get-ADComputer -Identity 'SRV-AD-AZ01' -Properties LastLogonDate, DistinguishedName |
    Format-List Name, DistinguishedName, LastLogonDate

# 2. Supprimer
Remove-ADComputer -Identity 'SRV-AD-AZ01' -Confirm:$false
```

Si la suppression échoue avec :

```text
Remove-ADComputer : Le service d'annuaire ne peut effectuer l'opération requise
que sur un objet Nœud terminal (erreur 8213)
```

c'est que l'objet a un enfant (souvent un `serviceConnectionPoint`
« Windows Virtual Machine » déposé par l'outillage Azure). Vérifier puis
supprimer récursivement :

```powershell
$dn = (Get-ADComputer -Filter "Name -eq 'SRV-AD-AZ01'").DistinguishedName
Get-ADObject -SearchBase $dn -Filter * -SearchScope OneLevel |
    Format-Table Name, objectClass, DistinguishedName -AutoSize

Remove-ADObject -Identity $dn -Recursive -Confirm:$false
```

> Ne pas utiliser `-Recursive` si l'enfant est un `nTDSSettings` : cela signifie
> que l'objet est un contrôleur de domaine, et il faut passer par `ntdsutil`
> (cas B). Vérifier d'abord avec `Get-ADDomainController -Filter *`.

Sans ce nettoyage, la nouvelle VM échoue à la jonction avec un message du type
« le compte existe déjà ». AD ne peut pas créer deux objets de même nom : il
réutilise l'ancien (avec ses attributs périmés) ou refuse.

**Cas B — phase 2 (VM promue DC)** :

```powershell
# 1. S'assurer que l'objet n'est plus un DC actif
Get-ADDomainController -Filter * | Format-Table Name, Site

# 2. Nettoyage des métadonnées
ntdsutil
#   metadata cleanup
#   select operation target
#   list sites / select site <n> / list servers in site / select server <n>
#   quit / remove selected server
```

Puis supprimer les enregistrements DNS résiduels de `SRV-AD-AZ01` (`A`, `SRV`,
`NS`) dans `redone.local` et `_msdcs.redone.local` :

```powershell
Get-DnsServerResourceRecord -ZoneName 'redone.local' -Name 'SRV-AD-AZ01' -ErrorAction SilentlyContinue
Remove-DnsServerResourceRecord -ZoneName 'redone.local' -Name 'SRV-AD-AZ01' -RRType A -Force
```

Vérifier qu'il ne reste que les DC voulus (`SRV-AD`, `SRV-AD2`) et que la
réplication est saine :

```powershell
Get-ADDomainController -Filter * | Format-Table Name, Site, IPv4Address
repadmin /replsummary
```

#### 11.4.6. Vérifier la clé Tailscale

Une clé d'authentification n'est **pas réutilisable par défaut** : utilisée une
fois, elle devient invalide, et le run suivant échoue avec
`invalid key: API key ... not valid`.

- clé créée avec **Reusable** et non expirée → **rien à refaire** ;
- sinon → en générer une nouvelle (pre-approved, `tag:dc-azure`, **Reusable**,
  expiration courte) et mettre à jour le secret GitHub `TAILSCALE_AUTH_KEY`
  (au niveau **environnement `azure-lab`** s'il y est défini, sinon dépôt).

Voir `troubleshooting.md` §3.7.

#### 11.4.7. Redéployer

Via le pipeline :

| Champ | Valeur |
|---|---|
| `action` | `deploy` |
| `promoteDc` | `false` |
| `joinDomain` | `true` |

Puis, après validation de la phase 1, relancer avec `promoteDc=true`.

Vérifications après le run :

```bash
az vm extension list -g rg-redone-adds-lab --vm-name SRV-AD-AZ01 -o table
```

Attendu : `01-Tailscale` et `02-JoinDomain` en `Provisioning succeeded`.

```powershell
Get-ADComputer -Filter "Name -eq 'SRV-AD-AZ01'" -Properties LastLogonDate |
    Format-List Name, LastLogonDate
```

La `LastLogonDate` doit être **du jour**. Puis réaffecter `100.64.0.4` au
nouveau device Tailscale.

La réplication repart de `SRV-AD`, resté intact. Le script `05` est idempotent
et ne déplace que les rôles qui ne sont pas déjà sur la cible.

> **À retenir** : le reset complet nettoie trois choses distinctes — le
> resource group Azure, le device Tailscale et le compte ordinateur (ou l'objet
> DC) dans l'AD. La clé Tailscale et l'app registration OIDC, elles, se
> conservent. Oublier le device ou le compte AD ne casse pas Azure, mais
> provoque un nom suffixé dans Tailscale ou une erreur de jonction.


---

## 12. Checklist finale pour la soutenance

- [ ] `what-if` et déploiement verts dans GitHub Actions.
- [ ] Historique Git avec plusieurs commits (infra, scripts, docs).
- [ ] VM Azure visible dans le portail, NSG appliqué.
- [ ] `tailscale status` connecté des deux côtés.
- [ ] Route `10.2.41.0/24` **approuvée** (`1 route is advertised but not
  approved` absent) et IP statique `100.64.0.4` affectée au DC Azure.
- [ ] `Get-ADDomainController -Filter *` affiche 3 DC.
- [ ] `repadmin /replsummary` : 0 échec.
- [ ] `dcdiag` : tests de réplication/DNS OK.
- [ ] Sites AD `Site-Proxmox` et `Site-Azure` configurés.
- [ ] `SYSVOL` et `NETLOGON` partagés.
- [ ] Transfert FSMO **vérifié** (mode vérification par défaut,
  `-ExecuteTransfer` pour l'action réelle).
- [ ] Rétrogradation **documentée** (optionnelle : mode vérification par défaut,
  `-ExecuteDemotion` pour l'action réelle) avec captures.
- [ ] Resource group Azure supprimé après la démonstration (si migration rejouable).
- [ ] Rapport `04-replication-report.txt` archivé.
