# Plan d'adressage IP - AP_1

## 1. Principes

- **Aucun chevauchement** entre le LAN Proxmox (`10.2.41.0/24`) et le VNet Azure
  (`10.3.0.0/16`).
- Les équipements d'infrastructure (DC, NAS, passerelle) sont en **IP fixe** en
  dehors de la plage DHCP.
- Les postes clients utilisent le **DHCP** de `SRV-AD`.
- Les adresses Tailscale (`100.64.0.0/10`) sont **fixées manuellement** dans la
  console Tailscale pour rester stables.

---

## 2. Site Proxmox - `10.2.41.0/24`

| Équipement | FQDN | IP | Masque | Passerelle | DNS | Attribution |
|---|---|---|---|---|---|---|
| Passerelle | `router.redone.local` | `10.2.41.1` | /24 | - | - | Fixe |
| `SRV-AD` (DC1) | `srv-ad.redone.local` | `10.2.41.10` | /24 | `10.2.41.1` | `10.2.41.10`, `10.2.41.11` | Fixe |
| `SRV-AD2` (DC2) | `srv-ad2.redone.local` | `10.2.41.11` | /24 | `10.2.41.1` | `10.2.41.10`, `10.2.41.11` | Fixe |
| `TRUENAS-01` | `truenas.redone.local` | `10.2.41.12` | /24 | `10.2.41.1` | `10.2.41.10` | Fixe |
| `CLIENT01-03` | - | `10.2.41.19` - `10.2.41.100` | /24 | `10.2.41.1` | `10.2.41.10`, `10.2.41.11` | DHCP (bail 8 j) |
| `userdebian` | `userdebian.redone.local` | DHCP | /24 | `10.2.41.1` | `10.2.41.10`, `10.2.41.11` | DHCP |

### Étendue DHCP existante

| Paramètre | Valeur |
|---|---|
| Étendue | `10.2.41.0/24` |
| Plage dynamique | `10.2.41.19` - `10.2.41.100` |
| Exclusions | `10.2.41.1`, `10.2.41.10`, `10.2.41.11`, `10.2.41.12` (hors plage) |
| Option 003 (routeur) | `10.2.41.1` |
| Option 006 (DNS) | `10.2.41.10`, `10.2.41.11` |
| Option 015 (domaine) | `redone.local` |
| Bail | 8 jours |

> Après migration, ajouter le DC Azure (`10.3.1.4` ou son IP Tailscale) comme
> **troisième** serveur DNS uniquement si les clients peuvent le joindre
> (VPN/Tailscale). Sinon, conserver les DNS locaux et laisser la réplication
> propager les zones.

---

## 3. Site Azure - VNet `10.3.0.0/16`

| Élément | Valeur | Commentaire |
|---|---|---|
| VNet | `vnet-redone-lab` | `10.3.0.0/16` |
| Sous-réseau AD | `snet-adds` | `10.3.1.0/24` |
| Sous-réseau passerelle (option) | `GatewaySubnet` | `10.3.255.0/27`, réservé Azure |
| DC Azure | `SRV-AD-AZ01` | `10.3.1.4` (fixe) |
| DNS de la NIC | `168.63.129.16` | DNS Azure pour Internet (bootstrap) |
| DNS de `redone.local` | NRPT -> `100.64.0.10` | règle créée par le script Tailscale |
| NSG | `nsg-adds-lab` | RDP + flux AD restreints |
| IP publique | `SRV-AD-AZ01-pip` | sortie Internet, pas de RDP entrant |
| Resource Group | `rg-redone-adds-lab` | à créer par le pipeline |

### Détail des plages

| Plage | Usage | Disponible |
|---|---|---|
| `10.3.0.0/16` | VNet complet | oui |
| `10.3.1.0/24` | `snet-adds` | oui |
| `10.3.255.0/27` | `GatewaySubnet` (si VPN) | oui |
| `10.3.0.0/24`, `10.3.2.0/23`, ... | réservés pour extensions futures | oui |

---

## 4. Réseau Tailscale - `100.64.0.0/10`

| Machine | IP Tailscale | Rôle |
|---|---|---|
| `SRV-AD` | `100.64.0.10` | DC on-prem, source de réplication |
| `SRV-AD2` | `100.64.0.11` | DC on-prem secondaire |
| `TRUENAS-01` | `100.64.0.12` | NAS (optionnel) |
| `SRV-AD-AZ01` | `100.64.0.4` | DC Azure |
| `CLIENT01-03` | `100.64.0.101` - `100.64.0.103` | postes distants (optionnel) |

> Les IP Tailscale sont attribuées par le plan de contrôle. Pour les figer :
> console Tailscale > **Machines** > sélectionner la machine > **Edit** >
> **IPv4 address** > saisir l'adresse > **Save**.

