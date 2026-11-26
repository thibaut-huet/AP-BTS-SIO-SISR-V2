# AP_2 - Sécurisation et analyse de la qualité de code de l'Infrastructure as Code (AP_1) avec SonarQube

**Auteur :** Thibaut HUET  
**Contexte :** BTS SIO option SISR - Atelier Professionnel  
**Projet rattaché :** Sécurisation et intégration continue pour l'AP_1 (*Migration de l'Active Directory RedOne vers Azure*)  
**Plateforme d'analyse :** SonarQube Community Edition (Docker / PostgreSQL 16)  
**Environnement d'hébergement :** VM Debian sur Proxmox VE  

---

## 1. Présentation et Contexte de l'AP_2

Dans le cadre de l'**AP_1**, l'entreprise RedOne a déployé et migré son infrastructure Active Directory vers Microsoft Azure en adoptant une approche moderne de **DevOps** et d'**Infrastructure as Code (IaC)** reposant sur des templates **Bicep** et des pipelines **GitHub Actions**.

Cependant, l'adoption de l'IaC expose l'infrastructure à de nouveaux risques de sécurité et de non-conformité :
- Mauvaises configurations réseau (ports ouverts, NSG trop permissifs).
- Absence de bonnes pratiques sur les ressources Azure ou les scripts.
- Présence potentielle de secrets ou de données sensibles codés en dur.
- Dette technique et manque de maintenabilité dans le code d'infrastructure.

L'objectif de cet **AP_2** est de mettre en place une démarche **DevSecOps** en intégrant **SonarQube** comme solution d'analyse statique de code (SAST) et de sécurité pour auditer, analyser et sécuriser l'ensemble du code produit dans **AP_1**.

---

## 2. Objectifs du projet

1. **Héberger et déployer une instance SonarQube dédiée** :
   - Mise en œuvre sur une VM Debian hébergée sur l'hyperviseur Proxmox.
   - Conteneurisation avec **Docker** et **Docker Compose**, adossée à une base **PostgreSQL 16**.
2. **Sécuriser et auditer le code d'infrastructure (AP_1)** :
   - Analyser les templates Azure Bicep / ARM, scripts PowerShell/Bash, configurations YAML et workflows CI/CD.
   - Identifier les vulnérabilités, failles de sécurité, bugs et "code smells".
3. **Mettre en place des Quality Gates (Portes de qualité)** :
   - Définir des seuils de validation stricts avant tout déploiement en production.
   - Bloquer les régressions ou configurations non sécurisées.
4. **Intégration dans la chaîne DevOps (CI/CD)** :
   - Connecter l'analyseur SonarQube (SonarScanner) aux pipelines GitHub Actions de l'AP_1 pour un contrôle automatisé à chaque `push` ou `pull request`.

---

## 3. Architecture globale

```text
+--------------------------------------------------------------------------+
|                            PROXMOX VE (On-Premise)                       |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  | VM Debian (10.2.41.4)                                              |  |
|  |                                                                    |  |
|  |   +--------------------------+      +--------------------------+   |  |
|  |   |    SonarQube Community   | <--> |      PostgreSQL 16       |   |  |
|  |   |       (Port 9000)        |      |      (Port 5432)         |   |  |
|  |   +--------------------------+      +--------------------------+   |  |
|  |                ^                                                   |  |
|  +----------------|---------------------------------------------------+  |
+-------------------|------------------------------------------------------+
                    |
                    | Analyses de code (SonarScanner / API / GitHub Actions)
                    |
+-------------------|------------------------------------------------------+
|                   v                                                      |
|   Code source & Déploiements AP_1 (GitHub / Azure)                       |
|   - Modules Bicep (VNet, VM, NSG, Key Vault...)                          |
|   - Scripts PowerShell & Bash                                            |
|   - Workflows CI/CD GitHub Actions                                       |
+--------------------------------------------------------------------------+
```

---

## 4. Ce que démontre ce livrable (Compétences SISR)

| Axe | Mise en œuvre |
|---|---|
| **Sécurité & DevSecOps** | Analyse statique de code (SAST), détection des failles de sécurité et mauvaises configurations IaC. |
| **Conteneurisation** | Déploiement multi-conteneurs avec Docker Compose (SonarQube + PostgreSQL 16), gestion des volumes persistants et du réseau Docker. |
| **Administration Système Linux** | Optimisation du noyau Debian (`sysctl`, mémoire virtuelle `vm.max_map_count`, descripteurs de fichiers), gestion des services et permissions. |
| **Intégration continue** | Automatisation des analyses de qualité et contrôle via Quality Gate dans la chaîne CI/CD de l'AP_1. |
| **Exploitation & Maintenance** | Surveillance des conteneurs, gestion des logs, procédures de sauvegarde des volumes de base de données. |

---

## 5. Structure du dossier AP_2

- [`Installation_SonarQube.md`](Installation_SonarQube.md) : Procédure pas à pas détaillée pour préparer Debian, installer Docker et déployer la stack SonarQube.
- [`docker/docker-compose.yml`](docker/docker-compose.yml) : Fichier de définition des services Docker (SonarQube Community + PostgreSQL 16).
- [`Procedure_SonarQube.odt`](Procedure_SonarQube.odt) : Documentation et compte-rendu au format bureautique.

---

## 6. Guide rapide de déploiement

Pour déployer rapidement l'environnement SonarQube :

1. Consultez la procédure complète dans [`Installation_SonarQube.md`](Installation_SonarQube.md).
2. Configurez les paramètres du noyau Linux (`vm.max_map_count`).
3. Lancez les conteneurs :
   ```bash
   cd docker
   docker compose up -d
   ```
4. Accédez au tableau de bord SonarQube sur `http://<IP_DEBIAN>:9000` (identifiants initiaux : `admin` / `admin`).
