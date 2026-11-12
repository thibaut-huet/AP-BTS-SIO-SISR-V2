# FICHE DE PROCÉDURE TECHNIQUE — BTS SIO (Option SISR)

---

## 📌 En-tête & Informations Générales

| Métadonnée | Information |
| :--- | :--- |
| **Intitulé de la procédure** | Déploiement, configuration et automatisation de la protection antivirale Linux avec ClamAV |
| **Domaine / Contexte** | Sécurité des systèmes d'information, administration système Linux |
| **Bloc de compétences SIO** | **Bloc 1** : Support et mise à disposition de services informatiques<br>**Bloc 2** : Administration des systèmes et des réseaux<br>**Bloc 3** : Cybersécurité des services informatiques |
| **Auteur / Candidat** | Étudiant BTS SIO |
| **Système d'exploitation cible** | Debian GNU/Linux 12 (Bookworm) |
| **Outils & Services** | ClamAV (`clamscan`, `clamd`, `clamonacc`), ClamUI, Cron, Systemd |
| **Machine / Environnement** | Machine hôte : `userdebian` — Comptes : `root` & `debianuser` |
| **Ressource de référence** | [Guide IT-Connect : ClamAV - Installer et configurer un antivirus sur Linux](https://www.it-connect.fr/guide-clamav-installer-et-configurer-un-antivirus-sur-linux/) |

---

## 🎯 1. Contexte & Objectifs

Dans le cadre de la sécurisation des infrastructures Linux (serveurs de fichiers, dépôts applicatifs web, répertoires partagés), la mise en place d'une solution de détection antivirale est essentielle afin d'empêcher l'introduction et la prolifération de fichiers corrompus ou malveillants.

### Objectifs opérationnels :
1. **Initialisation du moteur :** Installer et démarrer le démon d'analyse en arrière-plan `clamav-daemon`.
2. **Qualification opérationnelle :** Valider la chaîne de détection à l'aide de la chaîne de test normalisée non destructrice **EICAR**.
3. **Automatisation métier (script Bash) :** Mettre en œuvre un script d'analyse pour isoler automatiquement les pièces jointes/CV téléversés sur un serveur web en triant les fichiers sains (`safe`) et infectés (`infected`).
4. **Planification Cron :** Programmer l'exécution périodique du script via la `crontab`.
5. **Protection temps réel (On-Access) :** Configurer `clamonacc` via le sous-système noyau `fanotify` pour surveiller à la volée le dossier de téléchargement utilisateur et isoler toute menace dans `/var/quarantine`.
6. **Planification avancée Systemd :** Créer un couple de fichiers Systemd (`.service` et `.timer`) pour ordonnancer un scan hebdomadaire basse priorité de `/home`.
7. **Administration graphique (ClamUI) :** Déployer l'interface moderne ClamUI pour simplifier l'audit et la mise à jour des définitions virales.

---

## 🛠️ 2. Architecture & Prérequis

- Machine Debian GNU/Linux avec privilèges d'administration (`root` ou groupe `sudo`).
- Connexion réseau pour les dépôts APT et le protocole de mise à jour virale (`freshclam`).
- Espace de stockage partitionné pour accueillir les journaux (`/var/log/clamav/`) et la quarantaine (`/var/quarantine/`).

---

## 📝 3. Étapes de Réalisation Détaillées

### Étape 1 : Activation et contrôle du service ClamAV Daemon

Après l'installation des paquets `clamav` et `clamav-daemon`, nous activons et démarrons le service démon afin qu'il charge les signatures virales en mémoire vive :

```bash
systemctl enable --now clamav-daemon
systemctl status clamav-daemon
```

![Activation et statut du démon ClamAV](images/Capture%20d'écran%202026-11-12%20094838.png)

> **Observation :** Le démon est correctement initialisé (`active (running)`). Le processus `/usr/sbin/clamd --foreground=true` est actif et écoute sur son socket local `/run/clamav/clamd.ctl`.

---

### Étape 2 : Test de détection unitaire avec la signature standard EICAR

Afin de qualifier l'antivirus sans manipuler de logiciel malveillant réel, nous générons un fichier contenant la chaîne standard de test international EICAR :

```bash
echo 'X50!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > eicar.txt
```

![Génération du fichier test EICAR](images/Capture%20d'écran%202026-11-12%20095511.png)

Nous lançons ensuite une analyse immédiate avec suppression automatique en cas d'infection :

```bash
clamscan --infected --remove --recursive eicar.txt
```

![Détection et suppression par clamscan](images/Capture%20d'écran%202026-11-12%20095632.png)

> **Résultat :** Le fichier `/root/eicar.txt` est immédiatement identifié avec la signature `Eicar-Signature FOUND` puis supprimé (`Removed.`). Le bilan du scan affiche 1 fichier scanné, 1 fichier infecté.

---

### Étape 3 : Automatisation du traitement des dépôts de fichiers (Script Bash)

Dans une architecture web recevant des dépôts externes (exemple : espace de recrutement ou téléversement de CV), les fichiers ne doivent pas être accessibles publiquement sans analyse préalable.

#### 3.1 Création de l'arborescence des flux
```bash
cd /var/www/data
mkdir cv_incoming cv_safe cv_infected
```

![Création des répertoires de tri](images/Capture%20d'écran%202026-11-12%20103320.png)

#### 3.2 Écriture du script `scan_cvs.sh`
Un script shell d'automatisation analyse chaque élément du dossier tampon `cv_incoming` et oriente le fichier selon le code retour (`ret`) de `clamscan` :
- Code `0` : Fichier intègre -> déplacement vers `cv_safe/`.
- Code `1` : Signature malveillante détectée -> déplacement vers `cv_infected/`.
- Code `*` : Erreur de lecture/scan -> mise en quarantaine préventive vers `cv_infected/`.

```bash
nano scan_cvs.sh
```

```bash
#!/bin/bash
INCOMING="/var/www/data/cv_incoming"
SAFE="/var/www/data/cv_safe"
INFECTED="/var/www/data/cv_infected"
LOG="/var/log/clamav/scan_cvs.log"

mkdir -p "$SAFE" "$INFECTED"

# Pour chaque fichier dans le répertoire de dépôt
for file in "$INCOMING"/*; do
    [ -e "$file" ] || continue

    # Scan du fichier : on récupère la sortie ET le code retour
    result=$(clamscan --stdout "$file" 2>&1)
    ret=$?

    echo "$(date '+%F %T') - $result" >> "$LOG"

    # En fonction du code retour de la commande
    case "$ret" in
        0)
            # Pas de virus trouvé
            mv -- "$file" "$SAFE"/
            ;;
        1)
            # Au moins un virus trouvé
            mv -- "$file" "$INFECTED"/
            ;;
        *)
            # Erreur lors du scan, mise en quarantaine par prudence
            mv -- "$file" "$INFECTED"/
            ;;
    esac
done
```

![Contenu du script Bash scan_cvs.sh - partie 1](images/Capture%20d'écran%202026-11-12%20103342.png)
![Contenu du script Bash scan_cvs.sh - partie 2](images/Capture%20d'écran%202026-11-12%20103356.png)

#### 3.3 Attribution des droits et test fonctionnel
```bash
chmod +x scan_cvs.sh
sh scan_cvs.sh
ls cv_safe/
```

![Validation du traitement d'un fichier sain](images/Capture%20d'écran%202026-11-12%20103458.png)

> **Résultat :** Le fichier de test sain `ok.txt` a été correctement analysé et déplacé dans `cv_safe/`.

---

### Étape 4 : Ordonnancement régulier via Crontab

Pour exécuter le script en continu en arrière-plan sans intervention humaine, nous configurons la table cron de l'administrateur :

```bash
sudo crontab -e
```

![Configuration de la crontab administrateur](images/Capture%20d'écran%202026-11-12%20104311.png)

Ajout de la ligne d'exécution récurrente (ex: toutes les 5 minutes) :
```cron
*/5 * * * * /bin/bash /var/www/data/scan_cvs.sh >/dev/null 2>&1
```

---

### Étape 5 : Protection en Temps Réel (On-Access Scanning avec `clamonacc`)

La commande standard `clamscan` fonctionne à la demande. Pour intercepter les fichiers dès leur écriture sur le disque (protection active), nous déployons `clamonacc`.

#### 5.1 Paramétrage du fichier `/etc/clamav/clamd.conf`
Nous configurons les exclusions obligatoires pour éviter les boucles d'interception infinies (exclure l'utilisateur `clamav` et l'UID root), limitons la taille maximale et spécifions le dossier à surveiller :

```ini
OnAccessMaxFileSize 5M
OnAccessExcludeRootUID yes
OnAccessPrevention yes
OnAccessIncludePath /home/debianuser/Téléchargements
OnAccessExcludeUname clamav
OnAccessExcludePath /proc
OnAccessExcludePath /dev
OnAccessExcludePath /sys
```

![Configuration du clamd.conf pour clamonacc](images/Capture%20d'écran%202026-11-12%20105944.png)

#### 5.2 Création du dossier de quarantaine sécurisé
```bash
sudo mkdir -p /var/quarantine
sudo chmod 700 /var/quarantine
```

#### 5.3 Création du service Systemd `clamonacc.service`
Nous encapsulons `clamonacc` dans un service système persistant `/etc/systemd/system/clamonacc.service` :

```ini
[Unit]
Description=ClamAV On-Access Scanner
Requires=clamav-daemon.service
After=clamav-daemon.service syslog.target network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/clamonacc -F --fdpass --log=/var/log/clamav/clamonacc.log --move=/var/quarantine
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now clamonacc.service
ps aux | grep clamonacc
```

![Démarrage du service clamonacc et vérification du processus](images/Capture%20d'écran%202026-11-12%20113425.png)

> **Contrôle :** Le journal `/var/log/clamav/clamonacc.log` confirme l'écoute active : `ClamInotif: watching '/home/debianuser/Téléchargements' (and all sub-directories)`.

#### 5.4 Preuve de concept : neutralisation en temps réel d'une menace
Sous l'utilisateur non privilégié `debianuser`, nous téléchargeons l'échantillon EICAR dans son dossier `Téléchargements` :

```bash
sudo -u debianuser wget -O /home/debianuser/Téléchargements/eicar.txt https://secure.eicar.org/eicar.com.txt
```

![Téléchargement et interception immédiate](images/Capture%20d'écran%202026-11-12%20113707.png)

Contrôle dans l'espace de quarantaine :
```bash
ls /var/quarantine/
# Affichage : eicar.txt
```

> **Résultat :** Dès la fin de l'écriture réseau par `wget`, le hook `fanotify` a notifié `clamonacc`, qui a identifié le malware et l'a instantanément extrait vers `/var/quarantine/`.

---

### Étape 6 : Planification hebdomadaire avec Systemd Timer

Contrairement à Cron, les timers Systemd offrent une gestion fine des dépendances, de l'historique et des priorités d'E/S (évite les ralentissements serveur pendant les heures de production).

#### 6.1 Fichier service `/etc/systemd/system/scan-home-hebdo.service`
```ini
[Unit]
Description=Scan ClamAV hebdomadaire de /home
Requires=clamav-daemon.service
After=clamav-daemon.service

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/clamscan --recursive --infected --move=/var/quarantine /home
SuccessExitStatus=1
```

![Configuration du service systemd hebdomadaire](images/Capture%20d'écran%202026-11-12%20114045.png)

- `Nice=19` : Priorité CPU la plus basse.
- `IOSchedulingClass=idle` : Ne lit les disques que lorsque le système est inactif.
- `SuccessExitStatus=1` : Évite que Systemd ne considère le service en erreur quand ClamAV trouve un virus (code retour 1).

#### 6.2 Fichier timer `/etc/systemd/system/scan-home-hebdo.timer`
```ini
[Unit]
Description=Timer pour le scan hebdomadaire ClamAV de /home

[Timer]
OnCalendar=Sun *-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Activation et inspection du planning :
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now scan-home-hebdo.timer
systemctl list-timers scan-home-hebdo.timer
```

![Vérification de l'activation du timer systemd](images/Capture%20d'écran%202026-11-12%20114550.png)

> **Contrôle :** Le timer est actif et programmé pour le dimanche à 02:00:00.

---

### Étape 7 : Déploiement de l'interface graphique ClamUI

Pour une administration conviviale et le contrôle visuel des définitions antivirales, les paquets de **ClamUI** sont installés :

```bash
apt install ./clamui_0.6.0_amd64.deb ./clamui-privileged-helper_0.6.0_amd64.deb
```

![Installation des paquets ClamUI via APT](images/Capture%20d'écran%202026-11-12%20123334.png)

![Interface ClamUI et gestion des bases virales](images/Capture%20d'écran%202026-11-12%20123351.png)

L'interface ClamUI permet :
- De visualiser l'état du service de mise à jour automatique `freshclam`.
- De forcer la mise à jour des définitions virales en cas d'urgence (`bytecode.cvd`).
- De déclencher des scans ponctuels et de consulter graphiquement la quarantaine.

---

## 📋 4. Grille de Correspondance — Compétences BTS SIO

| Bloc de compétences | Sous-compétence visée | Justification technique dans la procédure |
| :--- | :--- | :--- |
| **Bloc 1 : Support & services** | **Gérer le patrimoine informatique** | Traitement, sécurisation et inventaire des fichiers utilisateurs et applicatifs. |
| **Bloc 2 : Administration Systèmes** | **Déployer des services réseau et système** | Création de démons Systemd (`clamonacc`), de scripts Bash automatisés et de timers. |
| **Bloc 2 : Administration Systèmes** | **Superviser les services** | Mise en place de journaux centralisés (`/var/log/clamav/`) et planification des tâches. |
| **Bloc 3 : Cybersécurité** | **Protéger les données et les équipements** | Mise en quarantaine temps réel automatique des fichiers infectés (`/var/quarantine`). |
| **Bloc 3 : Cybersécurité** | **Garantir la disponibilité et l'intégrité** | Limitation des ressources allouées aux scans (`Nice`, `IOSchedulingClass`) pour préserver les performances. |

---

## 📈 5. Bilan, Difficultés Rencontrées & Pistes d'Évolution

### Difficultés rencontrées et solutions apportées :
1. **Erreur d'exécution de `clamonacc` au premier lancement :** Le service refusait de démarrer car aucun utilisateur n'était exclu (`OnAccessExcludeRootUID` / `OnAccessExcludeUname`). La directive a été renseignée dans `clamd.conf` pour éviter une boucle infinie de scanning sur les fichiers ouverts par l'antivirus lui-même.
2. **Gestion du code retour de `clamscan` dans Systemd :** Par défaut, Systemd considère qu'un code retour différent de 0 est un échec. L'ajout de `SuccessExitStatus=1` permet d'éviter les fausses alertes système lorsqu'une menace est détectée et traitée.

### Pistes d'évolution :
- **Notification mail immédiate :** Ajout d'une commande `mail` ou `curl` vers un webhook Discord/Slack dans le script pour alerter le RSSI / administrateur en temps réel.
- **Centralisation des logs :** Transmission des journaux de scan vers un serveur de log centralisé (ex: rsyslog vers Grafana Loki ou Graylog).

