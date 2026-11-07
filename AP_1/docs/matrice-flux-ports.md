# Matrice des flux et des ports - AP_1

## 1. Objectif

Ce document recense les flux nécessaires au fonctionnement de la maquette :

- jonction de domaine et réplication Active Directory ;
- résolution DNS ;
- administration (RDP) ;
- accès au partage SMB TrueNAS ;
- téléchargement des extensions Azure et fonctionnement de Tailscale.

Il sert de référence pour le NSG Azure, le pare-feu Windows et, si besoin, le
pare-feu Proxmox.

---

## 2. Flux Active Directory

### 2.1. Client vers contrôleur de domaine

| Port | Protocole | Service | Usage |
|---|---|---|---|
| 53 | TCP + UDP | DNS | résolution du domaine, `_msdcs`, `_sites` |
| 88 | TCP + UDP | Kerberos | authentification |
| 123 | UDP | NTP | synchronisation horaire |
| 135 | TCP | RPC Endpoint Mapper | négociation RPC |
| 137-139 | TCP/UDP | NetBIOS | hérité, optionnel |
| 389 | TCP + UDP | LDAP | annuaire |
| 445 | TCP | SMB | GPO, SYSVOL, partages |
| 464 | TCP + UDP | Kerberos kpasswd | changement de mot de passe |
| 636 | TCP | LDAPS | LDAP chiffré |
| 3268 | TCP | Global Catalog | recherches globales |
| 3269 | TCP | Global Catalog SSL | recherches globales chiffrées |
| 49152-65535 | TCP | RPC dynamique | réplication, gestion |

### 2.2. DC vers DC (réplication)

Les contrôleurs de domaine utilisent les mêmes ports, avec en plus :

| Port | Protocole | Usage |
|---|---|---|
| 135 | TCP | RPC Endpoint Mapper |
| 445 | TCP | réplication SYSVOL / fichiers |
| 49152-65535 | TCP | RPC dynamique |
| 53 | TCP/UDP | réplication DNS intégrée |
| 88, 389, 636, 3268, 3269 | TCP | Kerberos / LDAP / GC |
| 123 | UDP | synchronisation horaire |

> **RPC dynamique** : la plage `49152-65535` est large. En production, il est
> recommandé de la restreindre via la clé de registre
> `HKLM\SOFTWARE\Microsoft\Rpc\Internet` et de limiter les ports côté pare-feu.
> Pour l'AP, la plage complète est autorisée entre les DC uniquement.

---

## 3. Flux d'administration et de gestion

| Source | Destination | Port | Justification |
|---|---|---|---|
| Admin (Tailscale) | `SRV-AD-AZ01` | 3389/TCP | RDP |
| Admin (Tailscale) | `SRV-AD` | 3389/TCP | RDP (si besoin) |
| Azure platform | `SRV-AD-AZ01` | 443/TCP | agent invité, extensions |
| `SRV-AD-AZ01` | Internet | 443/TCP | GitHub raw, Windows Update, Tailscale |
| `SRV-AD-AZ01` | Tailscale | 41641/UDP | NAT traversal WireGuard |
| `SRV-AD-AZ01` | Tailscale | 443/TCP | plan de contrôle / DERP |
| Clients | `TRUENAS-01` | 445/TCP | partage SMB |
| Clients | `SRV-AD` / `SRV-AD-AZ01` | 53, 88, 389, 445, 636 | authentification + GPO |

> Le trafic Tailscale est **initié en sortie** par la VM. Aucun port entrant
> spécifique n'est nécessaire sur le NSG pour Tailscale. Les paquets AD
> circulent ensuite dans l'interface Tailscale de la VM (overlay), pas dans
> l'interface Azure.

---

## 4. Correspondance avec le NSG `nsg-adds-lab`

