# Procédure d'installation de SonarQube avec Docker Compose (Debian sur Proxmox)

Ce document détaille l'installation et la configuration de la plateforme d'analyse de code **SonarQube Community Edition** adossée à une base de données **PostgreSQL 16**, conteneurisées avec Docker sur une machine virtuelle **Debian** hébergée sous **Proxmox VE**.

---

## 1. Prérequis & Contexte

- **Environnement hôte** : Machine Virtuelle Debian existante hébergée sur l'hyperviseur Proxmox.
- **Ressources recommandées** :
  - RAM : Au minimum **2 à 4 Go** de mémoire vive libre (Elasticsearch intégré à SonarQube est gourmand en mémoire).
  - vCPU : 2 vCPU minimum.
  - Espace disque : 20 Go recommandés.
- **Accès** : Connexion SSH avec privilèges `sudo` ou `root`.

---

## 2. Configuration système (Noyau et Mémoire Virtuelle)

SonarQube intègre un moteur Elasticsearch qui nécessite une configuration spécifique de la mémoire virtuelle (`vm.max_map_count`) et du nombre maximal de descripteurs de fichiers (`fs.file-max`). Sans cela, le conteneur plantera immédiatement au démarrage.

### Appliquer les paramètres immédiatement
```bash
sudo sysctl -w vm.max_map_count=524288
sudo sysctl -w fs.file-max=131072
```

### Rendre les paramètres persistants au redémarrage
```bash
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.d/99-sonarqube.conf
echo "fs.file-max=131072" | sudo tee -a /etc/sysctl.d/99-sonarqube.conf
sudo sysctl --system
```

### Vérification
Exécutez la commande suivante :
```bash
sysctl vm.max_map_count
```
> **Sortie attendue :** `vm.max_map_count = 524288`

---

## 3. Installation de Docker et Docker Compose

### Étape 3.1 : Nettoyage et dépendances
Supprimez les versions obsolètes ou paquets non officiels, puis installez les outils de base :
```bash
sudo apt-get update
sudo apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc
sudo apt-get install -y ca-certificates curl
```

### Étape 3.2 : Ajout du dépôt officiel Docker
Ajoutez la clé GPG officielle et les dépôts adaptés à votre version de Debian :
```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
```

### Étape 3.3 : Installation de Docker Engine et du plugin Compose
```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Vérification des versions
```bash
docker --version && docker compose version
```

### Étape 3.4 : Gestion des droits non-root (optionnel mais conseillé)
Pour exécuter les commandes `docker` sans devoir utiliser `sudo` :
```bash
sudo usermod -aG docker $USER
newgrp docker
```

---

## 4. Déploiement de SonarQube avec Docker Compose

### Étape 4.1 : Préparation de l'arborescence
Créez un dossier dédié pour héberger la configuration :
```bash
mkdir -p ~/sonarqube && cd ~/sonarqube
```

### Étape 4.2 : Fichier `docker-compose.yml`
Créez le fichier `docker-compose.yml` (ou copiez celui présent dans le dossier [`docker/docker-compose.yml`](docker/docker-compose.yml)) :

```yaml
services:
  sonarqube:
    image: sonarqube:community
    container_name: sonarqube
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: ********
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs
    ports:
      - "9000:9000"
    restart: unless-stopped

  db:
    image: postgres:16-alpine
    container_name: sonarqube-db
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: ********
      POSTGRES_DB: sonar
    volumes:
      - postgresql_data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
  postgresql_data:
```

> ⚠️ **Sécurité** : Pensez à adapter le mot de passe (`SONAR_JDBC_PASSWORD` et `POSTGRES_PASSWORD`) pour votre environnement de production.

---

## 5. Démarrage et suivi des conteneurs

Lancez les conteneurs en arrière-plan :
```bash
docker compose up -d
```

Pour visualiser l'avancement et l'initialisation des logs SonarQube (compter 1 à 2 minutes lors de la première initialisation) :
```bash
docker compose logs -f sonarqube
```
Attendez l'affichage du message indiquant que SonarQube est opérationnel :
> `SonarQube is operational`

---

## 6. Accès à l'interface Web

1. Ouvrez votre navigateur et accédez à l'URL suivante (en remplaçant par l'adresse IP de votre VM Debian) :
   ```text
   http://10.2.41.4:9000
   ```

2. **Identifiants de première connexion par défaut** :
   - **Identifiant** : `admin`
   - **Mot de passe initial** : `********` *(ou le mot de passe défini lors du premier paramétrage)*

3. Lors du premier accès, SonarQube vous demandera de modifier le mot de passe administrateur par défaut.

---

## 7. Commandes utiles d'administration

| Action | Commande |
|---|---|
| Voir l'état des conteneurs | `docker compose ps` |
| Suivre les logs en temps réel | `docker compose logs -f` |
| Arrêter les conteneurs | `docker compose stop` |
| Redémarrer les services | `docker compose restart` |
| Arrêter et détruire les conteneurs | `docker compose down` |
| Sauvegarder les volumes | Les données sont persistées dans les volumes Docker (`postgresql_data`, `sonarqube_data`, etc.) |
