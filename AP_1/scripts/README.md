# Scripts PowerShell - ordre d'exécution

## DC Azure (`azure-dc/`)

| Script | Quand l'exécuter | Automatique ? |
|---|---|---|
| `01-setup-tailscale.ps1` | au déploiement de la VM | oui (extension `01-Tailscale`) |
| `02-join-domain.ps1` | en secours si la jonction échoue | non (l'extension native est utilisée) |
| `03-promote-dc.ps1` | phase 2 de la migration | oui (extension `03-PromoteDC`) |
| `04-validate-replication.ps1` | après le redémarrage de promotion | manuel |
| `05-transfer-fsmo.ps1` | après validation de la réplication | manuel, avec confirmation |
| `06-demote-onprem-dc.ps1` | sur `SRV-AD`, après transfert FSMO | manuel, avec confirmation |

## Clients (`clients/`)

| Script | Usage |
|---|---|
| `join-domain-client.ps1` | jonction d'un poste Windows au domaine |
| `setup-tailscale-client.ps1` | accès distant d'un poste au tailnet |

## TrueNAS (`truenas/`)

| Fichier | Usage |
|---|---|
| `join-domain-truenas.md` | procédure de jonction du NAS au domaine |
| `map-smb-shares.ps1` | mappage de secours du lecteur `Z:` |

## Conventions

- Les scripts écrivent leurs journaux dans `C:\WindowsAzure\Logs\CustomScript`.
- Les scripts sensibles acceptent des mots de passe en paramètre : en
  production, préférer une lecture depuis Azure Key Vault ou une identité
  managée.
- Toujours tester avec `-WhatIf` lorsque le script le supporte.
