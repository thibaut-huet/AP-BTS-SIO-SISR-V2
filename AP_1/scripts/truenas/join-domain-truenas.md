# Jonction de TrueNAS au domaine Active Directory `redone.local`

**Cible :** TrueNAS SCALE (VM Proxmox `10.2.41.12`)
**Domaine :** `redone.local`
**DC de reference :** `SRV-AD` (`10.2.41.10`), secondaire `SRV-AD2` (`10.2.41.11`), DC Azure via Tailscale (`100.64.0.4`)

---

## 1. Prerequis

| Element | Valeur attendue |
|---|---|
| Reseau | TrueNAS : `10.2.41.12/24`, passerelle `10.2.41.1` |
| DNS | `10.2.41.10` puis `10.2.41.11` |
| Nom de domaine | `redone.local` |
| Heure | Synchronisee a moins de 5 minutes du DC (Kerberos) |
| Compte | `REDONE\Administrateur` (ou un compte delegue a la jonction) |

Verifier depuis la console TrueNAS :

```bash
ping -c 3 10.2.41.10
nslookup redone.local 10.2.41.10
date -u
```

> Si TrueNAS doit joindre le domaine depuis un site distant (sans LAN Proxmox),
> installer Tailscale sur TrueNAS ou exposer le DC via le subnet router
> Tailscale. Les commandes de verification restent identiques.

---

## 2. Jonction via l'interface web (recommande pour l'AP)

1. Ouvrir `http://10.2.41.12` avec `truenas_admin`.
2. **Credentials** > **Directory Services** > **Configure**.
3. Renseigner :

| Champ | Valeur |
|---|---|
| Directory Service | **Active Directory** |
| Domain Name | `redone.local` |
| Domain Account Name | `Administrateur` |
| Domain Account Password | (mot de passe du domaine) |
| Computer Account OU | laisser vide, ou `OU=Servers,DC=redone,DC=local` |
| Enable DNS updates | active si souhaite |

4. **Save**. TrueNAS cree le compte machine et joint le domaine.
5. Verifier dans **Active Directory Users and Computers** que `TRUENAS-01`
   apparait dans le conteneur `Computers` (ou l'OU cible).

---

## 3. Verification en ligne de commande

Depuis le shell TrueNAS :

```bash
# Le ticket Kerberos et le compte machine sont-ils valides ?
net ads testjoin
kinit Administrateur@REDONE.LOCAL
klist

# Le service d'annuaire repond-il ?
wbinfo -t
wbinfo -u | head
getent passwd 'REDONE\Administrateur'
```

Resultats attendus :
- `net ads testjoin` : `Join is OK`
- `wbinfo -t` : `succeeded`
- les utilisateurs du domaine sont listes.

---

## 4. Partage SMB et ACL

1. **Storage** > `datapool` > **Create Dataset** : `partage`.
2. **Shares** > **Windows (SMB)** > **Add** :
   - Path : `/mnt/datapool/partage`
   - Name : `Partage`
   - Description : `Partage commun redone.local`
3. **Edit ACL** :
   - Group : `REDONE\Domain Users` (ou `REDONE\Utilisateurs du domaine`)
   - Permissions : `Modify`
   - Inheritance : activee
4. Tester depuis un client Windows joint au domaine :

```powershell
net use Z: \\10.2.41.12\Partage /persistent:yes
dir Z:\
```

---

## 5. Mappage automatique par GPO (rappel)

La GPO `Lecteur-TrueNAS` mappe `Z:` vers `\\10.2.41.12\Partage`.

- Action : **Update**
- Reconnect : coche
- **Common** > *Run in logged-on user's security context* : coche

Depuis le client :

```cmd
gpupdate /force
```

Si le lecteur n'apparait pas, executer `scripts/clients/map-smb-shares.ps1`
en secours.

---

## 6. Depannage

| Symptome | Piste |
|---|---|
| `DNS update failed` / `this could be a DNS misconfiguration` | Retirer la passerelle de la configuration TrueNAS, ne garder que le DNS `10.2.41.10` ; verifier la zone directe et inversee. |
| `Clock skew too great` | Resynchroniser l'heure (NTP) avec le DC. |
| `Join is OK` mais partage inaccessible | Verifier le service SMB, les ACL et que le client est bien authentifie sur le domaine. |
| Erreur Kerberos apres migration du DC | Verifier que le DC Azure publie bien les enregistrements SRV dans DNS (`nltest /dsgetdc:redone.local`). |
