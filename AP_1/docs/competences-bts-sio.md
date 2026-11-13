# Compétences BTS SIO SISR mobilisées - AP_1

## 1. Positionnement de l'AP

Cette activité professionnelle consiste à **migrer un service d'annuaire
critique** (Active Directory) d'un hyperviseur local (Proxmox) vers le cloud
Azure, en appliquant une démarche **DevOps / Infrastructure as Code**.

Elle combine :

- administration système (Windows Server, AD DS, DNS) ;
- administration réseau (VNet, NSG, VPN/Tailscale, DNS) ;
- sécurité (secrets, moindre privilège, filtrage) ;
- automatisation (Bicep, PowerShell, GitHub Actions) ;
- gestion de projet (Git, documentation, procédure de rollback).

---

## 2. Tableau de synthèse des compétences

| Bloc | Compétence | Mise en œuvre dans l'AP | Preuve / livrable |
|---|---|---|---|
| **B1.1** | Gérer le patrimoine informatique | inventaire des serveurs, plan d'adressage, choix de la cible Azure | `docs/plan-adressage-ip.md`, tableau de correspondance |
| **B1.2** | Répondre aux incidents et aux demandes d'assistance | diagnostic de réplication, DNS, jonction, journaux d'extensions | `docs/troubleshooting.md`, rapport `04-replication-report.txt` |
| **B1.3** | Développer la présence en ligne de l'organisation | non traitée dans cette AP (hors périmètre SISR) | - |
| **B1.4** | Travailler en mode projet | découpage en phases, versionnement Git, pipeline CI/CD, documentation | historique Git, workflows, runbook |
| **B1.5** | Mettre à disposition des utilisateurs un service informatique | AD DS, DNS, authentification, accès SMB TrueNAS | `Get-ADDomainController`, `repadmin`, partage `\\10.2.41.12\Partage` |
| **B1.6** | Organiser son développement professionnel | veille sur Bicep, Tailscale, bonnes pratiques AD | README, choix techniques justifiés |
| **B2.1** | Concevoir une solution d'infrastructure réseau | architecture hybride Proxmox/Azure, VNet, sous-réseaux, flux AD | `docs/architecture.md`, schéma Mermaid |
| **B2.2** | Installer, tester et déployer une solution d'infrastructure réseau | modules Bicep, extensions Azure, scripts PowerShell, pipeline | `main.bicep`, `extensions.bicep`, workflows |
| **B2.3** | Exploiter, dépanner et superviser une solution d'infrastructure réseau | `repadmin`, `dcdiag`, journaux, sites AD, transfert FSMO | scripts `04`, `05`, `06`, checklist |
| **B2.4** | Organiser l'accès aux services | comptes de domaine, groupes, ACL SMB, RDP restreint | NSG, GPO, doc TrueNAS |
| **B3.1** | Sécuriser les accès et les données | secrets hors du code, OIDC, NSG, Tailscale chiffré, Key Vault | `@secure()`, workflows, Key Vault |

> Les intitulés exacts peuvent varier selon la version du référentiel de votre
> établissement. L'important est de rattacher chaque action à une compétence
> identifiable et de fournir une **preuve** (capture, commande, fichier).

---

## 3. Détail des compétences techniques

### 3.1. Conception (B2.1)

- Choix d'un VNet `10.3.0.0/16` sans chevauchement avec le LAN `10.2.41.0/24`.
- Découpage `snet-adds` + `GatewaySubnet` optionnel.
- Choix de Tailscale plutôt qu'IPsec, justifié par le coût et la simplicité.
- Définition des sites AD (`Site-Proxmox`, `Site-Azure`) et des sous-réseaux
  associés.
- Matrice de flux et règles NSG.

**Preuves :** `docs/architecture.md`, `docs/plan-adressage-ip.md`,
`docs/matrice-flux-ports.md`, `bicep/modules/vnet.bicep`, `bicep/modules/nsg.bicep`.

### 3.2. Déploiement (B2.2)

- Écriture de modules Bicep réutilisables (`vnet`, `nsg`, `vm-adds`,
  `extensions`, `keyvault`).
- Paramétrage par `main.bicepparam`, secrets injectés par le pipeline.
- Déploiement d'une VM Windows Server 2022 Gen2, disque managé, IP fixe.
- Extensions Azure : Tailscale, jonction de domaine native, promotion AD DS.
- Pipeline GitHub Actions : `build`, `lint`, `what-if`, `deploy`.

**Preuves :** `bicep/`, `.github/workflows/`, résultat du pipeline, captures
du portail Azure.

### 3.3. Exploitation et supervision (B2.3)

- Vérification des services `NTDS`, `DNS`, `Netlogon`, `KDC`, `W32Time`.
- `repadmin /replsummary`, `repadmin /showrepl`, `dcdiag`.
- Contrôle des rôles FSMO.
- Vérification du partage `SYSVOL` / `NETLOGON`.
- Analyse des journaux d'extensions et de `dcpromo.log`.
- Procédure de transfert FSMO et de rétrogradation (toutes deux optionnelles,
  en mode vérification par défaut : `-ExecuteTransfer` / `-ExecuteDemotion`).

