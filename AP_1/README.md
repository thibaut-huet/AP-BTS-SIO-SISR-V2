# AP_1 - Migration de l'Active Directory RedOne vers Azure

**Auteur :** Thibaut HUET
**Contexte :** BTS SIO option SISR - Atelier Professionnel
**Entreprise :** RedOne (infrastructure type GSB)
**Domaine :** `redone.local`
**Environnement existant :** Proxmox VE
**Cible :** Microsoft Azure, déployée en Infrastructure as Code (Bicep) via un pipeline GitHub Actions

---

## 1. Objectif du projet

L'entreprise RedOne dispose aujourd'hui d'une infrastructure Active Directory
hébergée sur Proxmox :

- `SRV-AD` (`10.2.41.10`) : contrôleur de domaine principal, DNS, DHCP, rôles FSMO ;
- `SRV-AD2` (`10.2.41.11`) : contrôleur de domaine secondaire, DNS ;
- `TRUENAS-01` (`10.2.41.12`) : stockage ZFS et partage SMB intégré au domaine ;
- `CLIENT01` à `CLIENT03` : postes clients joints au domaine ;
- `userdebian` : poste client Linux de test.

L'AP consiste à **migrer l'Active Directory vers Azure** en respectant une
démarche **DevOps / Infrastructure as Code** :

1. décrire toute l'infrastructure Azure dans du code **Bicep** versionné ;
2. automatiser le déploiement via **GitHub Actions** (CI/CD) ;
3. déployer un **nouveau contrôleur de domaine** Windows Server 2022 dans Azure ;
4. le raccorder au domaine existant via **Tailscale** (WireGuard) ;
5. laisser la **réplication native Active Directory** synchroniser utilisateurs,
   groupes, mots de passe (hachés), GPO et DNS ;
6. transférer les rôles **FSMO** puis **rétrograder** proprement le DC Proxmox.

