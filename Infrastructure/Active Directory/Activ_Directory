# Installation et Configuration d'un Active Directory

**Auteur :** Thibaut HUET  
**Date :** Juin 2026  
**Contexte :** Projet AP BTS SIO — Infrastructure GSB

---

## Table des matières

1. [Introduction](#1-introduction)
2. [Installation de l'environnement virtuel](#2-installation-de-lenvironnement-virtuel)
3. [Installation de Windows Server](#3-installation-de-windows-server)
4. [Configuration IP statique](#4-configuration-ip-statique)
5. [Installation du rôle Active Directory](#5-installation-du-rôle-active-directory)
6. [Promotion en contrôleur de domaine](#6-promotion-en-contrôleur-de-domaine)
7. [Création des unités d'organisation (OU)](#7-création-des-unités-dorganisation-ou)
8. [Création des utilisateurs et des groupes](#8-création-des-utilisateurs-et-des-groupes)
9. [Intégration d'un poste client au domaine](#9-intégration-dun-poste-client-au-domaine)
10. [Tests et validation](#10-tests-et-validation)
11. [Problèmes rencontrés et solutions](#11-problèmes-rencontrés-et-solutions)
12. [Conclusion](#12-conclusion)

---

## 1. Introduction

Vous venez d'être recruté comme technicien système et réseau dans une PME appelée **TechnoLab**. L'entreprise souhaite centraliser l'administration de ses utilisateurs et postes informatiques grâce à un serveur Active Directory.

### Objectif

Créer un Active Directory fonctionnel permettant la gestion centralisée des identités et des accès.

### Ressources utilisées

- **VMware Workstation Player** (hyperviseur de type 2)
- **ISO Windows Server 2022** (pour le contrôleur de domaine)
- **ISO Windows 10/11** (pour le poste client test)

### Déroulement

1. Installer un serveur Windows Server
2. Mettre en place un domaine Active Directory
3. Créer les unités d'organisation et les comptes utilisateurs
4. Intégrer un poste client Windows au domaine
5. Tester le fonctionnement global
6. Rédiger un rapport technique détaillé

---

## 2. Installation de l'environnement virtuel

### Installation de l'hyperviseur

Le choix s'est porté sur **VMware Workstation Player** comme hyperviseur de type 2. L'installation s'est déroulée de manière standard sur la machine physique (Dell Latitude 7420, Intel Core i7-11th gen, 16 Go RAM).

### Création des Machines Virtuelles

Deux machines virtuelles distinctes ont été créées :

| Paramètre | VM Serveur (SRV-AD) | VM Client (CLIENT01) |
|---|---|---|
| Système d'exploitation | Windows Server 2022 | Windows 10/11 Pro |
| Mémoire vive (RAM) | 4 Go | 2 à 4 Go |
| Processeur (CPU) | 2 vCPU | 1 ou 2 vCPU |
| Espace disque | 20 Go | 20 Go ou plus |
| Type de réseau | NAT | NAT (identique au serveur) |

![Création et paramétrage de la VM serveur SRV-AD](images/image12.jpg)

---

## 3. Installation de Windows Server

### Démarrage de l'installation

Amorcer la machine SRV-AD sur l'image ISO de Windows Server 2022.

### Sélection de la version

Choisir **Windows Server 2022 Standard (Desktop Experience)** afin de disposer de l'interface graphique nécessaire à l'administration.

![Sélection de la version Windows Server 2022](images/image2.png)

### Partitionnement

Partitionner le disque virtuel de 20 Go et exécuter l'assistant d'installation.

![Partitionnement du disque virtuel](images/image3.jpg)

### Définition du mot de passe Administrateur local

Lors du premier démarrage, définir le mot de passe du compte Administrateur local :

- **Mot de passe :** `Serveur2022`

### Renommage du serveur

Pour respecter la nomenclature de l'arborescence cible, le serveur doit être renommé :

1. Accéder au **Gestionnaire de serveur** > **Serveur local**
2. Cliquer sur le **Nom de l'ordinateur**
3. Modifier la valeur par **SRV-AD**
4. Redémarrer la machine

---

## 4. Configuration IP statique

Un contrôleur de domaine doit obligatoirement posséder une **configuration IP statique (fixe)** pour que les clients du réseau puissent le solliciter de manière fiable. Le serveur faisant également office de serveur DNS pour le domaine, son adresse de DNS préféré pointe sur lui-même.

### Paramètres réseau appliqués

| Paramètre | Valeur |
|---|---|
| Adresse IP | `192.168.10.10` |
| Masque de sous-réseau | `255.255.255.0` |
| Passerelle par défaut | `192.168.10.1` |
| DNS préféré | `192.168.10.10` (boucle locale) |

### Vérification

Exécuter `ipconfig /all` dans l'invite de commandes Windows pour valider la configuration.

![Vérification de la configuration réseau avec ipconfig /all](images/image4.png)

---

## 5. Installation du rôle Active Directory

Le déploiement des fonctionnalités Active Directory s'effectue depuis le **Gestionnaire de serveur** :

1. Cliquer sur **Ajouter des rôles et fonctionnalités**
2. Sélectionner le type d'installation basée sur un rôle ou une fonctionnalité
3. Cocher le rôle **Services de domaine Active Directory (AD DS)**
4. Valider l'ajout des fonctionnalités requises de gestion
5. Lancer l'installation

![Ajout du rôle Services de domaine Active Directory](images/image5.png)

![Validation des fonctionnalités requises pour AD DS](images/image6.png)

![Installation du rôle AD DS en cours](images/image7.png)

---

## 6. Promotion en contrôleur de domaine

Une fois le rôle installé, une notification dans le Gestionnaire de serveur invite à promouvoir le serveur en contrôleur de domaine.

### Configuration du domaine

| Paramètre | Valeur |
|---|---|
| Option de déploiement | Ajouter une nouvelle forêt |
| Nom de domaine racine | `technolab.local` |
| Niveau fonctionnel | Windows Server 2016 (ou supérieur) |
| Mot de passe DSRM | Saisir un mot de passe sécurisé |

![Assistant de promotion en contrôleur de domaine](images/image8.png)

### Finalisation

Après finalisation de l'assistant, le serveur redémarre automatiquement pour appliquer les modifications d'annuaire.

![Redémarrage après la promotion](images/image9.jpg)

---

## 7. Création des unités d'organisation (OU)

L'organisation des objets au sein de l'annuaire a été structurée via la console **Utilisateurs et ordinateurs Active Directory** afin de séparer les services de l'entreprise TechnoLab.

### Arborescence logique

```
technolab.local
├── Direction
├── Comptabilite
├── Informatique
├── Utilisateurs
└── Postes
```

Chaque OU permettra d'appliquer des **GPO spécifiques** (restrictions d'accès, politiques de sécurité, fonds d'écran, etc.).

---

## 8. Création des utilisateurs et des groupes

### Création des groupes de sécurité

Trois groupes de sécurité globaux ont été créés :

| Groupe | Description |
|---|---|
| `G_Direction` | Direction de l'entreprise |
| `G_Compta` | Service comptable |
| `G_IT` | Service informatique |

### Création des utilisateurs

Les comptes utilisateurs ont été créés avec des identifiants standardisés (première lettre du prénom + nom complet) :

| Nom complet | Login | Mot de passe initial | Groupe |
|---|---|---|---|
| Alice Martin | `amartin` | `P@ssw0rd123` | G_Direction |
| Hugo Bernard | `hbernard` | `P@ssw0rd123` | G_Compta |
| Sarah Leroy | `sleroy` | `P@ssw0rd123` | G_IT |

> **Note :** Le mot de passe initial sera changé à la première connexion.

![Création des comptes utilisateurs dans l'Active Directory](images/image10.png)

---

## 9. Intégration d'un poste client au domaine

### Configuration réseau du client

La machine virtuelle CLIENT01 (Windows 10/11) doit être configurée sur le **même réseau virtuel** que le serveur. Son serveur DNS doit obligatoirement pointer vers l'adresse IP du contrôleur de domaine.

| Paramètre | Valeur |
|---|---|
| Adresse IP | `192.168.10.20` |
| Masque | `255.255.255.0` |
| DNS | `192.168.10.10` |

### Test de connectivité

Effectuer un `ping 192.168.10.10` depuis le client pour valider la communication réseau.

![Test ping entre le client et le serveur](images/image11.png)

### Jonction au domaine

1. Ouvrir les **Propriétés système** de la machine cliente
2. Cliquer sur **Modifier** (renommer le PC en `CLIENT01` si nécessaire)
3. Cocher la case **Domaine**
4. Renseigner le nom : `technolab.local`
5. Saisir les identifiants du compte `TECHNOLAB\Administrateur`
6. Un message de bienvenue confirme la réussite
7. **Redémarrer** le poste

![Message de bienvenue confirmant la jonction au domaine](images/image12.jpg)

---

## 10. Tests et validation

### Connexion avec un compte domaine

Au redémarrage du client, l'option **Autre utilisateur** permet de s'authentifier avec le compte domaine d'un employé, par exemple : `TECHNOLAB\amartin`.

![Connexion avec un compte domaine](images/image13.jpg)

![Changement de mot de passe à la première connexion](images/image14.jpg)

### Commandes de validation

Exécuter les commandes suivantes pour valider le bon fonctionnement :

```batch
whoami
nslookup technolab.local
net view
```

![Commande whoami — vérification du compte domaine](images/image15.png)

![Commande nslookup — résolution DNS du domaine](images/image16.png)

![Commande net view — liste des ressources du domaine](images/image17.png)

### Vérification dans l'Active Directory

Le poste client apparaît bien visible dans la console d'administration Active Directory.

![Poste client visible dans l'Active Directory](images/image18.png)

![Poste visible dans la console Active Directory](images/image19.png)

### Récapitulatif des commandes

| Commande | Rôle |
|---|---|
| `ipconfig /all` | Afficher la configuration réseau complète |
| `ping 192.168.10.10` | Tester la connectivité réseau |
| `nslookup technolab.local` | Résoudre le nom de domaine via DNS |
| `whoami` | Vérifier que l'utilisateur est bien un compte domaine |
| `net view` | Lister les ressources partagées visibles sur le domaine |

---

## 11. Problèmes rencontrés et solutions

### Problème : Impossible de changer le mot de passe via l'Active Directory

**Problème :** Impossible de modifier le mot de passe d'un utilisateur depuis l'Active Directory.

**Solution :** L'utilisateur était connecté avec la session locale créée lors de l'installation de Windows, avant la jonction au domaine. Il faut se connecter avec un compte domaine (`TECHNOLAB\amartin`) pour que les modifications s'appliquent correctement.

---

## 12. Conclusion

Ce TP a permis de comprendre de manière concrète le fonctionnement d'une architecture client-serveur en entreprise. La manipulation d'un hyperviseur pour isoler un réseau virtuel et le paramétrage manuel des couches réseau (IP, DNS) ont renforcé les compétences pratiques en administration système.

### Bénéfices apportés par Active Directory

- **Centralisation :** Un seul point d'administration pour gérer l'ensemble des accès et l'authentification
- **Sécurité :** Application de politiques de mots de passe globalisées, gestion stricte des privilèges via groupes de sécurité
- **Évolutivité :** Facilité d'ajouter de nouveaux collaborateurs ou de renouveler le parc informatique

### Recommandations

- Toujours utiliser une **IP fixe** sur un contrôleur de domaine
- Ne jamais utiliser un **DNS externe** sur un contrôleur de domaine
- **Sauvegarder régulièrement** le serveur (état système + Active Directory)
- Utiliser des **mots de passe complexes**
- Créer des **unités d'organisation (OU)** pour structurer les objets
