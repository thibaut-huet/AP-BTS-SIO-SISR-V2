# Intégration Tailscale - accès privé au SonarQube de l'AP_2

> Ce document décrit l'accès **sans IP publique** à l'instance SonarQube
> hébergée sur la VM Debian de l'AP_2, puis son intégration dans le workflow
> GitHub Actions. Source d'origine : `Procedure_SonarQube.odt`.

---

## 1. Objectif

L'instance SonarQube écoute sur le port `9000` de la VM Debian
(`10.2.41.4` sur le LAN Proxmox). Plutôt que d'exposer cette VM sur Internet
avec une IP publique et des règles de pare-feu complexes, elle est rendue
accessible **uniquement via un tailnet Tailscale** (WireGuard).

Le même tailnet est utilisé par l'AP_1 pour raccorder le DC Azure au DC
Proxmox. Les deux projets partagent donc **le même espace Tailscale**, mais
restent des projets distincts.

```text
Navigateur / runner GitHub
        │  tunnel WireGuard chiffré
        ▼
Tailnet 100.64.0.0/10
        │
        ▼
VM Debian 10.2.41.4  ──  Tailscale 100.105.124.41
        └── SonarQube :9000
```

## 2. Pourquoi Tailscale plutôt qu'une IP publique

| Critère | IP publique + pare-feu | Tailscale |
|---|---|---|
| Exposition Internet | oui, surface d'attaque | non, aucune |
| Certificat / reverse proxy | à gérer | non nécessaire |
| Authentification | à ajouter | identité du tailnet |
| Accès depuis GitHub Actions | règles entrantes + IP du runner | client OAuth éphémère |
| Mise en œuvre | moyenne | simple |

Le port 9000 n'est **jamais** publié sur Internet. Seuls les nœuds autorisés
par les ACL du tailnet peuvent l'atteindre.

## 3. Installation de Tailscale sur la VM Debian

### 3.1. Installation

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### 3.2. Connexion au tailnet

```bash
sudo tailscale up
```

La commande affiche une URL d'authentification à ouvrir dans un navigateur.
Pour un serveur, on peut aussi utiliser une clé d'authentification non
interactive :

```bash
sudo tailscale up --authkey tskey-auth-xxxxxxxxxxxx
```

Options utiles selon le besoin :

- `--hostname sonarqube-ap2` : nom lisible dans la console Tailscale ;
- `--accept-routes` : uniquement si des routes du LAN doivent être apprises ;
- `--ssh` : active Tailscale SSH (facultatif).

### 3.3. Vérification

```bash
tailscale status
tailscale ip -4
```

Résultat attendu :

- le nœud apparaît `online` dans `tailscale status` ;
- `tailscale ip -4` retourne l'IP du tailnet, par exemple
  **`100.105.124.41`**.

### 3.4. Pare-feu local (si `ufw` est actif)

```bash
sudo ufw allow in on tailscale0 to any port 9000 proto tcp
sudo ufw status
```

Sans `ufw`, aucune règle supplémentaire n'est nécessaire : Docker publie le
port `9000` sur l'hôte.

## 4. Vérifier l'accès à SonarQube

Depuis un poste membre du tailnet :

```bash
curl -I http://100.105.124.41:9000
```

Ou dans un navigateur :

```text
http://100.105.124.41:9000
```

La page de connexion SonarQube doit s'afficher. Depuis le DC Proxmox ou un
poste du LAN, un `ping 100.105.124.41` valide le chemin réseau.

## 5. Créer un client OAuth Tailscale pour GitHub Actions

GitHub Actions ne doit pas utiliser un compte utilisateur : il crée un nœud
**éphémère**, supprimé automatiquement à la fin du job.

1. Se connecter à la console d'administration :
   [login.tailscale.com/admin](https://login.tailscale.com/admin).
2. Aller dans **Settings → Trust credentials → OAuth clients**.
3. Cliquer sur **Generate OAuth client**.
4. Dans **Scopes**, cocher **Devices → Core** avec le droit **Write**
   (nécessaire pour enregistrer puis supprimer le runner temporaire).
5. Donner un nom explicite, par exemple `github-actions-ap2`.
6. Cliquer sur **Generate client** et copier **immédiatement** :
   - le **Client ID** ;
   - le **Client Secret**.
7. Vérifier que le client apparaît dans la liste des clients OAuth actifs.

> Le *Client Secret* n'est affiché qu'une seule fois. En cas de perte, il faut
> générer un nouveau client.

## 6. Autoriser le tag `tag:ci` dans les ACL

Le workflow demande le tag `tag:ci`. Ce tag doit exister dans la politique
d'accès Tailscale, sinon le runner ne peut pas rejoindre le tailnet.

Exemple de politique (console Tailscale → **Access controls**) :

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["tag:ci"],
      "dst": ["100.105.124.41"],
      "ip": ["tcp:9000"]
    }
  ]
}
```

Cette politique autorise **uniquement** les nœuds `tag:ci` à joindre la VM
SonarQube sur le port 9000. Adapter `dst` si l'IP Tailscale de la VM change.

## 7. Configurer les secrets GitHub

Dans le dépôt : **Settings → Secrets and variables → Actions**.

| Secret | Valeur |
|---|---|
| `SONAR_HOST_URL` | `http://100.105.124.41:9000` (sans slash final) |
| `SONAR_TOKEN` | jeton généré dans SonarQube (*My Account → Security*) |
| `TS_OAUTH_CLIENT_ID` | Client ID du client OAuth Tailscale |
| `TS_OAUTH_SECRET` | Client Secret du client OAuth Tailscale |

