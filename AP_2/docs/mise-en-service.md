# Mise en service de l'AP_2 - pas à pas

> **But de ce document :** te donner **un seul chemin linéaire**, du début à la
> fin, pour arriver à un pipeline SonarQube vert. Si tu suis les 6 étapes dans
> l'ordre, tu n'as pas besoin de deviner quoi faire.
>
> Durée indicative : 1 h à 1 h 30 la première fois.

---

## 0. Ce que tu vas obtenir

À la fin :

- une instance **SonarQube** accessible sur `http://100.105.124.41:9000` ;
- un **projet** `redone-ap1-iac` dans SonarQube ;
- un workflow GitHub Actions **AP_2 - Analyse SonarQube (IaC)** qui se lance à
  chaque `push` et qui **échoue** si la Quality Gate n'est pas respectée.

Tu n'as **rien à modifier dans l'AP_1**. L'AP_2 ne fait qu'auditer son code.

---

## 1. Déployer SonarQube sur la VM Debian

**Document :** [`../installation_SonarQube/Installation_SonarQube.md`](../installation_SonarQube/Installation_SonarQube.md)

À faire dans l'ordre :

1. Configurer le noyau (`vm.max_map_count`, `fs.file-max`).
2. Installer Docker + le plugin Compose.
3. Copier [`docker-compose.yml`](../installation_SonarQube/docker/docker-compose.yml)
   sur la VM, dans `~/sonarqube/`.
4. Remplacer les mots de passe `********` par de vrais mots de passe
   (idéalement via un fichier `.env` non versionné).
5. Lancer `docker compose up -d`, puis attendre `SonarQube is operational`.

**Vérification :**

```bash
docker compose ps
# sonarqube et sonarqube-db doivent être "running"
```

---

## 2. Rendre SonarQube accessible via Tailscale

**Document :** [`integration-tailscale.md`](integration-tailscale.md) §3 et §4

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4
```

**Note l'IP affichée.** Dans cette documentation, on utilise
`100.105.124.41`. Si la tienne est différente, remplace-la partout (ACL,
secret `SONAR_HOST_URL`, README).

**Vérification :**

```bash
curl -I http://100.105.124.41:9000
# doit répondre HTTP/1.1 200 ou 302
```

---

## 3. Créer le projet et le token dans SonarQube

1. Ouvrir `http://100.105.124.41:9000` et se connecter (`admin`).
2. Changer le mot de passe administrateur quand il le demande.
3. **Créer le projet** : *Projects → Create project → Manually*.
   - **Project key** : `redone-ap1-iac` (exactement, sans espace).
   - **Display name** : `RedOne - AP_1 Infrastructure as Code`.
4. **Générer un token** : cliquer sur ton avatar → *My Account* →
   *Security* → *Generate Tokens*.
   - Nom : `github-actions-ap2`.
   - Type : *Project Analysis Token* ou *User Token*.
   - Copier le token immédiatement (il n'est plus affiché ensuite).

> Le `projectKey` doit être **identique** à celui de
> [`../../sonar-project.properties`](../../sonar-project.properties).

---

## 4. Créer le client OAuth Tailscale

**Document :** [`integration-tailscale.md`](integration-tailscale.md) §5 et §6

1. Console Tailscale → **Settings → Trust credentials → OAuth clients**.
2. **Generate OAuth client**.
3. Scopes : **Devices → Core → Write**.
4. Copier le **Client ID** et le **Client Secret**.
5. Dans **Access controls**, autoriser `tag:ci` à joindre la VM sur le port
   9000 (exemple de politique JSON dans la doc Tailscale §6).

**Vérification :** le client OAuth apparaît dans la liste, et `tag:ci` est
déclaré dans les ACL.

---

## 5. Configurer les 4 secrets GitHub

Dépôt GitHub → **Settings → Secrets and variables → Actions → New repository
secret**.

| Nom du secret | Valeur exacte |
|---|---|
| `SONAR_TOKEN` | le token généré à l'étape 3 |
| `SONAR_HOST_URL` | `http://100.105.124.41:9000` (sans `/` final) |
| `TS_OAUTH_CLIENT_ID` | le Client ID de l'étape 4 |
| `TS_OAUTH_SECRET` | le Client Secret de l'étape 4 |

**Vérification :** les 4 secrets apparaissent dans la liste.

---

## 6. Vérifier que les fichiers sont au bon endroit

Avant de lancer le pipeline, contrôle ces 3 emplacements :

| Fichier | Emplacement attendu | Rôle |
|---|---|---|
| `ap2-SonarQube.yml` | `.github/workflows/` **à la racine** | workflow exécuté par GitHub |
| `sonar-project.properties` | **racine** du dépôt | configuration du scanner |
| `docker-compose.yml` | sur la VM Debian (`~/sonarqube/`) | stack SonarQube |

> Un workflow placé dans `AP_1/.github/workflows/` ou `AP_2/.github/workflows/`
> **ne sera jamais exécuté** par GitHub.

---

## 7. Lancer et lire le résultat

1. GitHub → onglet **Actions** → **AP_2 - Analyse SonarQube (IaC)** →
   **Run workflow**.
2. Suivre les 5 étapes :

| Étape | Résultat attendu |
|---|---|
| Récupération du code | OK |
| Connexion au réseau privé Tailscale | OK, nœud `tag:ci` créé |
| Installation du CLI Bicep | version affichée |
| Compilation Bicep → ARM | `build/arm/main.json` créé |
| Analyse SonarQube | scan envoyé, Quality Gate évaluée |

3. Si tout est vert : ouvrir SonarQube → *Projects* → `redone-ap1-iac` →
   les *Issues* et la *Quality Gate* sont disponibles.

---

## 8. Si ça ne marche pas

| Étape qui échoue | Réflexe |
|---|---|
| Tailscale | vérifier `tailscale status` sur la VM et les ACL `tag:ci` |
| `curl` vers `:9000` | conteneurs arrêtés ? `docker compose ps` |
| Compilation Bicep | relancer `bicep build AP_1/bicep/main.bicep --outfile build/arm/main.json` en local |
| Analyse SonarQube | `SONAR_TOKEN` / `SONAR_HOST_URL` erronés, ou projet inexistant |
| Quality Gate rouge | ce n'est pas un bug : consulter les *Issues* dans SonarQube |

Dépannage détaillé : [`integration-tailscale.md`](integration-tailscale.md) §10
et [`../README.md`](../README.md) §12.

---

## 9. Checklist finale

- [ ] `docker compose ps` : SonarQube + PostgreSQL `running`.
- [ ] `http://100.105.124.41:9000` accessible depuis le tailnet.
- [ ] Projet `redone-ap1-iac` créé dans SonarQube.
- [ ] Token SonarQube généré et stocké dans `SONAR_TOKEN`.
- [ ] Client OAuth Tailscale créé, `tag:ci` autorisé dans les ACL.
- [ ] 4 secrets GitHub présents.
- [ ] Workflow à la racine `.github/workflows/ap2-SonarQube.yml`.
- [ ] `sonar-project.properties` à la racine.
- [ ] Workflow vert, Quality Gate `Passed`.

Si toutes les cases sont cochées, l'AP_2 est opérationnel et démontrable.