**Preuves :** scripts `04`, `05`, `06`, rapport texte, captures.

### 3.4. Sécurité (B3.1)

- Aucun secret dans Git (`.gitignore`, `@secure()`, GitHub Secrets).
- Authentification OIDC du pipeline (pas de clé JSON Azure).
- NSG : RDP non exposé à Internet, flux AD limités.
- Tailscale : tunnel WireGuard chiffré, ACL par tags.
- Key Vault optionnel avec purge protection.

**Preuves :** workflows, `keyvault.bicep`, règles NSG, ACL Tailscale.

---

## 4. Ce qui distingue cette AP d'un simple tutoriel

1. **Tout est versionné** : l'infrastructure n'est pas cliquée dans le portail,
   elle est décrite dans des fichiers relus et historisés.
2. **Le déploiement est reproductible** : un `git push` recrée l'environnement.
3. **La migration est sûre** : réplication native plutôt que copie de disque,
   continuité de service, procédure de rollback.
4. **La sécurité est traitée** : secrets, OIDC, NSG, moindre privilège.
5. **L'exploitation est documentée** : runbook, troubleshooting, checklist.

---

## 5. Questions possibles du jury et pistes de réponse

| Question | Piste de réponse |
|---|---|
| Pourquoi ne pas avoir converti la VM Proxmox en VHD ? | Risque d'USN Rollback, pilotes différents, incohérence des secrets machine. La réplication native est plus sûre. |
| Pourquoi Tailscale plutôt qu'un VPN site-à-site ? | Simplicité, NAT traversal, pas de passerelle VPN facturée. `deployVpnGateway=true` prépare le `GatewaySubnet` si un VPN IPsec doit être ajouté. |
| Où sont stockés les mots de passe ? | GitHub Secrets + paramètres `@secure()`, transmis chiffrés aux extensions. Option Key Vault pour l'audit. |
| Comment garantissez-vous la reprise ? | `SRV-AD2` reste en place, sauvegarde de l'état système, procédure de rollback, validation avant rétrogradation. |
| Que se passe-t-il si Azure tombe ? | Le site Proxmox continue d'assurer l'authentification ; le DC Azure est un DC additionnel. |
| Pourquoi les sites AD sont-ils importants ? | Ils déterminent la topologie de réplication, les coûts de lien et le DC le plus proche pour les clients. |
| Comment vérifiez-vous la réplication ? | `repadmin /replsummary`, `repadmin /showrepl`, `dcdiag`, contrôle de `SYSVOL`. |
| Le pipeline peut-il casser la production ? | `what-if` avant application, environnement protégé, revue de code, rollback documenté. En l'état, le pipeline déploie sur `main` : ajouter une approbation manuelle en production. |

---

## 6. Limites à assumer devant le jury

- Un seul DC dans Azure : ce n'est pas une haute disponibilité cloud complète.
- Le DHCP n'est pas migré.
- **Quota** : l'abonnement de démonstration limite le total de vCPU régionaux
  (typiquement 4), pas un nombre de VM. Le déploiement principal tient donc sur
  une seule VM ; le poste client est un client Linux léger ou le poste Proxmox
  existant (`README.md` §4.2).
- **Stockage** : `TRUENAS-01` n'est pas migré ; Azure Files est proposé mais
  hors périmètre (`README.md` §4.3).
- **Cloud natif** : la bascule vers Entra ID + Intune est une perspective
  documentée, non déployée (`README.md` §3.4).
- Les scripts d'extension sont téléchargés depuis GitHub : dépôt public ou
  stockage avec SAS nécessaire.
- Le pipeline applique automatiquement sur `main` : acceptable en laboratoire,
  à renforcer en production (approbation, tests, `what-if` obligatoire).
- Tailscale est un choix pragmatique pour l'AP ; en entreprise, un VPN IPsec ou
  ExpressRoute serait privilégié pour un réseau hybride permanent.

---

## 7. Portfolio / captures à préparer

- [ ] `git log --oneline` montrant les commits.
- [ ] Workflow GitHub Actions vert (`validate` et `deploy`).
- [ ] Résultat du `what-if`.
- [ ] Portail Azure : resource group, VNet, NSG, VM, extensions.
- [ ] `tailscale status` sur les deux DC.
- [ ] `Get-ADDomainController -Filter *`.
- [ ] `repadmin /replsummary` avec 0 échec.
- [ ] `dcdiag` (extrait).
- [ ] Sites AD et sous-réseaux.
- [ ] Transfert FSMO : **optionnel** (mode vérification par défaut,
  `-ExecuteTransfer` pour l'action réelle) — captures du mode vérification
  suffisantes si la démonstration doit rester rejouable.
- [ ] Rétrogradation de `SRV-AD` : **optionnelle** (mode vérification par
  défaut, `-ExecuteDemotion` pour l'action réelle) — captures du mode
  vérification suffisantes si la démonstration doit rester rejouable.
- [ ] Partage SMB TrueNAS accessible.
- [ ] Rapport `04-replication-report.txt`.
