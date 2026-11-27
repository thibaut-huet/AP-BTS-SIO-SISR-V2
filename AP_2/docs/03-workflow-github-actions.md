# 03 - Projet SonarQube et workflow GitHub Actions

> **Étape 3 du parcours.** La VM SonarQube est installée (doc 01) et joignable
> via Tailscale (doc 02). Il reste à créer le projet, configurer les secrets et
> lancer l'analyse automatique.

---

## 1. Créer le projet et le token dans SonarQube

1. Ouvrir `http://100.105.124.41:9000` et se connecter (`admin`).
2. Changer le mot de passe administrateur quand il le demande.
3. **Créer le projet** : *Projects → Create project → Manually*.
   - **Project key** : `redone-ap1-iac` (exactement, sans espace).
   - **Display name** : `RedOne - AP_1 Infrastructure as Code`.
4. **Générer un token** : avatar → *My Account → Security →
   Generate Tokens*.
   - Nom : `github-actions-ap2`.
   - Type : *Project Analysis Token* ou *User Token*.
   - Copier le token immédiatement : il n'est plus affiché ensuite.

> Le `projectKey` doit être **identique** à celui de
> [`../../sonar-project.properties`](../../sonar-project.properties).

---

## 2. Configurer les secrets GitHub

Dépôt GitHub → **Settings → Secrets and variables → Actions → New repository
secret**.

| Secret | Valeur | Origine |
|---|---|---|
| `SONAR_TOKEN` | token généré à l'étape 1 | SonarQube |
| `SONAR_HOST_URL` | `http://100.105.124.41:9000` (sans `/` final) | IP Tailscale de la VM |
| `TS_OAUTH_CLIENT_ID` | Client ID OAuth | doc 02 §5 |
| `TS_OAUTH_SECRET` | Client Secret OAuth | doc 02 §5 |

> Aucun secret n'est écrit dans le dépôt. Ils sont injectés dans le job
> uniquement.

---

## 3. Emplacement des fichiers

| Fichier | Emplacement attendu | Rôle |
|---|---|---|
| `ap2-SonarQube.yml` | `.github/workflows/` **à la racine** | workflow exécuté par GitHub |
| `sonar-project.properties` | **racine** du dépôt | configuration du scanner |
| `docker-compose.yml` | sur la VM Debian (`~/sonarqube/`) | stack SonarQube |

> GitHub Actions ne lit **que** `.github/workflows/` à la **racine**. Un
> workflow placé dans `AP_1/.github/workflows/` ou
> `AP_2/.github/workflows/` ne sera jamais exécuté.

---

## 4. Le workflow expliqué

Fichier : [`../../.github/workflows/ap2-SonarQube.yml`](../../.github/workflows/ap2-SonarQube.yml)

### 4.1. Déclencheurs

```yaml
on:
  push:
    branches: [ main ]
  pull_request:
    types: [opened, synchronize, reopened]
  workflow_dispatch:
```

- `push` sur `main` : analyse après fusion ;
- `pull_request` : analyse avant fusion, pour bloquer une régression ;
- `workflow_dispatch` : lancement manuel depuis l'interface GitHub.

### 4.2. Étapes

| Étape | Rôle |
|---|---|
| `actions/checkout@v4` (`fetch-depth: 0`) | historique complet, nécessaire au *new code* |
| `tailscale/github-action@v4` | nœud éphémère `tag:ci`, tunnel WireGuard |
| Installation du CLI Bicep | télécharge le binaire officiel |
| Compilation Bicep → ARM | produit `build/arm/main.json` |
| `SonarSource/sonarqube-scan-action@v8` | envoie l'analyse et attend la Quality Gate |

### 4.3. Pourquoi compiler le Bicep ?

SonarQube Community Build analyse nativement l'**Azure Resource Manager
(ARM JSON)**, mais **pas** le Bicep source (aucune édition ne le fait
directement). Le workflow compile donc `AP_1/bicep/main.bicep` en ARM avant
l'analyse. Sans cette étape, SonarQube n'analyserait aucun template
d'infrastructure.

### 4.4. Quality Gate bloquante

`sonar-project.properties` contient :

```properties
sonar.qualitygate.wait=true
```

Le job attend le verdict et **échoue** si la Quality Gate n'est pas respectée.
C'est ce qui transforme l'analyse en contrôle bloquant.

---

## 5. Lancer et lire le résultat

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

3. Si tout est vert : SonarQube → *Projects* → `redone-ap1-iac` → *Issues* et
   *Quality Gate* sont disponibles.

---

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| Tailscale échoue | secrets OAuth invalides, `tag:ci` absent des ACL |
| `curl` vers `:9000` impossible | conteneurs arrêtés, VM hors tailnet |
| Compilation Bicep en échec | relancer `bicep build AP_1/bicep/main.bicep` en local |
| `401 Unauthorized` | `SONAR_TOKEN` invalide ou expiré |
| `Project not found` | `sonar.projectKey` incohérent avec le projet |
| Quality Gate rouge | ce n'est pas un bug : consulter les *Issues* |

Dépannage Tailscale détaillé : [`02-integration-tailscale.md`](02-integration-tailscale.md) §10.

---

## 7. Checklist finale

- [ ] Projet `redone-ap1-iac` créé dans SonarQube.
- [ ] Token SonarQube généré et stocké dans `SONAR_TOKEN`.
- [ ] `SONAR_HOST_URL` = IP Tailscale de la VM, sans slash final.
- [ ] Client OAuth Tailscale créé, `tag:ci` autorisé dans les ACL.
- [ ] 4 secrets GitHub présents.
- [ ] Workflow à la racine `.github/workflows/ap2-SonarQube.yml`.
- [ ] `sonar-project.properties` à la racine.
- [ ] Workflow vert, Quality Gate `Passed`.

Si toutes les cases sont cochées, l'AP_2 est opérationnel et démontrable.
