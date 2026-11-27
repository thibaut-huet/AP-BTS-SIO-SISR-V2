# AP_2 - Sécurisation et analyse de la qualité de code de l'IaC de l'AP_1 avec SonarQube

**Auteur :** Thibaut HUET  
**Contexte :** BTS SIO option SISR - Atelier Professionnel  
**Projet rattaché :** AP_1 (*Migration de l'Active Directory RedOne vers Azure*)  
**Plateforme d'analyse :** SonarQube Community Build (Docker / PostgreSQL 16)  
**Hébergement :** VM Debian sur Proxmox VE, exposée uniquement via Tailscale  

---

> **AP_2 est un projet distinct de l'AP_1.** Il ne déploie aucune ressource
> Azure et ne modifie pas l'infrastructure de l'AP_1. Il ajoute une démarche
> **DevSecOps** : une plateforme SonarQube auto-hébergée analyse le code IaC
> produit dans l'AP_1, et un workflow GitHub Actions automatise ce contrôle.
> Le lien entre les deux AP est le **code audité** (Bicep, PowerShell, YAML),
> pas l'infrastructure.

> **Tu veux juste déployer ?** Suis le guide linéaire
> [`docs/mise-en-service.md`](docs/mise-en-service.md) : 6 étapes, de la VM
> Debian jusqu'au pipeline vert, avec les vérifications à chaque étape.

---

## 1. Présentation et contexte

L'AP_1 a déployé et migré l'Active Directory de RedOne vers Azure avec une
démarche **DevOps / Infrastructure as Code** : templates **Bicep**, scripts
**PowerShell** et pipelines **GitHub Actions**.

L'adoption de l'IaC déplace une partie des risques vers le code lui-même :

- mauvaises configurations réseau (ports ouverts, NSG trop permissifs) ;
- ressources Azure mal paramétrées ;
- secrets ou données sensibles codés en dur ;
- dette technique et manque de maintenabilité.

L'AP_2 répond à ces risques en intégrant **SonarQube** comme outil d'analyse
statique (SAST) dans la chaîne CI/CD. L'objectif est de **détecter, mesurer et
bloquer** les régressions de qualité et de sécurité avant tout déploiement.

## 2. Objectifs

1. **Héberger une instance SonarQube dédiée** sur une VM Debian Proxmox,
   conteneurisée avec Docker Compose et adossée à PostgreSQL 16.
2. **Auditer le code de l'AP_1** : templates Bicep compilés en ARM, scripts,
   workflows et fichiers de configuration.
3. **Définir une Quality Gate** : seuils de qualité qui conditionnent le succès
   du pipeline.
4. **Automatiser l'analyse** à chaque `push` et `pull request` via GitHub
   Actions, avec un accès privé au serveur SonarQube par **Tailscale**.

## 3. Périmètre

| Élément | Statut | Remarque |
|---|---|---|
| Instance SonarQube + PostgreSQL | **déployé** | Docker Compose sur VM Debian |
| Accès privé via Tailscale | **déployé** | aucune IP publique exposée |
| Workflow GitHub Actions | **déployé** | `.github/workflows/ap2-SonarQube.yml` |
| Compilation Bicep → ARM | **déployé** | nécessaire pour l'analyse SonarQube |
| Quality Gate bloquante | **configurée** | `sonar.qualitygate.wait=true` |
| Modification de l'infrastructure AP_1 | **hors périmètre** | AP_2 audite, ne déploie pas |
| Haute disponibilité de SonarQube | **hors périmètre** | instance unique de laboratoire |

## 4. Architecture

```text
+--------------------------------------------------------------------------+
|                            PROXMOX VE (On-Premise)                       |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  | VM Debian (10.2.41.4) - Tailscale 100.105.124.41                   |  |
|  |                                                                    |  |
|  |   +--------------------------+      +--------------------------+   |  |
|  |   |    SonarQube Community   | <--> |      PostgreSQL 16       |   |  |
|  |   |       (Port 9000)        |      |      (Port 5432)         |   |  |
|  |   +--------------------------+      +--------------------------+   |  |
|  |                ^                                                   |  |
|  +----------------|---------------------------------------------------+  |
+-------------------|------------------------------------------------------+
                    | Tunnel WireGuard Tailscale (tag:ci, éphémère)
                    |
+-------------------|------------------------------------------------------+
|                   v                                                      |
|   GitHub Actions (runner ubuntu-latest)                                  |
|   - checkout du dépôt                                                    |
|   - compilation Bicep -> ARM                                             |
|   - SonarScanner -> http://100.105.124.41:9000                           |
+--------------------------------------------------------------------------+
```

Aucun port n'est publié sur Internet : le runner GitHub rejoint le tailnet le
temps du job, puis son nœud est supprimé automatiquement.

## 5. Structure du dossier

```text
AP_2/
├── README.md                                  # ce document
├── docs/
│   ├── mise-en-service.md                     # guide linéaire de A à Z
│   ├── integration-tailscale.md               # Tailscale + workflow (procédure)
│   └── Procedure_SonarQube.odt                # compte-rendu bureautique
└── installation_SonarQube/
    ├── Installation_SonarQube.md              # installation Debian + Docker
    └── docker/
        └── docker-compose.yml                 # SonarQube + PostgreSQL 16

Racine du dépôt (éléments partagés avec l'AP_1) :
├── .github/workflows/ap2-SonarQube.yml        # workflow actif (obligatoire ici)
└── sonar-project.properties                   # configuration du SonarScanner
```

> **Emplacement du workflow.** GitHub Actions ne lit **que**
> `.github/workflows/` à la **racine** du dépôt. Un fichier placé dans
> `AP_1/.github/workflows/` ou `AP_2/.github/workflows/` est **ignoré**.
> C'est pourquoi le workflow AP_2 est à la racine, avec le préfixe `ap2-`
> pour le distinguer des workflows AP_1.

## 6. Démarrage rapide

Le plus simple est de suivre **un seul document**, dans l'ordre :
[`docs/mise-en-service.md`](docs/mise-en-service.md).

En résumé :

1. **Installer SonarQube** : suivre
   [`installation_SonarQube/Installation_SonarQube.md`](installation_SonarQube/Installation_SonarQube.md).
2. **Rendre l'accès privé** : suivre
   [`docs/integration-tailscale.md`](docs/integration-tailscale.md).
3. **Créer le projet et le token** dans SonarQube (`redone-ap1-iac`).
4. **Configurer les 4 secrets GitHub** (§8).
5. **Lancer le workflow** : onglet *Actions* → *AP_2 - Analyse SonarQube (IaC)*
   → *Run workflow*, ou simplement pousser sur `main`.
6. **Consulter le résultat** sur `http://100.105.124.41:9000`.

## 7. Intégration Tailscale

La VM SonarQube n'a **pas d'IP publique**. Trois éléments doivent être en
place :

1. **La VM est membre du tailnet** (`tailscale up`) et porte l'IP
   `100.105.124.41`.
2. **Un client OAuth Tailscale** autorise GitHub Actions à créer un nœud
   éphémère avec le tag `tag:ci`.
3. **Les ACL Tailscale** autorisent `tag:ci` à joindre la VM sur le port 9000.

Procédure complète, commandes et vérifications :
[`docs/integration-tailscale.md`](docs/integration-tailscale.md).

## 8. Secrets et variables GitHub

À déclarer dans *Settings → Secrets and variables → Actions* :

| Secret | Rôle | Exemple |
|---|---|---|
| `SONAR_TOKEN` | Jeton d'analyse généré dans SonarQube | `sqa_...` |
| `SONAR_HOST_URL` | URL du serveur, **sans slash final** | `http://100.105.124.41:9000` |
| `TS_OAUTH_CLIENT_ID` | *Client ID* du client OAuth Tailscale | `k...` |
| `TS_OAUTH_SECRET` | *Client Secret* du client OAuth Tailscale | `tskey-client-...` |

> Aucun secret n'est écrit dans le dépôt. Les secrets GitHub sont injectés
> dans l'environnement du job uniquement.

## 9. Le workflow `.github/workflows/ap2-SonarQube.yml`

### 9.1. Déclencheurs

```yaml
on:
  push:
    branches: [ main ]
  pull_request:
    types: [opened, synchronize, reopened]
  workflow_dispatch:
```

- `push` sur `main` : analyse après fusion.
- `pull_request` : analyse avant fusion, pour bloquer une régression.
- `workflow_dispatch` : lancement manuel depuis l'interface GitHub.

### 9.2. Étapes

| Étape | Rôle |
|---|---|
| `actions/checkout@v4` (`fetch-depth: 0`) | récupère tout l'historique, nécessaire au calcul du *new code* |
| `tailscale/github-action@v4` | connecte le runner au tailnet avec le tag `tag:ci` |
| Installation du CLI Bicep | télécharge le binaire officiel |
| Compilation Bicep → ARM | `bicep build` produit `build/arm/main.json` |
| `SonarSource/sonarqube-scan-action@v8` | envoie l'analyse à `SONAR_HOST_URL` |

### 9.3. Pourquoi compiler le Bicep ?

SonarQube Community Build analyse nativement l'**Azure Resource Manager
(ARM JSON)**, mais **pas** le Bicep source. Le workflow compile donc
`AP_1/bicep/main.bicep` en ARM avant l'analyse. Sans cette étape, SonarQube
n'analyserait aucun template d'infrastructure.

### 9.4. Quality Gate

`sonar-project.properties` contient :

```properties
sonar.qualitygate.wait=true
```

Le job attend le verdict de la Quality Gate et **échoue** si elle n'est pas
respectée. C'est ce qui transforme l'analyse en véritable contrôle bloquant.

## 10. Vérifications

| Vérification | Commande / lieu | Attendu |
|---|---|---|
| Conteneurs actifs | `docker compose ps` sur la VM | `sonarqube` et `sonarqube-db` en `running` |
| Interface accessible | navigateur sur `http://100.105.124.41:9000` | page de connexion SonarQube |
| VM dans le tailnet | `tailscale status` | `100.105.124.41` visible |
| Workflow exécuté | onglet *Actions* GitHub | job vert, étape *Analyse SonarQube* OK |
| Projet créé | SonarQube → *Projects* | `redone-ap1-iac` présent |
| Quality Gate | SonarQube → projet → *Quality Gate* | statut `Passed` |

## 11. Limites à assumer

- **Langages réellement analysés** : SonarQube Community Build couvre l'ARM,
  le Docker, les secrets et de nombreux langages applicatifs, mais **pas** le
  Bicep brut, **pas** PowerShell et **pas** YAML. Le pipeline compile donc le
  Bicep en ARM et s'appuie sur les outils natifs de l'AP_1 pour le reste
  (`bicep lint`, `az bicep build`, analyse YAML par GitHub).
- **Instance unique** : pas de haute disponibilité ; la VM et les volumes
  Docker sont un point unique de défaillance.
- **Pas de sauvegarde automatique** : les volumes `postgresql_data` et
  `sonarqube_data` doivent être sauvegardés manuellement.
- **Dépendance à Tailscale** : sans tailnet opérationnel, le runner ne peut
  pas joindre SonarQube.
- **Pas de déploiement Azure** : l'AP_2 audite l'AP_1, il ne le remplace pas.

## 12. Dépannage rapide

| Symptôme | Piste |
|---|---|
| `Connection refused` vers `:9000` | conteneurs arrêtés ou VM hors tailnet |
| Workflow bloqué à Tailscale | secrets OAuth invalides, tag `tag:ci` absent des ACL |
| `Project not found` | `sonar.projectKey` différent de celui créé, ou token sans droit |
| `No files to analyze` | compilation Bicep absente ou `build/arm` non généré |
| Quality Gate en échec | consulter les *Issues* du projet dans SonarQube |

## 13. Compétences SISR mobilisées

| Axe | Mise en œuvre |
|---|---|
| **Sécurité & DevSecOps** | SAST, détection de secrets, Quality Gate bloquante |
| **Conteneurisation** | Docker Compose multi-services, volumes persistants, réseau Docker |
| **Administration Linux** | `sysctl` (`vm.max_map_count`), Docker Engine, permissions |
| **Réseau & accès distant** | Tailscale/WireGuard, client OAuth, ACL par tag |
| **CI/CD** | GitHub Actions, secrets, compilation Bicep, SonarScanner |
| **Exploitation** | logs, supervision des conteneurs, sauvegarde des volumes |

## 14. Documents

| Document | Contenu |
|---|---|
| [`docs/mise-en-service.md`](docs/mise-en-service.md) | **guide linéaire de A à Z** (à suivre en premier) |
| [`installation_SonarQube/Installation_SonarQube.md`](installation_SonarQube/Installation_SonarQube.md) | installation Debian, Docker, stack SonarQube |
| [`docs/integration-tailscale.md`](docs/integration-tailscale.md) | Tailscale sur la VM + intégration au workflow |
| [`docs/Procedure_SonarQube.odt`](docs/Procedure_SonarQube.odt) | compte-rendu bureautique |
| [`sonar-project.properties`](../sonar-project.properties) | configuration du scanner et Quality Gate |
| [`../.github/workflows/ap2-SonarQube.yml`](../.github/workflows/ap2-SonarQube.yml) | workflow CI/CD |