| Règle NSG | Priorité | Direction | Protocole | Source | Ports destination |
|---|---|---|---|---|---|
| `Allow-RDP-Admin` | 100 | Inbound | TCP | `10.2.41.0/24`, `100.64.0.0/10` | 3389 |
| `Allow-AD-Replication-TCP` | 110 | Inbound | TCP | `10.2.41.0/24`, `100.64.0.0/10` | 53, 88, 135, 139, 389, 445, 464, 636, 3268, 3269, 49152-65535 |
| `Allow-AD-Replication-UDP` | 111 | Inbound | UDP | `10.2.41.0/24`, `100.64.0.0/10` | 53, 88, 123, 389, 464 |
| `Allow-ICMP-Diagnostics` | 120 | Inbound | ICMP | `10.2.41.0/24`, `100.64.0.0/10` | * |

Les règles par défaut Azure (`AllowVnetInBound`,
`AllowAzureLoadBalancerInBound`, `DenyAllInBound`) restent actives. Aucune
règle n'autorise RDP depuis `Internet`.

> Les préfixes `10.2.41.0/24` et `100.64.0.0/10` sont paramétrables dans
> `main.bicep` (`allowedAdminSourcePrefixes`, `allowedOnPremSourcePrefixes`).

---

## 5. Pare-feu Windows Server (DC Azure)

Le profil **Domain** est actif après la jonction. Les règles intégrées
« Active Directory Domain Controller » ouvrent les ports nécessaires. Vérifier :

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled
Get-NetFirewallRule -DisplayGroup 'Active Directory Domain Controller - *' |
    Select-Object DisplayName, Enabled, Direction, Action
```

Si un flux est bloqué, créer une règle explicite **limitée aux sous-réseaux**
concernés :

```powershell
New-NetFirewallRule -DisplayName 'AD Replication - Proxmox Tailscale' `
    -Direction Inbound -Protocol TCP -LocalPort 53,88,135,389,445,464,636,3268,3269 `
    -RemoteAddress 100.64.0.10,10.2.41.0/24 -Action Allow -Profile Domain
```

> Ne pas désactiver le pare-feu Windows pour « faire marcher » la réplication.
> Ouvrir uniquement les flux nécessaires est une compétence attendue en SISR.

---

## 6. Flux TrueNAS / SMB

| Source | Destination | Port | Usage |
|---|---|---|---|
| Clients | `TRUENAS-01` (`10.2.41.12`) | 445/TCP | partage `\\10.2.41.12\Partage` |
| `TRUENAS-01` | `SRV-AD` | 53, 88, 389, 445, 464, 636 | jonction AD, Kerberos, LDAP |
| `TRUENAS-01` | DC (NTP) | 123/UDP | synchronisation horaire |

En cas d'accès distant, installer Tailscale sur TrueNAS ou exposer le NAS via
un subnet router approuvé.

---

## 7. Tests de connectivité

Depuis la VM Azure :

```powershell
# Tailscale
tailscale status
tailscale ping 100.64.0.10

# DNS
Resolve-DnsName redone.local
Resolve-DnsName _ldap._tcp.dc._msdcs.redone.local -Type SRV

# Jonction / DC
nltest /dsgetdc:redone.local
nltest /sc_verify:redone.local

# Réplication
repadmin /replsummary
repadmin /showrepl
dcdiag /test:replications /test:advertising /test:dns
```

Depuis un client Windows :

```cmd
nslookup redone.local
nltest /dsgetdc:redone.local
gpupdate /force
net use Z: \\10.2.41.12\Partage
```

---

## 8. Résumé des règles à retenir pour le jury

1. **DNS (53)** et **Kerberos (88)** sont les premiers ports à contrôler :
   sans eux, pas de jonction ni d'authentification.
2. **RPC (135 + plage dynamique)** est indispensable à la réplication.
3. **SMB (445)** transporte SYSVOL et les GPO.
4. **RDP (3389)** doit rester **fermé à Internet** et accessible uniquement via
   un réseau d'administration (VPN/Tailscale/Bastion).
5. **Tailscale** n'ouvre pas de port entrant : il établit un tunnel sortant
   chiffré, ce qui simplifie le NSG et la traversée de NAT.
