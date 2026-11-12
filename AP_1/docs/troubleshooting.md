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

### 2.2. `AADSTS70021: No matching federated identity record found`

Le sujet OIDC ne correspond pas. Vérifier :

- le nom de l'environnement GitHub (`azure-lab`) ;
- le sujet exact : `repo:<owner>/<repo>:environment:azure-lab` ;
- l'audience : `api://AzureADTokenExchange`.

Lister les fédérations :

```bash
az ad app federated-credential list --id "$APP_ID" -o table
```

### 2.3. `AuthorizationFailed` / `The client does not have authorization`

Le service principal n'a pas le rôle sur le resource group. Vérifier :

```bash
az role assignment list --assignee "$APP_ID" --all -o table
```

Le rôle `Contributor` sur `rg-redone-adds-lab` est suffisant pour ce livrable.

### 2.4. `QuotaExceeded` / `SkuNotAvailable`

- Changer de région (`westeurope` → `francecentral`) ou de taille
  (`Standard_B2ms` → `Standard_B2s`).
- Penser à supprimer les VM orphelines : un abonnement gratuit est typiquement
  limité à **4 vCPU régionaux**, pas à un nombre de VM (`README.md` §4.2).
- Vérifier les quotas :

```bash
az vm list-usage --location westeurope -o table
```

### 2.5. `InvalidParameter: adminPassword`

Le mot de passe ne respecte pas la complexité Windows Server :

- 12 caractères minimum (le paramètre Bicep impose `minLength(12)`) ;
- majuscule, minuscule, chiffre et caractère spécial ;
- ne pas utiliser un mot de passe déjà utilisé dans un ancien document.

### 2.6. L'extension télécharge un script en 404

- Vérifier que le dépôt est **public** ou que l'URL brute est accessible.
- Tester l'URL dans un navigateur :

```text
https://raw.githubusercontent.com/thibaut-huet/AP-BTS-SIO-SISR-V2/main/AP_1/scripts/azure-dc/01-setup-tailscale.ps1
```

- Vérifier `repositoryRawBaseUrl` et `scriptsBasePath` passés au déploiement.
- Si le fichier a été ajouté après le déploiement, relancer le déploiement ou
  l'extension.

### 2.7. `The extension operation timed out`

- La promotion AD peut dépasser le délai de l'extension à cause du redémarrage.
- Vérifier `Get-Service NTDS` : si le service tourne, la promotion a réussi.
- Relancer uniquement si nécessaire :

```bash
az vm extension delete -g rg-redone-adds-lab --vm-name SRV-AD-AZ01 -n 03-PromoteDC
# puis relancer le déploiement
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

### 8.2. `Uninstall-ADDSDomainController` refuse

Le script `06` bloque si des rôles FSMO sont encore sur le serveur. C'est
volontaire. Transférer les rôles avec `05`, puis relancer.

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
