# Dépannage - AP_1

## 1. Méthodologie

1. **Identifier la couche** : Azure (déploiement) → réseau (Tailscale/DNS) →
   Windows (jonction) → AD DS (promotion) → réplication.
2. **Lire les journaux** avant de modifier quoi que ce soit.
3. **Tester dans l'ordre** : `tailscale status`, `Resolve-DnsName`,
   `nltest /dsgetdc`, `Get-Service NTDS`, `repadmin`.
4. **Ne jamais désactiver un pare-feu ou un antivirus** pour contourner un
   problème : ouvrir uniquement le flux nécessaire.
5. Documenter l'incident et la résolution (attendu pour le BTS).

### Emplacements des journaux utiles

| Élément | Emplacement |
|---|---|
| Extension CustomScript | `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\` |
| Extension JsonADDomain | `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.JsonADDomainExtension\` |
| Scripts AP_1 | `C:\WindowsAzure\Logs\CustomScript\` |
| Promotion AD | `C:\Windows\NTDS\dcpromo.log`, `C:\Windows\debug\dcpromo.log` |
| Réplication | Observateur d'événements > `Directory Service` |
| DNS | Observateur d'événements > `DNS Server` |
| Déploiement Azure | Portail > Resource Group > Deployments > opération |

---

## 2. Erreurs de déploiement Azure / Bicep

### 2.1. `The parameter file ... could not be found` ou erreur `.bicepparam`

- Vérifier la version d'Azure CLI : `az version` (2.50+ recommandé).
- Vérifier que le fichier commence par `using './main.bicep'`.
- Tester la compilation :

```bash
az bicep build --file AP_1/bicep/main.bicep --stdout > /dev/null
az bicep lint --file AP_1/bicep/main.bicep
```

### 2.2. `AADSTS70021` / `AADSTS700213: No matching federated identity record`

Le sujet OIDC ne correspond pas. Vérifier :

- le nom de l'environnement GitHub (`azure-lab`) ;
- le sujet exact présenté dans le log du run (ligne `subject claim - ...`) ;
- l'audience : `api://AzureADTokenExchange`.

**Identifiants immuables** : les dépôts récents présentent un sujet de la forme
`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:azure-lab`. Le credential
Azure doit contenir **exactement** cette chaîne, identifiants inclus.

```bash
# Vérifier le préfixe utilisé par le dépôt
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/thibaut-huet/AP-BTS-SIO-SISR-V2/actions/oidc/customization/sub

# Lister les fédérations
az ad app federated-credential list --id "$APP_ID" -o table
```

Corriger la fédération (exemple pour ce dépôt) :

```bash
az ad app federated-credential update \
  --id "$APP_ID" \
  --federated-credential-id "github-env-azure-lab" \
  --parameters '{
    "name": "github-env-azure-lab",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:thibaut-huet@286593076/AP-BTS-SIO-SISR-V2@1387710223:environment:azure-lab",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

> Garder l'ancienne fédération le temps de valider la nouvelle, puis la
> supprimer. La propagation peut prendre quelques minutes.

### 2.3. `AuthorizationFailed` / `The client does not have authorization`

Le service principal n'a pas le rôle sur la cible. Vérifier :

```bash
az role assignment list --assignee "$APP_ID" --all -o table
```

`Contributor` sur le resource group (`/subscriptions/<sub>/resourceGroups/rg-redone-adds-lab`) est suffisant pour ce livrable, mais il est **supprimé avec le resource group**. Une attribution au niveau abonnement survit aux resets : c'est le choix retenu ici pour rejouer la démonstration. Voir `procedure-deploiement.md` §3.4.

Réattribuer le rôle (avec un compte `Owner` / `User Access Administrator`) :

```bash
# Portée abonnement (survit à la suppression du RG) - choix de ce livrable
SUB_ID=$(az account show --query id -o tsv)
az role assignment create --assignee "$APP_ID" --role Contributor --scope "/subscriptions/$SUB_ID"

# Ou portée resource group (plus sûr, mais à refaire après chaque suppression)
az group create -n rg-redone-adds-lab -l polandcentral
az role assignment create --assignee "$APP_ID" --role Contributor \
  --scope "/subscriptions/$SUB_ID/resourceGroups/rg-redone-adds-lab"
```

Comptez 5 à 10 minutes de propagation avant de relancer le workflow.

### 2.3.1. `No subscriptions found for ***` à l'étape Azure login (OIDC)

Symptôme dans le log du run :

```text
Federated token details:
 issuer - https://token.actions.githubusercontent.com
 subject claim - repo:...:environment:azure-lab
 ...