### ACL Tailscale recommandées

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:dc-onprem", "tag:dc-azure"],
      "dst": ["tag:dc-onprem:53,88,135,389,445,464,636,3268,3269,49152-65535",
              "tag:dc-azure:53,88,135,389,445,464,636,3268,3269,49152-65535"]
    },
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["tag:dc-azure:3389", "tag:dc-onprem:3389"]
    }
  ],
  "tagOwners": {
    "tag:dc-onprem": ["autogroup:admin"],
    "tag:dc-azure": ["autogroup:admin"]
  },
  "groups": {
    "group:admins": ["votre-compte@example.com"]
  }
}
```

> Adapter les tags et le groupe à votre tailnet. L'objectif est de ne pas
> autoriser tout le tailnet à parler à tous les DC.

---

## 5. Sites et services Active Directory

| Site AD | Sous-réseaux | DC rattachés |
|---|---|---|
| `Site-Proxmox` | `10.2.41.0/24` | `SRV-AD`, `SRV-AD2` |
| `Site-Azure` | `10.3.1.0/24`, `100.64.0.0/10` | `SRV-AD-AZ01` |

Créer ces sites avant la promotion du DC Azure pour éviter qu'il ne soit
rattaché au site par défaut.

---

## 6. DNS

| Serveur | Rôle | Écoute |
|---|---|---|
| `SRV-AD` | DNS intégré AD, primaire | `10.2.41.10:53` |
| `SRV-AD2` | DNS intégré AD, secondaire | `10.2.41.11:53` |
| `SRV-AD-AZ01` | DNS intégré AD, répliqué | `10.3.1.4:53`, `100.64.0.4:53` |

Zones :

- `redone.local` (zone directe intégrée AD) ;
- `41.2.10.in-addr.arpa` (zone inverse du LAN) ;
- `1.3.10.in-addr.arpa` (zone inverse Azure, à créer) ;
- `_msdcs.redone.local` (délégué automatiquement).

Vérifications :

```powershell
nslookup redone.local 10.2.41.10
nslookup srv-ad.redone.local 10.3.1.4
nslookup srv-ad-az01.redone.local 10.2.41.10
```

> Les enregistrements `A` et `SRV` doivent être visibles sur les deux sites.
> Si `_msdcs` ne se résout pas, la jonction et la réplication échouent.

### 6.1. Résolution DNS de la VM Azure (NRPT)

La VM Azure utilise deux sources DNS :

| Requête | Serveur DNS | Mécanisme |
|---|---|---|
| Internet (`pkgs.tailscale.com`, GitHub, Windows Update) | `168.63.129.16` | DNS de la plateforme Azure (NIC) |
| `redone.local` et `*.redone.local` | `100.64.0.10` puis `100.64.0.4` | règle NRPT |

Règle créée automatiquement par `01-setup-tailscale.ps1` :

```powershell
Add-DnsClientNrptRule -Namespace '.redone.local' `
    -NameServers '100.64.0.10' `
    -DisplayName 'AP1 - redone.local via Tailscale'
```

Après la promotion, `04-validate-replication.ps1` remplace `100.64.0.10` par
`100.64.0.4` (le DC Azure assure alors sa propre résolution DNS).

Vérification :

```powershell
Get-DnsClientNrptRule | Where-Object Namespace -contains '.redone.local'
Resolve-DnsName redone.local
Resolve-DnsName pkgs.tailscale.com
```

> Sans NRPT, une NIC Azure configurée directement avec `100.64.0.10` ne peut
> pas télécharger l'installateur Tailscale au premier démarrage (le DC on-prem
> n'est pas encore joignable). C'est le problème « poule et œuf » classique des
> architectures hybrides.

---

## 7. Plan de nommage

| Type | Convention | Exemple |
|---|---|---|
| DC on-prem | `SRV-AD`, `SRV-AD2` | existant |
| DC Azure | `SRV-AD-AZ01` | <= 15 caractères (NetBIOS) |
| Clients | `CLIENT01` ... | existant |
| Resource Group | `rg-redone-adds-<env>` | `rg-redone-adds-lab` |
| VNet | `vnet-<projet>-<env>` | `vnet-redone-lab` |
| NSG | `nsg-adds-<env>` | `nsg-adds-lab` |
| Key Vault | `kv-<uniqueString>` | `kv-a1b2c3d4e5f6g` |
| IP publique | `<vm>-pip` | `SRV-AD-AZ01-pip` |
| NIC | `<vm>-nic` | `SRV-AD-AZ01-nic` |

---

## 8. Contrôles avant déploiement

- [ ] `10.2.41.0/24` et `10.3.0.0/16` ne se chevauchent pas.
- [ ] `10.3.1.4` est libre dans `snet-adds`.
- [ ] `100.64.0.10` et `100.64.0.4` sont fixés dans Tailscale.
- [ ] Le DC on-prem répond sur son IP Tailscale (`tailscale ping 100.64.0.10`).
- [ ] La NIC Azure garde `168.63.129.16` pour Internet.
- [ ] La règle NRPT `*.redone.local` pointe vers `100.64.0.10`.
- [ ] `redone.local` se résout depuis la VM Azure après installation de Tailscale.
- [ ] Les sites AD `Site-Proxmox` et `Site-Azure` existent.
