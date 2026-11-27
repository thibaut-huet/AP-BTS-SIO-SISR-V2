# AP_2 - Sécurisation et analyse de la qualité de code de l'IaC de l'AP_1

**Auteur :** Thibaut HUET  
**Contexte :** BTS SIO option SISR - Atelier Professionnel  
**Projet rattaché :** AP_1 (*Migration de l'Active Directory RedOne vers Azure*)  
**Plateforme d'analyse :** SonarQube Community Build (Docker / PostgreSQL 16)  
**Hébergement :** VM Debian sur Proxmox VE, accessible uniquement via Tailscale  

---

## 1. Le projet en bref

L'**AP_1** a consisté à migrer l'Active Directory de RedOne vers Azure avec une
démarche **DevOps / Infrastructure as Code** : templates **Bicep**, scripts
**PowerShell**, pipelines **GitHub Actions**.

L'**AP_2** est un projet **distinct** qui sécurise cette démarche. Il ne déploie
aucune ressource Azure et ne modifie pas l'infrastructure de l'AP_1 : il ajoute
une chaîne **DevSecOps** qui analyse le code produit par l'AP_1 et bloque les
régressions de qualité ou de sécurité.

Le lien entre les deux projets est le **code audité**, pas l'infrastructure.

| | AP_1 | AP_2 |
|---|---|---|
| **Objet** | migrer l'AD vers Azure | auditer le code de l'AP_1 |
| **Livrable** | DC Azure opérationnel | SonarQube + pipeline d'analyse |
| **Réseau** | Tailscale pour joindre le DC | Tailscale pour joindre SonarQube |
| **Résultat** | réplication validée | Quality Gate bloquante |

## 2. Problématique

L'adoption de l'IaC déplace une partie des risques vers le code lui-même :

- configurations réseau trop permissives (ports ouverts, NSG) ;
- ressources Azure mal paramétrées ;
- secrets ou données sensibles codés en dur ;
- dette technique et manque de maintenabilité ;
- absence de contrôle automatique avant déploiement.

Un déploiement réussi ne garantit donc pas un déploiement **sûr**. L'AP_2
apporte ce contrôle manquant : une analyse statique (SAST) exécutée à chaque
`push` et à chaque `pull request`.

## 3. Objectifs

1. **Héberger une instance SonarQube dédiée** sur une VM Debian Proxmox,
   conteneurisée avec Docker Compose et adossée à PostgreSQL 16.
2. **Auditer le code de l'AP_1** : templates Bicep compilés en ARM, scripts,
   workflows et fichiers de configuration.
3. **Définir une Quality Gate** : seuils de qualité qui conditionnent le succès
   du pipeline.
4. **Automatiser l'analyse** dans GitHub Actions, avec un accès privé au
   serveur SonarQube par **Tailscale**.

## 4. Périmètre

| Élément | Statut | Remarque |
|---|---|---|
| Instance SonarQube + PostgreSQL | **déployé** | Docker Compose sur VM Debian |
| Accès privé via Tailscale | **déployé** | aucune IP publique exposée |
| Workflow GitHub Actions | **déployé** | `.github/workflows/ap2-SonarQube.yml` |
| Compilation Bicep → ARM | **déployé** | format réellement analysé par SonarQube |
| Quality Gate bloquante | **configurée** | `sonar.qualitygate.wait=true` |
| Modification de l'infrastructure AP_1 | **hors périmètre** | AP_2 audite, ne déploie pas |
| Haute disponibilité de SonarQube | **hors périmètre** | instance unique de laboratoire |

## 5. Architecture

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

Aucun port n'est publié sur Internet. Le runner GitHub rejoint le tailnet le
temps du job, puis son nœud est supprimé automatiquement.

## 6. Choix techniques

| Choix | Justification |
|---|---|
| **SonarQube Community Build** | solution SAST complète, gratuite et auto-hébergeable, adaptée à un laboratoire |
| **Docker Compose** | déploiement reproductible de SonarQube et PostgreSQL en deux services |
| **PostgreSQL 16** | base supportée par SonarQube, séparée du conteneur applicatif |
| **Tailscale** | accès privé sans IP publique ni reverse proxy, cohérent avec l'AP_1 |
| **GitHub Actions** | même chaîne CI/CD que l'AP_1, secrets natifs, runner standard |
| **Compilation Bicep → ARM** | SonarQube analyse l'ARM JSON, pas le Bicep source ; la compilation rend l'IaC réellement auditable |
| **Quality Gate bloquante** | l'analyse devient un contrôle qui empêche la fusion, pas un simple rapport |

## 7. Fonctionnement de la chaîne d'analyse

À chaque `push` sur `main` ou à chaque `pull request`, le workflow :

1. récupère le dépôt avec son historique complet (nécessaire au calcul du
   *new code*) ;
2. se connecte au tailnet avec un nœud **éphémère** `tag:ci`, via un client
   OAuth Tailscale ;
3. installe le CLI Bicep et compile `AP_1/bicep/main.bicep` en ARM ;
4. envoie l'analyse à SonarQube avec le SonarScanner ;
5. attend le verdict de la **Quality Gate** et fait échouer le job si elle
   n'est pas respectée.

Le scanner lit sa configuration dans `sonar-project.properties`, à la racine
du dépôt. Le workflow est lui aussi à la racine, dans `.github/workflows/`,
seul emplacement lu par GitHub Actions.

## 8. Démarche de sécurité

- **Aucune IP publique** sur la VM SonarQube ; le port 9000 reste dans le
  tailnet.
- **Moindre privilège** : le client OAuth ne peut créer que des nœuds
  `tag:ci`, et ces nœuds ne joignent que le port 9000 de la VM.
- **Aucun secret dans Git** : tout passe par les secrets GitHub.
- **Nœuds éphémères** : le runner est retiré du tailnet à la fin du job.
- **Contrôle bloquant** : une Quality Gate en échec empêche la fusion.

## 9. Résultats et indicateurs

| Indicateur | Valeur attendue |
|---|---|
| Conteneurs | `sonarqube` et `sonarqube-db` actifs |
| Accès | `http://100.105.124.41:9000` depuis le tailnet |
| Projet analysé | `redone-ap1-iac` |
| Sources | `AP_1/` + `build/arm/main.json` |
| Quality Gate | `Passed` |
| Pipeline | job GitHub Actions vert |

## 10. Limites et perspectives

- **Langages réellement analysés** : SonarQube Community Build couvre l'ARM,
  Docker, les secrets et de nombreux langages applicatifs, mais **pas** le
  Bicep brut, **pas** PowerShell et **pas** YAML. D'où la compilation Bicep →
  ARM ; le reste s'appuie sur `bicep lint` et les contrôles natifs de l'AP_1.
- **Instance unique** : pas de haute disponibilité ; la VM et les volumes
  Docker constituent un point unique de défaillance.
- **Sauvegarde manuelle** : les volumes `postgresql_data` et `sonarqube_data`
  ne sont pas sauvegardés automatiquement.
- **Dépendance à Tailscale** : sans tailnet opérationnel, le runner ne peut
  pas joindre SonarQube.
- **Perspectives** : analyse PowerShell via un plugin ou `PSScriptAnalyzer`,
  sauvegarde planifiée des volumes, déploiement de SonarQube par IaC, ajout
  d'un second nœud pour la disponibilité.

## 11. Compétences SISR mobilisées

| Axe | Mise en œuvre |
|---|---|
| **Sécurité & DevSecOps** | SAST, détection de secrets, Quality Gate bloquante |
| **Conteneurisation** | Docker Compose multi-services, volumes persistants, réseau Docker |
| **Administration Linux** | `sysctl` (`vm.max_map_count`), Docker Engine, permissions |
| **Réseau & accès distant** | Tailscale/WireGuard, client OAuth, ACL par tag |
| **CI/CD** | GitHub Actions, secrets, compilation Bicep, SonarScanner |
| **Exploitation** | logs, supervision des conteneurs, sauvegarde des volumes |

## 12. Documentation

Le projet est documenté en trois volets, dans l'ordre chronologique de mise en
œuvre :

| Document | Contenu |
|---|---|
| [`docs/01-installation-sonarqube.md`](docs/01-installation-sonarqube.md) | installation de Debian, Docker et de la stack SonarQube |
| [`docs/02-integration-tailscale.md`](docs/02-integration-tailscale.md) | accès privé, client OAuth et ACL Tailscale |
| [`docs/03-workflow-github-actions.md`](docs/03-workflow-github-actions.md) | projet SonarQube, secrets et pipeline CI/CD |
| [`docker/docker-compose.yml`](docker/docker-compose.yml) | stack SonarQube + PostgreSQL 16 |
| [`sonar-project.properties`](../sonar-project.properties) | configuration du scanner et Quality Gate |
| [`../.github/workflows/ap2-SonarQube.yml`](../.github/workflows/ap2-SonarQube.yml) | workflow CI/CD |

## 13. Structure du dépôt

```text
AP_2/
├── README.md                                  # présentation du projet
├── docs/
│   ├── 01-installation-sonarqube.md           # volet 1 : Debian + Docker
│   ├── 02-integration-tailscale.md            # volet 2 : accès privé + OAuth
│   └── 03-workflow-github-actions.md          # volet 3 : projet, secrets, CI
└── docker/
    └── docker-compose.yml                     # SonarQube + PostgreSQL 16

Racine du dépôt (éléments partagés avec l'AP_1) :
├── .github/workflows/ap2-SonarQube.yml        # workflow actif
└── sonar-project.properties                   # configuration du SonarScanner
```