Attempting Azure CLI login by using OIDC...
Error: No subscriptions found for ***.
```

**L'OIDC fonctionne.** Le `subject claim` a été présenté et accepté (aucun
`AADSTS700213`), donc la fédération, le `client-id` et le `tenant-id` sont
corrects. Le message signifie seulement que le service principal **ne voit
aucun abonnement**, c'est-à-dire qu'il n'a **plus aucun role assignment**.

Cas typique : le resource group a été supprimé, et avec lui l'unique
attribution `Contributor` scopée sur ce groupe. Il n'y a **rien à régénérer
côté GitHub** (pas de nouveau secret, pas de nouvelle fédération) : il suffit
de recréer l'attribution de rôle (§2.3).

> Ne pas confondre avec un problème d'app registration : l'app, le service
> principal et la fédération vivent dans **Entra ID (tenant)** et ne sont pas
> supprimés avec le resource group.

### 2.4. `QuotaExceeded` / `SkuNotAvailable`

- Changer de région (`polandcentral` → `francecentral`) ou de taille
  (`Standard_D2as_v4` → `Standard_D2s_v4` ou `Standard_B2ms`).
- Penser à supprimer les VM orphelines : un abonnement gratuit est typiquement
  limité à **4 vCPU régionaux**, pas à un nombre de VM (`README.md` §4.2).
- Vérifier les quotas :

```bash
az vm list-usage --location polandcentral -o table
```

### 2.5. `AADSTS700016` / `Application with identifier '$APP_ID' was not found`

Le champ GitHub contient la **chaîne littérale** `$APP_ID` au lieu de la
valeur GUID. Les champs GitHub ne sont pas un shell : ils ne développent
aucune variable.

Vérifier la valeur de `AZURE_CLIENT_ID` :

- elle doit ressembler à `4f2a9c1e-8b3d-4c5a-9e7f-1a2b3c4d5e6f` ;
- elle ne doit contenir ni `$`, ni guillemets, ni espaces ;
- c'est l'**appId** (client ID), pas l'**object ID** de l'app registration.

```bash
# Valeur attendue
az ad app list --display-name "ap1-bicep-deploy" --query "[0].appId" -o tsv

