# Scripts PowerShell - ordre d'exécution

## DC Azure (`azure-dc/`)

| Script | Quand l'exécuter | Automatique ? |
|---|---|---|
| `01-setup-tailscale.ps1` | au déploiement de la VM | oui (extension `01-Tailscale`) |
| `02-join-domain.ps1` | en secours si la jonction échoue | non (l'extension native est utilisée) |
| `03-promote-dc.ps1` | phase 2 de la migration | oui (extension `03-PromoteDC`) |
| `04-validate-replication.ps1` | après le redémarrage de promotion | manuel |
| `05-transfer-fsmo.ps1` | après validation de la réplication, **uniquement pour une bascule définitive (hors démonstration)** | manuel ; mode vérification par défaut, `-ExecuteTransfer` pour agir |
| `06-demote-onprem-dc.ps1` | sur `SRV-AD`, après transfert FSMO, **uniquement pour une bascule définitive (hors démonstration)** | manuel ; mode vérification par défaut, `-ExecuteDemotion` pour agir |
| `07-cleanup-azure-dc.ps1` | sur `SRV-AD`, après suppression d'une VM promue DC | manuel ; mode vérification par défaut, `-ExecuteCleanup` pour agir |

## Conventions

- Les scripts écrivent leurs journaux dans `C:\WindowsAzure\Logs\CustomScript`.
- Les scripts sensibles acceptent des mots de passe en paramètre : en
  production, préférer une lecture depuis Azure Key Vault ou une identité
  managée.
- Toujours tester avec `-WhatIf` lorsque le script le supporte.