> **Point clé :** on ne migre pas le disque de la VM Proxmox (`.qcow2`/`.vmdk`)
> vers Azure. Le « lift-and-shift » d'un contrôleur de domaine est dangereux
> (risque d'**USN Rollback** et de corruption de la base `NTDS.dit`).
> On déploie une VM **neuve** et on utilise la **réplication AD native**.

> **Pourquoi garder AD DS ?** Le scénario, les cas réels où cette migration
> reste pertinente et la perspective d'évolution vers Entra ID / Intune sont
> argumentés au [§3](#3-pourquoi-migrer-ad-ds-et-pas-entra-id--intune). Le
> périmètre, les contraintes de quota de l'abonnement et la proposition de
> migration du stockage TrueNAS vers Azure Files sont détaillés au
> [§4](#4-périmètre-du-déploiement-et-contraintes-de-quota).

---

## 2. Ce que démontre ce livrable

| Axe | Mise en œuvre |
|---|---|
| **Infrastructure as Code** | Modules Bicep : VNet, NSG, NIC, VM, extensions, Key Vault |
| **CI/CD** | GitHub Actions : validation (`bicep build`/`lint`), `what-if`, déploiement |
| **Sécurité** | Secrets GitHub + paramètres `@secure()`, OIDC (pas de clé Azure stockée), NSG, aucune exposition RDP publique |
| **Réseau hybride** | Tailscale (WireGuard) entre Proxmox et Azure ; `GatewaySubnet` prévu pour ajouter une passerelle VPN IPsec |
| **Administration système** | Windows Server 2022, AD DS, DNS, promotion de DC, sites et services AD |
| **Migration** | Réplication AD, transfert FSMO, rétrogradation propre, validation `repadmin` / `dcdiag` |
| **Exploitation** | Scripts de validation, matrice de flux, plan d'adressage, procédure de rollback |

---

## 3. Pourquoi migrer AD DS et pas Entra ID / Intune ?

Le titre de l'AP est assumé : **« migration de l'Active Directory »**. Il ne
prétend pas qu'héberger un contrôleur de domaine dans une VM Azure soit la
cible moderne d'une PME. Pour une entreprise sans dette technique, la cible
serait plutôt **Entra ID + Intune** : annuaire en SaaS, postes administrés
depuis le cloud, aucun serveur à patcher. Ce n'est pas le scénario de RedOne,
et le choix est argumenté ci-dessous.

### 3.1. Les trois cibles possibles

| Critère | Entra ID + Intune | Entra Domain Services | **AD DS sur VM Azure (retenu)** |
|---|---|---|---|
| Nature de l'annuaire | SaaS Microsoft | AD managé par Microsoft | auto-administré |
| Jonction des postes | Entra Join | Entra DS Join | jonction de domaine classique |
| Stratégies de groupe | remplacées par Intune | partielles, peu éditables | GPO complètes |
| LDAP / Kerberos / NTLM | non (ou très limité) | oui | oui |
| Authentification des partages SMB | via Entra Kerberos / Azure Files | oui | oui |
| FSMO, schéma, sites AD | non | non | oui |
| Coût mensuel | faible, par utilisateur | moyen | **élevé (VM allumée 24/7)** |
| Compétences démontrées | identité / cloud | administration déléguée | **infra réseau, AD DS, DNS, exploitation** |

> Entra Domain Services est un bon compromis « AD managé », mais il ne permet
> ni l'extension de schéma, ni l'accès administrateur au contrôleur de domaine,
> ni la gestion des rôles FSMO. Il ne permettrait donc pas de démontrer les
> compétences SISR visées ici.

### 3.2. Cas réels où l'on migre encore un AD vers une VM Azure

Le DC en IaaS n'est pas un choix « moderne », c'est un choix **contraint**. On
le rencontre encore dans les situations suivantes :

- **sortie de datacenter** : on ferme la salle serveur sans réécrire les
  applications métier ;
- **applications legacy** : bind LDAP, Kerberos ou NTLM d'un logiciel éditeur
  qui ne connaît pas l'authentification cloud ;
- **parc sous GPO** : stratégies nombreuses ou très fines qu'Intune ne couvre
  pas à l'identique ;
- **serveurs de fichiers SMB** : les partages authentifiés en Kerberos
  dépendent d'AD DS ;
- **reprise d'activité** : un DC dans Azure sert de site de secours
  opérationnel en cas de sinistre sur le site principal ;
- **fusion / acquisition** : coexistence de plusieurs annuaires le temps de
  l'intégration.

### 3.3. Pourquoi c'est pertinent pour RedOne

- le NAS `TRUENAS-01` expose des partages **SMB joints au domaine** :
  supprimer AD DS casserait l'authentification des partages ;
- le parc client est **joint au domaine** et piloté par **GPO** ;
- `DHCP` et `DNS` sont intégrés à l'annuaire sur le site Proxmox ;
- l'objectif de l'AP est de démontrer des compétences **SISR cœur**
  (réplication, DNS, sites AD, FSMO, flux Kerberos/RPC/LDAP), que
  l'administration d'un annuaire SaaS ne permettrait pas d'évaluer.

### 3.4. Perspective : bascule vers Entra ID (non déployée)

La cible à moyen terme reste le cloud natif. La trajectoire envisagée, hors
périmètre de cet AP, serait :

1. **Entra Connect** : synchronisation hybride AD DS → Entra ID ;
2. **Intune** : prise en charge des postes, remplacement progressif des GPO ;
3. **Azure Files** avec authentification AD DS, puis Entra Kerberos, pour les
   partages SMB (voir §4.3) ;
4. **Entra Domain Services** pour les applications legacy à bind LDAP ;
5. **décommissionnement d'AD DS** une fois les dépendances legacy éteintes.

Les critères de déclenchement sont simples : disparition des applications liées
à Kerberos/LDAP, couverture Intune suffisante des GPO, et arbitrage de coût
entre une VM de DC allumée 24/7 et des licences par utilisateur.

---

## 4. Périmètre du déploiement et contraintes de quota

Le périmètre est **volontairement restreint** : l'abonnement utilisé pour l'AP
est un abonnement gratuit / étudiant, avec des quotas de ressources limités.

### 4.1. Dans le périmètre / hors périmètre

| Élément | Statut | Justification |
|---|---|---|
| DC additionnel dans Azure (`SRV-AD-AZ01`) | **déployé** | service critique, cœur de l'AP |
| Réplication AD, DNS, SYSVOL | **déployé** | continuité de service |
| Transfert FSMO et rétrogradation | **documenté, manuel** | opérations sensibles, hors pipeline |
| Poste client dans Azure | **limité** (voir §4.2) | contrainte de quota et d'image |
| `TRUENAS-01` → Azure Files | **proposé, non déployé** | voir §4.3 |
| `DHCP` | **hors périmètre** | le DHCP Azure imposerait un VPN site-à-site |
| Second DC Azure (zone de disponibilité) | **hors périmètre** | quota insuffisant |

### 4.2. Quota d'un abonnement gratuit et nombre de VM

Point important : Azure ne limite pas directement un **nombre de VM**, il
limite le **total de vCPU par région** (`Total Regional vCPUs`). Un abonnement
gratuit / étudiant est typiquement plafonné à **4 vCPU par région** (à vérifier
avec la commande ci-dessous, les valeurs varient selon l'offre).

Conséquence concrète : on ne raisonne pas en « nombre de VM » mais en
**budget de vCPU**.

| Combinaison possible sous 4 vCPU | Total | Remarque |
|---|---|---|
| 1 × `Standard_B2ms` (2 vCPU / 8 Go) | 2 / 4 | configuration actuelle : confortable |
| `B2ms` + 1 client Linux `B1s` (1 vCPU) | 3 / 4 | laisse 1 vCPU de marge |
| `B2ms` + 1 client Windows `B2s` (2 vCPU) | 4 / 4 | pile le quota, aucune marge |
| 4 × `B1s` (1 vCPU) | 4 / 4 | mais 1 Go de RAM : insuffisant pour un DC |

Deux pièges à connaître pour le poste client :

- **les images Windows client (10/11)** ne sont pas disponibles sur toutes les
  offres (souvent réservées aux abonnements dev/test type Visual Studio). À
  vérifier **avant** de concevoir le module ;
- à 2 + 2 vCPU, un déploiement échoué qui laisse une VM orpheline bloque le
  suivant (`QuotaExceeded`). Il faut alors nettoyer le resource group.

Vérifier le quota avant tout déploiement :

```bash
az vm list-usage --location westeurope -o table | grep -i "Total Regional"
```

Stratégie retenue pour tenir dans le quota :

- **une seule VM Azure** dans le déploiement principal (le DC) ;
- le client de démonstration est soit un **client Linux `B1s`**, soit le poste
  **déjà existant sur Proxmox**, joint au domaine et authentifié via Tailscale ;
- en cas de besoin, libérer le quota avec `az vm deallocate` puis
  `az group delete` (voir §12).

### 4.3. Proposition : remplacer TrueNAS par Azure Files (hors périmètre)

`TRUENAS-01` reste sur Proxmox dans cet AP. Une migration du stockage est
cependant **étudiée** comme suite logique de la sortie de datacenter.

| Service Azure | Pertinence comme remplaçant de TrueNAS | Commentaire |
|---|---|---|
| **Azure Files** | **oui, choix proposé** | SMB natif, ACL NTFS, authentification AD DS, snapshots de partage, quotas |
| Azure NetApp Files | oui, mais coûteux | SMB + NFS, performances proches du SAN ; inscription de fournisseur et budget réel |
| Managed Disks | non | disques bruts, pas de partage réseau |
| Blob Storage | non | stockage objet, pas de SMB ni d'ACL Windows |

Ce que la bascule vers Azure Files **ne restitue pas** :

- RAIDZ / miroirs ZFS → remplacés par la redondance Azure (**LRS** ou **ZRS**) ;
- snapshots ZFS → **snapshots de partage** Azure Files ;
- réplication ZFS → **Azure File Sync** ou redondance géographique ;
- iSCSI → pas d'équivalent simple (Azure NetApp Files) ;
- réglages fins ZFS (compression, dedup, ARC) → non exposés.

Prérequis techniques : le compte de stockage doit être **joint à AD DS**, le
client doit joindre un contrôleur de domaine et le **port 445** doit passer
(chez RedOne : via le tunnel Tailscale).

Coût indicatif : quelques euros par mois pour un partage standard de 100 Go,
hors transactions — à comparer au coût d'un serveur NAS à maintenir.

Statut : **proposition documentée, non déployée**, à la fois par contrainte de
quota et pour ne pas élargir le périmètre de l'AP.

---

## 5. Architecture cible

```mermaid
flowchart LR
    subgraph PROXMOX["Site Proxmox - 10.2.41.0/24"]
        SRVAD["SRV-AD<br/>10.2.41.10<br/>DC1 / DNS / DHCP / FSMO"]
        SRVAD2["SRV-AD2<br/>10.2.41.11<br/>DC2 / DNS"]
        NAS["TRUENAS-01<br/>10.2.41.12<br/>SMB / ZFS"]
        CLIENTS["CLIENT01-03<br/>DHCP 10.2.41.19-100"]
    end

    subgraph TAILNET["Tailnet 100.64.0.0/10"]
        TS1["SRV-AD<br/>100.64.0.10"]
        TS2["SRV-AD-AZ01<br/>100.64.0.4"]
    end

    subgraph AZURE["Azure - 10.3.0.0/16"]
        VNET["VNet vnet-redone-lab<br/>snet-adds 10.3.1.0/24"]
        NSG["NSG nsg-adds-lab<br/>RDP + flux AD restreints"]
        DCAZ["SRV-AD-AZ01<br/>10.3.1.4<br/>DC3 / DNS"]
    end

    SRVAD <-->|"Réplication AD<br/>Kerberos / RPC / LDAP"| DCAZ
    SRVAD --- TS1
    DCAZ --- TS2
    TS1 <-->|"Tunnel WireGuard"| TS2
    NAS --> CLIENTS
    CLIENTS -.->|"Authentification"| SRVAD
    VNET --- NSG
    NSG --- DCAZ
```

Légende :

- **DC1 / DC2** : contrôleurs de domaine existants sur Proxmox.
- **DC3** : contrôleur de domaine **additionnel** dans Azure (le terme exact est
  « additional domain controller » ; AD fonctionne en réplication multimaître).
- **Tailscale** : réseau privé overlay WireGuard. Il remplace un tunnel IPsec
  site-à-site pour cet atelier : pas de passerelle VPN Azure facturée à l'heure,
  traversée de NAT automatique, chiffrement de bout en bout.
- **NSG** : filtre les flux entrants. L'accès RDP n'est pas exposé à Internet.

---

## 6. Correspondance avec l'infrastructure existante

| Élément | Existant (Proxmox) | Cible (Azure) |
|---|---|---|
| Domaine | `redone.local` | identique (réplication) |
| DC principal | `SRV-AD` - `10.2.41.10` | conservé pendant la migration |
| DC secondaire | `SRV-AD2` - `10.2.41.11` | conservé |
| Nouveau DC | - | `SRV-AD-AZ01` - `10.3.1.4` |
| DNS | `10.2.41.10`, `10.2.41.11` | `SRV-AD-AZ01` + DNS intégré AD |
| DHCP | `SRV-AD` | conservé (hors périmètre Azure) |
| Stockage | `TRUENAS-01` - `10.2.41.12` | conservé (SMB joint au domaine) |
| Clients | `CLIENT01-03`, `userdebian` | conservés |
| Interconnexion | LAN Proxmox | Tailscale / VPN IPsec (option) |

> Le plan d'adressage complet est dans [`docs/plan-adressage-ip.md`](docs/plan-adressage-ip.md).

---

## 7. Structure du dépôt

```text
AP_1/
├── .github/
│   └── workflows/
│       ├── validate.yml              # bicep build + lint (version autonome)
│       └── deploy-infra.yml          # what-if / deploiement (version autonome)
│
├── bicep/
│   ├── main.bicep                    # orchestrateur principal
│   ├── main.bicepparam               # parametres NON sensibles
│   └── modules/
│       ├── vnet.bicep                # VNet, snet-adds, GatewaySubnet optionnel
│       ├── nsg.bicep                 # regles RDP + replication AD
│       ├── vm-adds.bicep             # NIC IP fixe + VM Windows Server 2022
│       ├── extensions.bicep          # Tailscale -> jonction -> promotion AD
│       └── keyvault.bicep            # coffre de secrets optionnel
│
├── scripts/
│   ├── azure-dc/
│   │   ├── 01-setup-tailscale.ps1    # installation + connexion Tailscale
│   │   ├── 02-join-domain.ps1        # jonction manuelle de secours
│   │   ├── 03-promote-dc.ps1         # promotion en DC additionnel
│   │   ├── 04-validate-replication.ps1
│   │   ├── 05-transfer-fsmo.ps1      # transfert des 5 roles FSMO
│   │   └── 06-demote-onprem-dc.ps1   # retrogradation du DC Proxmox
│   ├── truenas/
│   │   ├── join-domain-truenas.md    # procedure de jonction TrueNAS
│   │   └── map-smb-shares.ps1        # mappage de secours du lecteur Z:
│   └── clients/
│       ├── join-domain-client.ps1    # jonction des postes clients
│       └── setup-tailscale-client.ps1
│
├── docs/
│   ├── architecture.md               # choix techniques et flux
│   ├── plan-adressage-ip.md          # plan d'adressage complet
│   ├── matrice-flux-ports.md         # ports AD / Azure / Tailscale
│   ├── procedure-deploiement.md      # runbook pas a pas
│   ├── competences-bts-sio.md        # tableau de competences SISR
│   └── troubleshooting.md            # erreurs courantes et resolutions
│
├── .gitignore
└── README.md
```

> **Important - emplacement des workflows**
> GitHub Actions ne lit que le dossier `.github/workflows/` **à la racine du
> dépôt**. Ce livrable contient donc deux copies :
> - `AP_1/.github/workflows/` : version autonome, si `AP_1` devient un dépôt dédié ;
> - `.github/workflows/ap1-*.yml` à la racine du dépôt `AP-BTS-SIO-SISR-V2` :
>   version **active** dans le dépôt actuel, avec les chemins préfixés `AP_1/`.

---

## 8. Prérequis

| Prérequis | Détail |
|---|---|
| Abonnement Azure | droits `Contributor` sur le resource group |
| Azure CLI | version 2.50+ (support `.bicepparam`) |
| Bicep CLI | installé par `az bicep install` |
| Tailscale | compte gratuit, agents sur `SRV-AD` et `SRV-AD-AZ01` |
| Proxmox | `SRV-AD` opérationnel, DNS et réplication fonctionnels |
| GitHub | dépôt, droits sur les secrets et variables, environnement `azure-lab` |
| Réseau | le DC Proxmox doit pouvoir joindre Internet pour Tailscale |

> **Ne pas exposer les contrôleurs de domaine directement sur Internet.**
> Tailscale crée un tunnel chiffré ; les flux AD ne transitent jamais en clair.

---

## 9. Mise en route rapide

### 9.1. Préparer Tailscale

1. Installer Tailscale sur `SRV-AD` et noter son IP `100.x.y.z`.
2. Dans la console Tailscale, fixer une **IP statique** pour `SRV-AD`
   (`100.64.0.10` dans ce livrable) et pour `SRV-AD-AZ01` (`100.64.0.4`).
3. Créer une clé d'authentification (`tskey-auth-...`) et la stocker dans
   GitHub Secrets `TAILSCALE_AUTH_KEY`.
4. Vérifier depuis `SRV-AD` : `tailscale status` et `tailscale ip -4`.

### 9.2. Configurer Azure et GitHub

Créer une app registration Azure avec fédération OIDC, puis renseigner :

**Variables GitHub** (`Settings > Secrets and variables > Actions > Variables`) :

| Variable | Exemple |
|---|---|
| `AZURE_CLIENT_ID` | `00000000-0000-0000-0000-000000000000` |
| `AZURE_TENANT_ID` | `00000000-0000-0000-0000-000000000000` |
| `AZURE_SUBSCRIPTION_ID` | `00000000-0000-0000-0000-000000000000` |
| `AZURE_RESOURCE_GROUP` | `rg-redone-adds-lab` |
| `AZURE_LOCATION` | `westeurope` |

**Secrets GitHub** :

| Secret | Contenu |
|---|---|
| `VM_ADMIN_PASSWORD` | mot de passe admin local de la VM Azure |
| `DOMAIN_JOIN_PASSWORD` | mot de passe de `REDONE\Administrateur` |
| `DSRM_PASSWORD` | mot de passe du mode restauration AD |
| `TAILSCALE_AUTH_KEY` | clé Tailscale |

La procédure détaillée (création de l'app registration, fédération OIDC,
moindre privilège) est dans [`docs/procedure-deploiement.md`](docs/procedure-deploiement.md).

### 9.3. Déployer

Option pipeline (recommandée) :

```text
GitHub > Actions > AP_1 - Deploy Azure AD Infrastructure > Run workflow
  action     = what-if   (puis deploy)
  promoteDc  = false     (phase 1 : VM + jonction uniquement)
```

> Un push sur `main` déploie la phase 1 (`promoteDc=false`). La promotion en
> contrôleur de domaine (phase 2) se fait uniquement via un lancement manuel
> avec `promoteDc=true`.

Option CLI :

```bash
export VM_ADMIN_PASSWORD='<mot de passe admin VM>'
export DOMAIN_JOIN_PASSWORD='<mot de passe REDONE\Administrateur>'
export DSRM_PASSWORD='<mot de passe DSRM>'
export TAILSCALE_AUTH_KEY='tskey-auth-...'

az group create --name rg-redone-adds-lab --location westeurope

az deployment group create \
  --resource-group rg-redone-adds-lab \
  --parameters AP_1/bicep/main.bicepparam
```

> `main.bicepparam` lit les secrets via `readEnvironmentVariable()` : aucun
> secret n'apparaît dans la ligne de commande ni dans le fichier de paramètres.

### 9.4. Valider

Sur `SRV-AD-AZ01` (via Tailscale/RDP) :

```powershell
Get-Service NTDS, DNS, Netlogon, KDC
Get-ADDomainController -Filter *
repadmin /replsummary
dcdiag /test:replications /test:advertising /test:dns
```

Résultat attendu : `repadmin` affiche **0 échec** et les deux ou trois DC
apparaissent. Le script `scripts/azure-dc/04-validate-replication.ps1` produit
un rapport complet.

### 9.5. Basculer (si l'objectif est de couper Proxmox)

1. Transférer les rôles FSMO : `scripts/azure-dc/05-transfer-fsmo.ps1`.
2. Vérifier de nouveau la réplication et le partage `SYSVOL`.
3. Rétrograder `SRV-AD` : `scripts/azure-dc/06-demote-onprem-dc.ps1`.
4. Ajuster DHCP/DNS des clients pour pointer vers le DC Azure.

> Ne jamais rétrograder un DC avant d'avoir vérifié que les rôles FSMO et
> `SYSVOL` sont bien répliqués sur le DC Azure.

---

## 10. Sécurité et gestion des secrets

- Aucun mot de passe n'est présent dans `main.bicep`, `main.bicepparam` ou le dépôt.
- Les paramètres sensibles sont marqués `@secure()` et injectés par GitHub Secrets.
- L'extension Azure transmet les secrets via `protectedSettings` (chiffrés,
  non journalisés).
- Le pipeline utilise **OIDC** : pas de `AZURE_CREDENTIALS` (clé JSON) stocké.
- Le NSG n'autorise pas RDP depuis Internet ; l'accès se fait par Tailscale.
- Le Key Vault est **optionnel** (`deployKeyVault=true`) : il conserve les
  secrets pour l'audit et la rotation. La VM, elle, reçoit ses secrets par le
  pipeline pour éviter le problème « poule et œuf » du plan de données.

> En production, ajouter : Azure Bastion ou Just-in-Time, Defender for Cloud,
> Azure Policy, sauvegarde du DC (Azure Backup), et un second DC Azure dans une
> zone de disponibilité différente.

---

## 11. Choix techniques et justifications

| Choix | Justification |
|---|---|
| **Bicep** plutôt que portail | reproductibilité, revue de code, historique Git, déploiement idempotent |
| **VM neuve + réplication** plutôt que conversion `.qcow2` | évite l'USN Rollback et les incohérences de base AD |
| **Tailscale** plutôt que VPN IPsec | simplicité, NAT traversal, coût nul côté Azure ; `deployVpnGateway=true` prépare le `GatewaySubnet` pour une passerelle IPsec |
| **Extension `JsonADDomainExtension`** | jonction gérée nativement par Azure, redémarrage pris en charge |
| **CustomScriptExtension** pour AD DS | automatise l'installation du rôle et la promotion |
| **DC additionnel** | continuité de service, réplication multimaître, pas de bascule brutale |
| **Sites et services AD** | maîtrise des flux de réplication entre Proxmox et Azure |
| **Aucun RDP entrant depuis Internet** | l'IP publique sert à la sortie ; le NSG filtre l'administration |

---

## 12. Coût et nettoyage

Ordre de grandeur (à vérifier sur le calculateur Azure) :

- `Standard_B2ms` : environ 60 à 70 €/mois si la VM reste allumée 24/7 ;
- disque `StandardSSD_LRS` 127 Go : quelques euros par mois ;
- IP publique Standard : quelques euros par mois ;
- Tailscale : offre gratuite suffisante pour l'AP ;
- pas de passerelle VPN Azure (économie d'environ 25 à 30 €/mois) ;
- Azure Files (proposition, non déployé) : quelques euros par mois pour un
  partage standard de 100 Go, hors transactions — voir §4.3.

**Pour arrêter les frais :**

```bash
# Desallouer la VM (les disques restent factures)
az vm deallocate -g rg-redone-adds-lab -n SRV-AD-AZ01

# Ou supprimer tout le resource group de test
az group delete --name rg-redone-adds-lab --yes --no-wait
```

> Attention : supprimer le resource group supprime la VM et son disque. En
> production, sauvegarder l'état système du DC avant toute suppression.

---

## 13. Limites connues / pistes d'amélioration

- Un seul DC dans Azure : pour une vraie haute disponibilité, en déployer un
  second dans une autre zone de disponibilité.
- Le quota de l'abonnement (4 vCPU régionaux) limite à **une seule VM** dans le
  déploiement principal ; le poste client est un client Linux léger ou le poste
  Proxmox existant (voir §4.2).
- Le DC Azure dépend de Tailscale pour joindre le DC on-prem pendant la migration.
- Les extensions Azure peuvent afficher un statut `failed` lorsque la VM
  redémarre pendant la promotion : c'est documenté dans
  [`docs/troubleshooting.md`](docs/troubleshooting.md).
- Le DHCP n'est pas migré dans cette AP (il reste sur `SRV-AD`), sauf si
  l'objectif est la fermeture complète du site Proxmox.
- `TRUENAS-01` n'est pas migré : la cible Azure Files est proposée et
  documentée, mais hors périmètre (voir §4.3).
- La cible cloud natif (Entra ID + Intune) n'est pas traitée : elle reste une
  perspective d'évolution (voir §3.4).
- La clé Tailscale utilisée doit être révoquée après le déploiement.

---

## 14. Compétences BTS SIO SISR mobilisées

Le détail est dans [`docs/competences-bts-sio.md`](docs/competences-bts-sio.md).
Synthèse :

- **B1.1** Gérer le patrimoine informatique (inventaire, plan d'adressage) ;
- **B1.2** Répondre aux incidents (réplication, DNS, dépannage) ;
- **B1.4** Travailler en mode projet (Git, pipeline, documentation) ;
- **B1.5** Mettre à disposition un service (AD DS, DNS, SMB) ;
- **B2.1** Concevoir une solution d'infrastructure (architecture hybride) ;
- **B2.2** Installer, tester et déployer (Bicep, extensions, PowerShell) ;
- **B2.3** Exploiter, dépanner et superviser (repadmin, dcdiag, journaux).

---

## 15. Documentation détaillée

| Document | Contenu |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | architecture, flux, choix, sécurité |
| [`docs/plan-adressage-ip.md`](docs/plan-adressage-ip.md) | plan IP on-prem / Azure / Tailscale |
| [`docs/matrice-flux-ports.md`](docs/matrice-flux-ports.md) | ports et règles NSG |
| [`docs/procedure-deploiement.md`](docs/procedure-deploiement.md) | runbook complet, OIDC, sites AD, FSMO |
| [`docs/competences-bts-sio.md`](docs/competences-bts-sio.md) | tableau de compétences pour le jury |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | erreurs fréquentes et résolutions |
| [`scripts/truenas/join-domain-truenas.md`](scripts/truenas/join-domain-truenas.md) | jonction TrueNAS au domaine |

---

## 16. Avertissement

Ce projet est un **laboratoire pédagogique**. Les mots de passe fournis dans les
anciens documents (`Serveur2022`) sont des mots de passe de maquette et ne
doivent jamais être réutilisés en production. Les secrets réels doivent être
générés aléatoirement, stockés dans un coffre et renouvelés.