# Vérifier le format du GUID
[[ "$AZURE_CLIENT_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] \
  && echo "appId valide" || echo "ERREUR : appId invalide"
```

Corriger la variable dans **Settings > Environments > `azure-lab` >
Environment variables** (ou **Settings > Secrets and variables > Actions**),
puis relancer le workflow.

### 2.6. `BCP333` / `InvalidParameter: adminPassword`

Le secret `VM_ADMIN_PASSWORD` ne respecte pas les contraintes. Il s'agit du
**mot de passe du compte administrateur local `azureadmin` de la VM Azure**,
et non du compte de domaine `REDONE\Administrateur`.

- **12 caractères minimum** (le paramètre Bicep impose `@minLength(12)`) ;
- majuscule, minuscule, chiffre et caractère spécial ;
- ne pas utiliser un mot de passe déjà utilisé dans un ancien document.

Erreur observée au `what-if` si le secret est trop court :

```text
Error BCP333: The provided value (whose length will always be less than or
equal to 11) is too short to assign to a target for which the minimum
allowable length is 12.
```

Cause : `readEnvironmentVariable('VM_ADMIN_PASSWORD')` est évalué lors de la
**compilation Bicep**. La longueur du secret est donc connue avant le
déploiement, et le pipeline échoue sans rien créer.

Corriger le secret dans **Settings > Environments > `azure-lab` > Secrets**
(ou **Settings > Secrets and variables > Actions**), avec une valeur de
12 caractères minimum, puis relancer le workflow.

> Les autres secrets ont des minimums plus bas : `DOMAIN_JOIN_PASSWORD` et
> `DSRM_PASSWORD` imposent 8 caractères (`@minLength(8)`).

### 2.7. L'extension télécharge un script en 404

- Vérifier que le dépôt est **public** ou que l'URL brute est accessible.
- Tester l'URL dans un navigateur :

```text
https://raw.githubusercontent.com/thibaut-huet/AP-BTS-SIO-SISR-V2/main/AP_1/scripts/azure-dc/01-setup-tailscale.ps1
```

- Vérifier `repositoryRawBaseUrl` et `scriptsBasePath` passés au déploiement.
- Si le fichier a été ajouté après le déploiement, relancer le déploiement ou
  l'extension.

### 2.8. `RequestDisallowedByAzure` / région non éligible

Message typique :

```text
{"code": "RequestDisallowedByAzure", "target": "nsg-adds-lab",
 "message": "Resource 'nsg-adds-lab' was disallowed by Azure: This policy
 maintains a set of best available regions ... The selected region is
 currently not accepting new customers"}
```

**Cause** : la région demandée est bloquée pour cet abonnement (souvent un
abonnement étudiant, gratuit ou récent). Ce n'est pas une erreur Bicep.

Attention : le workflow écrase la valeur de `main.bicepparam` avec la variable
GitHub `AZURE_LOCATION` :

```yaml
--parameters "$PARAM_FILE" location="$AZURE_LOCATION"
```

Même si `main.bicepparam` contient `param location = 'polandcentral'`, c'est la
variable GitHub qui gagne. Si la variable est absente, le workflow applique
`polandcentral` par défaut (`${{ vars.AZURE_LOCATION || 'polandcentral' }}`).
Vérifier les deux niveaux :

- **Settings > Environments > `azure-lab` > Environment variables** (prioritaire)
- **Settings > Secrets and variables > Actions > Variables**

```bash
gh variable list                    # variables du dépôt
gh variable list --env azure-lab    # variables de l'environnement
```

**Correction** : choisir une région éligible et la mettre dans
`AZURE_LOCATION`. Tester la création d'un NSG dans une région candidate :

```bash
LOC=francecentral   # tester aussi polandcentral, swedencentral, northeurope...
RG="rg-test-$LOC"

az group create --name "$RG" --location "$LOC"
az network nsg create --resource-group "$RG" --name nsg-test --location "$LOC"
az group delete --name "$RG" --yes --no-wait
```

Si la création du NSG passe, la région est utilisable. Mettre à jour
`AZURE_LOCATION`, puis relancer le workflow. Le resource group peut rester dans
son ancienne région : les ressources suivent le paramètre `location`.

> Vérifier aussi la disponibilité de la taille de VM dans la nouvelle région :
> `az vm list-skus --location "$LOC" --size Standard_D2as_v4 -o table`.
> Si aucune région n'est acceptée, le blocage est au niveau de l'abonnement :
> contacter le support Azure ou utiliser un autre abonnement.

### 2.9. `The extension operation timed out`

- La promotion AD peut dépasser le délai de l'extension à cause du redémarrage.
- Vérifier `Get-Service NTDS` : si le service tourne, la promotion a réussi.
- Relancer uniquement si nécessaire :

```bash
az vm extension delete -g rg-redone-adds-lab --vm-name SRV-AD-AZ01 -n 03-PromoteDC
# puis relancer le déploiement
```

### 2.10. `InUseSubnetCannotBeDeleted` au redéploiement

```text
Subnet snet-adds is in use by .../networkInterfaces/SRV-AD-AZ01-nic/ipConfigurations/ipconfig1
```

**Ce n'est pas une erreur du premier déploiement** : elle n'apparaît qu'à la
**relance**, quand la carte réseau de la VM existe déjà.

Cause : si les sous-réseaux sont déclarés comme **ressources enfants
séparées** du VNet, le PUT du VNet parent ne contient pas la liste `subnets`.
Azure en déduit que le sous-réseau doit être supprimé, puis le recréer — ce qui
échoue car une NIC y est attachée.

Correctif appliqué dans `modules/vnet.bicep` : les sous-réseaux sont déclarés
**dans** `properties.subnets` de la ressource VNet. Le template est ainsi
déclaratif complet et ARM fait une mise à jour en place.

> Ne pas corriger en supprimant la VM : ça débloque une fois, mais le problème
> revient à chaque relance. Corriger le template.

Si le message persiste après le correctif (état de déploiement incohérent),
libérer la NIC en dernier recours :

```bash
az vm delete -g rg-redone-adds-lab --name SRV-AD-AZ01 --yes
# puis relancer le workflow (la VM est recréée par le déploiement)
```

---

## 3. Tailscale

### 3.1. `tailscale status` vide ou `Logged out`

```powershell
Get-Service Tailscale
tailscale status
tailscale up --authkey=<nouvelle-cle> --hostname=SRV-AD-AZ01 --unattended --accept-dns=false
```

- Vérifier que la clé n'est pas expirée ou révoquée.
- Vérifier que la VM a bien un accès Internet sortant (IP publique ou NAT).

### 3.2. `tailscale ping 100.64.0.10` échoue

- Vérifier que `SRV-AD` est connecté au même tailnet.
- Vérifier l'IP statique dans la console Tailscale.
- Vérifier les ACL : le tag du DC Azure doit être autorisé vers le DC on-prem.
- Vérifier le profil réseau de l'interface Tailscale : s'il est `Public`, le
  pare-feu Windows peut bloquer DNS/RDP. Le script le passe en `Private` sur le
  DC Azure ; sur `SRV-AD`, exécuter si besoin :
  `Get-NetConnectionProfile | Where-Object InterfaceAlias -like '*Tailscale*' | Set-NetConnectionProfile -NetworkCategory Private`
- Tester depuis un autre poste du tailnet pour isoler le problème.

### 3.3. `redone.local` ne résout pas

- Vérifier la règle NRPT (`*.redone.local` -> `100.64.0.10`, puis `100.64.0.4`
  après promotion) et laisser la NIC Azure sur `168.63.129.16`.
- Vérifier que le service DNS tourne sur `SRV-AD`.
- Tester directement :

```powershell
nslookup redone.local 100.64.0.10
Resolve-DnsName _ldap._tcp.dc._msdcs.redone.local -Server 100.64.0.10 -Type SRV
```

- Si la route `10.2.41.0/24` a été annoncée, vérifier qu'elle est **approuvée**
  dans la console Tailscale.

### 3.4. Le nom de machine Tailscale n'est pas `SRV-AD-AZ01`

Le script passe `--hostname=$vmName`. Si la machine a été renommée après coup,
relancer :

```powershell
tailscale up --hostname=SRV-AD-AZ01 --unattended --accept-dns=false
```

### 3.5. `redone.local` ne résout pas malgré Tailscale

Vérifier la règle NRPT :

```powershell
Get-DnsClientNrptRule |
    Where-Object Namespace -contains '.redone.local' |
    Format-List Name, Namespace, NameServers, DisplayName
```

Si elle est absente ou incorrecte :

```powershell
Add-DnsClientNrptRule -Namespace '.redone.local' `
    -NameServers '100.64.0.10' `
    -DisplayName 'AP1 - redone.local via Tailscale'
Clear-DnsClientCache
Resolve-DnsName redone.local
```

Après la promotion, la règle doit pointer vers `100.64.0.4` (le DC Azure) :

```powershell
Get-DnsClientNrptRule |
    Where-Object Namespace -contains '.redone.local' |
    ForEach-Object { Set-DnsClientNrptRule -Name $_.Name -NameServers '100.64.0.4' }
```

### 3.6. Internet ne fonctionne pas au premier boot

La NIC Azure doit garder le DNS `168.63.129.16` pour résoudre
`pkgs.tailscale.com`, GitHub et Windows Update. Si un ancien déploiement a mis
`100.64.0.10` sur la NIC :

```bash
az network nic update -g rg-redone-adds-lab -n SRV-AD-AZ01-nic \
  --dns-servers 168.63.129.16
```

Puis redémarrer la VM et compter sur la règle NRPT pour `redone.local`.

### 3.7. `invalid key: API key ... not valid` sur l'extension `01-Tailscale`

```text
backend error: invalid key: API key kfM6WWt3Lb11CNTRL not valid
```

La clé d'authentification Tailscale est refusée. Causes, par ordre de fréquence :

1. **Clé déjà consommée** : une auth key n'est **pas réutilisable par défaut**.
   Utilisée une première fois, elle devient invalide. C'est le piège classique
   d'une relance de déploiement.
2. **Clé expirée** (le runbook recommande 1 jour).
3. **Mauvaise valeur** : clé d'**API** (`tskey-api-...`) collée à la place d'une
   clé d'**authentification** (`tskey-auth-...`), valeur tronquée, espace ou
   retour à la ligne ajouté dans le secret GitHub.
4. Clé révoquée dans la console.

Correctif : console Tailscale > **Settings > Keys** > générer une clé
**pre-approved**, taguée `tag:dc-azure`, **Reusable**, expiration courte.
Mettre à jour le secret GitHub `TAILSCALE_AUTH_KEY` (au niveau **environnement
`azure-lab`** s'il y est défini, sinon au niveau dépôt), puis relancer.

Si l'extension reste en `Failed` après correction :

```bash
az vm extension delete -g rg-redone-adds-lab --vm-name SRV-AD-AZ01 -n 01-Tailscale
# puis relancer le déploiement
```


---

## 4. Jonction au domaine

### 4.1. `The specified domain either does not exist or could not be contacted`

Causes fréquentes :

1. DNS incorrect sur la VM Azure.
2. Tailscale non connecté.
3. Pare-feu Windows / NSG qui bloque Kerberos ou LDAP.
4. Heure décalée de plus de 5 minutes.

Tests :

```powershell
ipconfig /all
Resolve-DnsName redone.local
nltest /dsgetdc:redone.local
w32tm /query /status
Test-NetConnection 100.64.0.10 -Port 88
Test-NetConnection 100.64.0.10 -Port 389
```

### 4.2. `The trust relationship between this workstation and the primary domain failed`

La machine a été clonée ou le compte machine est incohérent. Dans le laboratoire :

```powershell
Reset-ComputerMachinePassword -Server SRV-AD -Credential (Get-Credential)
# ou rejoindre de nouveau le groupe de travail puis le domaine
```

### 4.3. `Access is denied` lors de la jonction

- Utiliser un compte du domaine (`REDONE\Administrateur`), pas un compte local.
- Vérifier que le compte n'est pas verrouillé.
- **Vérifier que `DOMAIN_JOIN_PASSWORD` correspond exactement au mot de passe
  actuel de `REDONE\Administrateur` sur `SRV-AD`.** Sur la maquette Proxmox,
  ce mot de passe est `ServeurAzure2022`. Un changement côté AD sans mise à
  jour du secret GitHub (ou l'inverse) fait échouer la jonction avec
  `The user name or password is incorrect`.
- Vérifier l'OU cible : si elle n'existe pas, la jonction échoue.
- Tester les identifiants :

```powershell
Test-ComputerSecureChannel -Server SRV-AD
```

### 4.4. L'extension `02-JoinDomain` échoue mais `Add-Computer` manuel fonctionne

- Lire le journal de l'extension.
- Vérifier le format du paramètre `domainJoinUser` (`REDONE\Administrateur`).
- Vérifier que le mot de passe passé par GitHub Secrets ne contient pas de
  caractères interprétés par le shell (le workflow utilise des variables
  d'environnement, mais vérifier les guillemets).
- Vérifier que `DOMAIN_JOIN_PASSWORD` est bien le mot de passe **actuel** de
  `REDONE\Administrateur` (maquette : `ServeurAzure2022`) et non l'ancien
  `Serveur2022`.
- Relancer l'extension après correction.

---

## 5. Promotion AD DS

### 5.1. `Verification of prerequisites failed`

Lire le détail dans `dcpromo.log`. Causes fréquentes :

- DNS non fonctionnel (`_msdcs` absent) ;
- site AD inexistant ou sous-réseau non déclaré ;
- mot de passe DSRM trop faible ;
- compte utilisé non administrateur du domaine ;
- réplication en erreur avec les autres DC.

### 5.2. La promotion redémarre la VM et Azure marque l'extension en échec

Comportement connu. Vérifier après redémarrage :

```powershell
Get-Service NTDS
Get-ADDomainController -Filter *
```

Si `NTDS` tourne, la promotion est réussie. Le statut Azure n'est pas
représentatif de l'état réel.

### 5.3. `The DNS server is not advertising itself`

Sur le nouveau DC :

```powershell
Get-Service DNS
Get-DnsServerDiagnostics
dcdiag /test:dns /v
```

Vérifier que la zone `redone.local` est bien répliquée et que le DC écoute
sur son IP Tailscale (`100.64.0.4`) et son IP Azure (`10.3.1.4`).

### 5.4. Le DC Azure n'apparaît pas dans `Site-Azure`

```powershell
Get-ADDomainController -Filter * | Select-Object Name, Site
Get-ADReplicationSubnet -Filter * | Select-Object Name, Site
```

Si le sous-réseau n'est pas déclaré, AD place le DC dans le site par défaut.
Créer les sous-réseaux et déplacer le DC :

```powershell
New-ADReplicationSubnet -Name '10.3.1.0/24' -Site 'Site-Azure'
Move-ADDirectoryServer -Identity SRV-AD-AZ01 -Site 'Site-Azure'
```

---

## 6. Réplication

### 6.1. `repadmin /replsummary` affiche des échecs

| Code | Signification | Piste |
|---|---|---|
| **8524** | Le DNS ne peut pas résoudre le partenaire | vérifier `_msdcs`, les enregistrements `A` et le DNS |
| **1722** | Le serveur RPC est indisponible | vérifier le port 135 et le pare-feu |
| **1908** | Le DC n'a pas pu se connecter au partenaire | vérifier Tailscale, les routes et le DNS |
| **2087** | Échec de réplication DNS | vérifier la zone intégrée AD et les droits |
| **1256** | Le partenaire n'est pas joignable | vérifier la connectivité réseau |
| **8452** | Le nom du partenaire ne se résout pas | vérifier le suffixe DNS et les enregistrements |

Commandes utiles :

```powershell
repadmin /showrepl
repadmin /replsummary
repadmin /syncall /AdeP
dcdiag /test:replications /v
```

### 6.2. `SYSVOL` non partagé

```powershell
net share
Get-Service DFSR
dfsrmig /getmigrationstate
```

Attendre la réplication initiale (quelques minutes) et vérifier
`\\redone.local\SYSVOL`. Ne pas rétrograder l'ancien DC avant que `SYSVOL` soit
disponible sur le nouveau.

### 6.3. Erreur de temps (Kerberos)

```powershell
w32tm /query /status
w32tm /resync /force
```

Le DC qui détient le rôle PDC Emulator doit se synchroniser sur une source
fiable ; les autres DC se synchronisent sur lui.

---

## 7. DNS

### 7.1. `_msdcs` ne se résout pas

- Vérifier la zone `_msdcs.redone.local` et sa délégation.
- Vérifier que le DC Azure publie ses enregistrements SRV.
- Forcer l'enregistrement :

```powershell
ipconfig /registerdns
nltest /dsregdns
Restart-Service Netlogon
```

### 7.2. Enregistrement PTR manquant

Créer la zone inverse `1.3.10.in-addr.arpa` et le pointeur du DC Azure, ou
laisser le DC s'enregistrer dynamiquement.

---

## 8. FSMO et rétrogradation

### 8.1. `Move-ADDirectoryServerOperationMasterRole` échoue

- Vérifier que le DC cible est en ligne et répliqué.
- Vérifier que le compte est `Domain Admins` / `Enterprise Admins` (schéma).
- Vérifier les journaux `Directory Service`.
- Rappel : `05-transfer-fsmo.ps1` est en **mode vérification par défaut** ; le
  transfert réel exige `-ExecuteTransfer`.

### 8.2. `Uninstall-ADDSDomainController` refuse

Le script `06` bloque si des rôles FSMO sont encore sur le serveur. C'est
volontaire. Transférer les rôles avec `05`, puis relancer.

> Par défaut, `06-demote-onprem-dc.ps1` s'exécute **en mode vérification** et
> ne modifie rien : la rétrogradation réelle exige `-ExecuteDemotion`. C'est
> volontaire, pour pouvoir rejouer la migration sans détruire le DC de
> référence.

### 8.3. Le DC a été rétrogradé mais les clients ne s'authentifient plus

- Vérifier que le DC Azure est joignable depuis les clients (VPN/Tailscale).
- Vérifier le DNS distribué par DHCP.
- Vérifier que le DC Azure est un Global Catalog.
- Tester : `nltest /dsgetdc:redone.local` depuis un client.

---

## 9. TrueNAS / SMB

| Erreur | Piste |
|---|---|
| `DNS update failed` | retirer la passerelle de la configuration TrueNAS, garder le DNS `10.2.41.10` |
| `Clock skew too great` | resynchroniser l'heure avec le DC |
| `Join is OK` mais partage inaccessible | vérifier le service SMB, les ACL et l'appartenance au domaine |
| Lecteur `Z:` absent | GPO : action **Update**, *Run in logged-on user's context* ; sinon `map-smb-shares.ps1` |

---

## 10. Nettoyage après incident

```bash
# Voir l'état du déploiement
az deployment group show -g rg-redone-adds-lab -n adds-phase2 -o json

# Lister les ressources
az resource list -g rg-redone-adds-lab -o table

# Supprimer un déploiement bloqué (ne supprime pas les ressources)
az deployment group delete -g rg-redone-adds-lab -n adds-phase2

# Supprimer tout le laboratoire
az group delete -g rg-redone-adds-lab --yes --no-wait
```

> En cas de doute, conserver les journaux et captures avant de supprimer : ils
> constituent des preuves pour le dossier et la soutenance.
