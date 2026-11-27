# Intégration Tailscale - accès privé au SonarQube de l'AP_2

> Ce document décrit l'accès **sans IP publique** à l'instance SonarQube
> hébergée sur la VM Debian de l'AP_2, puis son intégration dans le workflow
> GitHub Actions.

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

## 4. Vérifier l'accès à SonarQube depuis le Tailnet

La VM n'a **aucune IP publique** et n'est pas exposée sur Internet. Son port 9000 n'est accessible que depuis le réseau local Proxmox ou à travers le VPN Tailscale.

Depuis un poste membre du tailnet (ex: votre PC d'administration avec Tailscale actif) :

```bash
curl -I http://100.105.124.41:9000
```

Ou dans un navigateur web :

```text
http://100.105.124.41:9000
```

La page d'accueil de SonarQube doit s'afficher immédiatement. Depuis le contrôleur de domaine Proxmox ou un poste du LAN, un simple `ping 100.105.124.41` permet également de valider la connectivité réseau du tailnet.

## 5. Créer un client OAuth Tailscale pour GitHub Actions

GitHub Actions ne doit pas utiliser un compte utilisateur : il crée un nœud
**éphémère**, supprimé automatiquement à la fin du job.

1. Se connecter à la console d'administration :
   [login.tailscale.com/admin](https://login.tailscale.com/admin).
2. Aller dans **Settings → Trust credentials → OAuth clients** (ou cliquer sur **+ Credential**).
3. Donner un nom / description explicite, par exemple `github-actions-ap2` ou `SonarQube`.
4. Configurer impérativement les **Scopes** et **Tags** suivants :
   - ✅ **Auth Keys** : cocher **Write** *(INDISPENSABLE : permet au client OAuth d'émettre des clés d'authentification éphémères pour les runners GitHub).*
   - **Tags (required for write scope)** : sélectionner ou saisir **`tag:ci`** *(le tag doit au préalable être déclaré dans les ACLs, voir section 6).*
   - ✅ **Devices** : cocher **Write** (ou **Core**).
   - ⚠️ *Attention : ne pas cocher « OAuth Keys », qui sert à administrer d'autres clients OAuth et non à connecter des machines.*
5. Cliquer sur **Generate client** et copier **immédiatement** :
   - le **Client ID** (ex: `k3RZSmqt8511CNTRL`) ;
   - le **Client Secret** (commençant par `tskey-client-...`).
6. Vérifier que le client apparaît dans la liste des clients OAuth actifs avec le tag `tag:ci` et le scope `auth_keys:write`.

> ⚠️ **Point de vigilance (Erreur 404 Tailscale) :** Si la case **Auth Keys → Write** n'est pas cochée ou si le tag `tag:ci` n'est pas renseigné sous ce scope lors de la création du client OAuth, le runner GitHub recevra une erreur `Status: 404, Message: "not found"` lors de l'exécution de `tailscale up`.

> Le *Client Secret* n'est affiché qu'une seule fois. En cas de perte, il faut
> générer un nouveau client.

## 6. Configurer la politique d'accès Tailscale (ACLs & JSON Editor)

### 6.1. Qu'est-ce que les ACLs et où les modifier ?

Les ACLs (*Access Control Lists*) de Tailscale ne sont pas configurées machine par machine sur les VM, mais de manière centralisée pour l'ensemble du réseau privé (*tailnet*).

1. Rendez-vous sur la console d'administration Tailscale : [login.tailscale.com/admin](https://login.tailscale.com/admin).
2. Cliquez sur l'onglet **Access controls** dans le menu supérieur.
3. Vous arrivez directement sur le **JSON Editor** : c'est un fichier de configuration unique en JSON qui régit qui a le droit d'utiliser des tags et quelles machines peuvent communiquer entre elles.

---

### 6.2. Comprendre le rôle du tag `tag:ci`

Par défaut, sur Tailscale, chaque machine appartient à un utilisateur connecté (ex: votre adresse e-mail). 
Pour un pipeline d'intégration continue (GitHub Actions) :
- Le runner est une **machine virtuelle éphémère** qui n'a pas d'utilisateur physique pour cliquer sur un lien de connexion web.
- Pour identifier et sécuriser cette machine automatique, on lui attribue un **Tag** : **`tag:ci`**.
- Un nœud tagué perd son appartenance à un utilisateur humain et devient une machine de service ("server identity"), ce qui lui permet d'être créée, connectée et détruite automatiquement par un script.

Pour que cela fonctionne, deux règles sont obligatoires dans le JSON :
1. **`tagOwners`** : Déclare qui a l'autorité pour créer ou assigner le tag. Sans cela, Tailscale bloque toute création de machine taguée (`404 Not Found`).
2. **`grants`** (ou `acls`) : Définit vers quelles machines et quels ports les nœuds portant ce tag ont le droit d'émettre du trafic.

---

### 6.3. La configuration JSON complète du Tailnet

Voici le fichier JSON de la politique d'accès tel que configuré dans votre **JSON Editor** (partagé entre l'AP_1 et l'AP_2) :

```json
{
	// 1. Déclaration des propriétaires de tags (qui a le droit d'utiliser quel tag)
	"tagOwners": {
		"tag:ci":        ["autogroup:admin"],
		"tag:dc-onprem": ["autogroup:admin"],
		"tag:dc-azure":  ["autogroup:admin"]
	},

	// 2. Règles d'accès réseau (filtrage des flux)
	"grants": [
		// Règle générale du lab : autorise les flux nécessaires
		{
			"src": ["*"],
			"dst": ["*"],
			"ip":  ["*"]
		},
		// Règle explicite AP_2 : le runner CI (tag:ci) ne peut joindre QUE SonarQube sur le port 9000
		{
			"src": ["tag:ci"],
			"dst": ["100.105.124.41"],
			"ip":  ["tcp:9000"]
		}
	],

	// 3. Accès SSH sécurisé Tailscale
	"ssh": [
		{
			"action": "check",
			"src":    ["autogroup:member"],
			"dst":    ["autogroup:self"],
			"users":  ["autogroup:nonroot", "root"]
		}
	]
}
```

> 💡 **Explication des corrections apportées :**
> - **`tagOwners`** : Chaque tag (`tag:ci`, `tag:dc-onprem`, `tag:dc-azure`) doit obligatoirement avoir `["autogroup:admin"]`. Si un tag contient une liste vide `[]`, personne ne peut l'assigner, ce qui fait échouer l'enregistrement des machines.
> - **`grants` pour l'AP_2** : La règle `{ "src": ["tag:ci"], "dst": ["100.105.124.41"], "ip": ["tcp:9000"] }` formalise le principe de moindre privilège : le runner éphémère GitHub Actions ne peut atteindre que le port Web/API de SonarQube et rien d'autre sur le réseau.

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

## 8. Fonctionnement de l'étape Tailscale dans le workflow GitHub Actions

Le workflow actif qui orchestre l'analyse est situé dans [`.github/workflows/ap2-SonarQube.yml`](../../.github/workflows/ap2-SonarQube.yml) à la racine du dépôt.

### 8.1. Pourquoi Tailscale doit tourner dans le workflow ?

Le runner GitHub Actions est une machine virtuelle temporaire qui s'exécute dans les datacenters de Microsoft/GitHub. Elle n'a aucun moyen natif de joindre l'adresse IP privée de votre VM SonarQube sur Proxmox (`10.2.41.4` ou `100.105.124.41`).

L'action **`tailscale/github-action@v4`** permet au runner de :
1. Installer le client Tailscale à la volée sur la VM GitHub.
2. Contacter l'API Tailscale grâce au Client ID et Client Secret OAuth.
3. Obtenir une clé temporaire et monter un tunnel WireGuard chiffré vers votre Tailnet en tant que machine éphémère (`tag:ci`).
4. Rendre l'IP `100.105.124.41` routable directement depuis le script GitHub Actions.

### 8.2. Extrait du code YAML dans le workflow

Cette étape doit impérativement être placée **avant** l'étape d'analyse SonarScanner :

```yaml
      # Étape 1 : Le runner GitHub rejoint votre réseau privé Tailscale
      - name: Connexion au reseau prive Tailscale
        uses: tailscale/github-action@v4
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      # Étape 2 : Le scanner peut maintenant interroger SonarQube via l'IP Tailscale
      - name: Analyse SonarQube
        uses: SonarSource/sonarqube-scan-action@v8
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }} # http://100.105.124.41:9000
```

### 8.3. Cycle de vie et nettoyage automatique

- **Au début de l'étape :** Le runner démarre `tailscaled`, s'enregistre auprès de la coordination Tailscale avec le tag `tag:ci` et établit les routes réseau.
- **Pendant l'analyse :** SonarScanner communique avec `http://100.105.124.41:9000` de façon totalement transparente à travers le tunnel chiffré WireGuard.
- **À la fin du job (Post-run) :** L'action Tailscale s'arrête proprement et informe la console Tailscale de détruire le nœud éphémère. Aucun serveur fantôme ne reste dans votre tableau de bord Tailscale.

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
| `Status: 404, Message: "not found"` | Client OAuth sans scope `Auth Keys: Write` ou tag `tag:ci` manquant | Recréer le client OAuth avec **Auth Keys → Write** et assigner `tag:ci` |
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