Vérification : les quatre secrets apparaissent dans la liste, avec une date de
mise à jour récente. Leur valeur reste masquée.

## 8. Étape Tailscale dans le workflow

Le workflow actif est
[`../../.github/workflows/ap2-SonarQube.yml`](../../.github/workflows/ap2-SonarQube.yml).
L'étape Tailscale doit précéder l'analyse SonarQube :

```yaml
- name: Connexion au réseau privé Tailscale
  uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci

- name: Analyse SonarQube
  uses: SonarSource/sonarqube-scan-action@v8
  env:
    SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
    SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
```

Points importants :

- **Emplacement du fichier** : `.github/workflows/` à la **racine** du dépôt.
  GitHub ignore `AP_1/.github/workflows/` et `AP_2/.github/workflows/`.
- **Ordre** : Tailscale avant le scanner, sinon `SONAR_HOST_URL` est
  inaccessible.
- **Fin de job** : l'action Tailscale déconnecte le runner et supprime le nœud
  éphémère automatiquement.
- **Version** : `tailscale/github-action@v4` et
  `SonarSource/sonarqube-scan-action@v8` sont les versions majeures actuelles.

## 9. Vérification de bout en bout

1. Pousser un commit sur `main` ou lancer le workflow manuellement.
2. Dans GitHub → *Actions*, ouvrir le run **AP_2 - Analyse SonarQube (IaC)**.
3. Vérifier que l'étape **Connexion au réseau privé Tailscale** réussit.
4. Vérifier que l'étape **Analyse SonarQube** se termine sans erreur.
5. Dans la console Tailscale, vérifier qu'aucun nœud `tag:ci` ne reste après
   le job (nettoyage automatique).
6. Dans SonarQube, vérifier que le projet `redone-ap1-iac` a été mis à jour et
   que la Quality Gate est `Passed`.

## 10. Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| `tailscale up` reste bloqué | authentification non validée | ouvrir l'URL affichée, ou utiliser `--authkey` |
| Runner sans accès à `:9000` | ACL trop restrictives | autoriser `tag:ci` vers l'IP Tailscale sur `tcp:9000` |
| `OAuth client not allowed to use tag` | `tag:ci` absent de `tagOwners` | ajouter le tag dans la politique ACL |
| `Connection timed out` vers `100.x` | VM hors ligne ou Tailscale arrêté | `systemctl status tailscaled`, `tailscale status` |
| `401 Unauthorized` SonarQube | `SONAR_TOKEN` invalide ou expiré | régénérer le jeton dans SonarQube |
| `Project not found` | `sonar.projectKey` incohérent | aligner `sonar-project.properties` et le projet |
| Nœud `tag:ci` persistant | job interrompu brutalement | supprimer le nœud dans la console Tailscale |

## 11. Sécurité et bonnes pratiques

- **Aucune IP publique** sur la VM SonarQube ; le port 9000 reste dans le
  tailnet.
- **Principe du moindre privilège** : le client OAuth ne peut créer que des
  nœuds `tag:ci`, et ces nœuds ne joignent que le port 9000.
- **Rotation** : révoquer et régénérer le client OAuth et le `SONAR_TOKEN` en
  cas de doute.
- **Secrets** : jamais dans Git ; uniquement dans GitHub Secrets et dans les
  variables d'environnement du job.
- **Mise à jour** : maintenir l'image `sonarqube:community` et
  `postgres:16-alpine` à jour, après sauvegarde des volumes.
- **Sauvegarde** : sauvegarder `sonarqube_data`, `sonarqube_extensions` et
  `postgresql_data` avant toute mise à jour.

## 12. Limites

- Le tailnet est un **point de dépendance** : sans lui, ni l'administration ni
  le pipeline ne peuvent joindre SonarQube.
- Le client OAuth et les ACL doivent être maintenus lors d'un changement d'IP
  Tailscale de la VM.
- Tailscale ne remplace pas une authentification applicative : SonarQube
  conserve ses propres comptes et jetons.
