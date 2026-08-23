# Trivy Offline Scripts

Ce dépôt contient des scripts pour **préparer un bundle Trivy offline** et **lancer des scans Trivy** sur Linux et Windows.

## Contenu du dépôt

- `trivy_offline.ps1` : met à jour Trivy et ses bases, crée les archives de distribution et actualise un CycloneDX hors ligne.
- `Extra/trivy_scan.sh` : wrapper Linux pour exécuter un scan Trivy offline et produire plusieurs formats de sortie.
- `Extra/trivy_scan.bat` : wrapper Windows pour scanner un chemin ou tous les disques locaux.
- `Extra/export_windows_patch_history.ps1` : exporte l’historique des correctifs Windows au format CSV.
- `Extra/list_installed_products.bat` : exporte les logiciels installés depuis les clés `Uninstall` du registre Windows.
- `export_security_references.ps1` : télécharge les référentiels EndOfLife, EPSS et CISA KEV.
- `export_endoflife_api.py` / `export_endoflife_api.ps1` : produisent le JSON brut EndOfLife et un CSV simplifié de 21 colonnes.

## Prérequis

### Pour créer le bundle offline

- Windows + PowerShell 5.1+
- Accès internet (pour télécharger Trivy et les bases lors de la préparation)
- `tar.exe` pour extraire le binaire Trivy Linux pendant `update-trivy`
- Python (`python` ou `py.exe`) est optionnel pour `package` : il ajoute l’archive TAR.GZ ; sans Python, l’archive ZIP est tout de même produite.

### Pour exécuter les scans offline

- Les binaires `trivy` (Linux) et/ou `trivy.exe` (Windows)
- Un dossier `cache/` Trivy préchargé (généré par `trivy_offline.ps1 update-db`)
- Scripts et binaires dans le même répertoire (recommandé)

## Scanner en offline sous Linux

Script : `Extra/trivy_scan.sh`

### Exemple

```bash
chmod +x trivy_scan.sh
./trivy_scan.sh -p monprojet -m fs -c /opt/app --skip-dirs /opt/app/tmp
```

### Options

- `-p`, `--projet` : nom du projet (préfixe des fichiers générés).
- `-c`, `--chemin` : chemin cible.
- `-m`, `--mode` : mode Trivy (`rootfs`, `fs`, `k8s`, `image`, ...).
- Tout autre argument est transmis tel quel à Trivy.

### Fichiers générés

- `<prefix>.cyclonedx.json`
- `<prefix>.json`
- `<prefix>.config.licence.CVE.txt`
- `<projet>.<date>.trivy_scan.log`
- Archive finale `.tar.gz`

## Scanner en offline sous Windows

Script : `Extra/trivy_scan.bat`

### Exemple (scan d’un chemin précis)

```bat
trivy_scan.bat -p monprojet -m rootfs -c C:\
```

### Exemple (scan automatique des disques locaux)

```bat
trivy_scan.bat -p monprojet -m rootfs
```

### Options

- `-p`, `--projet` : nom du projet.
- `-m`, `--mode` : mode Trivy (`rootfs`, `fs`, `k8s`, `image`, ...).
- `-c`, `--chemin` : cible unique. Sans cette option, le script boucle sur les disques locaux.
- Tous les autres arguments sont transmis à Trivy.

### Sorties Windows

Par cible scannée :

- CycloneDX (`.cyclonedx.json`)
- JSON détaillé (`.json`)
- Tableau texte (`.config.licence.CVE.txt`)
- CSV patch Windows (`.patch.csv`, via `export_windows_patch_history.ps1`)
- Archive `.zip`
- Log global + log par cible

### Script complémentaire

```bat
list_installed_products.bat
list_installed_products.bat -o C:\Temp\installed_products.csv
```

Le script exporte les produits installés visibles dans les clés `Uninstall` du registre Windows (`HKLM` 64 bits, `HKLM\WOW6432Node`, `HKCU`) dans un CSV UTF-8.

## Conseils d’utilisation

- Décompresser/placer le bundle dans un dossier dédié, puis lancer les scripts depuis ce dossier.
- Vérifier la présence du dossier `cache/` avant scan.
- En environnement strictement offline, utiliser `--offline-scan` (déjà forcé dans les wrappers).
- Consulter les fichiers `.log` en priorité en cas d’échec.

## Commandes de maintenance indépendantes

Le script trivy_offline.ps1 conserve les executables dans Offline\tools et les
bases dans Offline\cache. Les commandes sont independantes :

    .\trivy_offline.ps1 update-trivy      # Executables Windows et Linux
    .\trivy_offline.ps1 update-db         # DB CVE, DB Java et checks
    .\trivy_offline.ps1 package           # Bundle local distribuable
    .\trivy_offline.ps1 all               # Les trois etapes precedentes

La procédure complète de création et le comportement sans Python sont décrits à la fin de ce document.

### Mettre a jour les CVE d'un CycloneDX hors ligne

    .\trivy_offline.ps1 update-cyclonedx -CycloneDxInput .\bom.cyclonedx.json -LocalArchive .\Export\trivy-offline-tools_0.70.0_20260820.tar.gz

La commande extrait Trivy et son cache depuis l'archive locale. Elle force le
mode offline et interdit les mises a jour DB, Java et VEX, la verification de
version et la telemetrie. Sans -CycloneDxOutput, le resultat porte le suffixe
.updated.json. Sans -LocalArchive, le bundle le plus recent d'Export est
utilise. Cette commande ne tente aucun acces Internet.

## Télécharger les référentiels complémentaires dans Export

Le script `export_security_references.ps1` telecharge en une seule commande les
referentiels EndOfLife API v1, EPSS et CISA Known Exploited Vulnerabilities.
Il doit etre execute sur une machine connectee a Internet.

### Utilisation par defaut

    .\export_security_references.ps1

Le dossier `Export` est cree automatiquement a cote du script si necessaire.
La commande produit les quatre fichiers suivants :

- `Export\endoflife_api_v1_full_export.csv` : export EndOfLife aplati, une ligne par release ;
- `Export\endoflife_api_v1_full_export.json` : reponse JSON brute EndOfLife API v1 ;
- `Export\epss_scores-current.csv` : scores EPSS quotidiens decomprimes ;
- `Export\known_exploited_vulnerabilities.csv` : catalogue CISA KEV.

L'export EndOfLife est realise en appelant `export_endoflife_api.ps1`. EPSS est
telecharge au format gzip puis decompresse. Les fichiers sont d'abord produits
sous des noms temporaires, valides, puis deplaces vers leur destination finale.
Une sortie existante n'est donc remplacee qu'apres une extraction reussie.

### Choisir les extractions

Le parametre `-Extraction` accepte `All`, `EndOfLife`, `EPSS` et `CisaKev`.
Sa valeur par defaut est `All`.

    .\export_security_references.ps1 -Extraction EndOfLife
    .\export_security_references.ps1 -Extraction EPSS
    .\export_security_references.ps1 -Extraction EPSS,CisaKev

`EndOfLife` produit toujours les deux fichiers JSON et CSV. Les alias
`-Only` et `-Sources` peuvent etre utilises a la place de `-Extraction`.

### Personnaliser les destinations

`-OutputDirectory` change le dossier utilise par les quatre noms de fichiers
par defaut :

    .\export_security_references.ps1 -OutputDirectory D:\Exports

Chaque destination peut egalement etre definie separement :

    .\export_security_references.ps1 `
      -EndOfLifeCsvPath D:\Exports\endoflife.csv `
      -EndOfLifeJsonPath D:\Exports\endoflife.json `
      -EpssCsvPath D:\Exports\epss.csv `
      -CisaKevCsvPath D:\Exports\kev.csv

Les chemins relatifs sont resolus depuis le dossier PowerShell courant.
`-EndOfLifeExporterPath` permet d'utiliser une autre copie de
`export_endoflife_api.ps1`.

### Personnaliser les URL et les options HTTP

Les URL par defaut peuvent etre surchargees avec :

- `-EndOfLifeApiBaseUrl`
- `-EpssUrl`
- `-CisaKevUrl`

Exemple :

    .\export_security_references.ps1 `
      -Extraction EPSS,CisaKev `
      -EpssUrl https://serveur.exemple/epss.csv.gz `
      -CisaKevUrl https://serveur.exemple/kev.csv

`-RequestTimeoutSec` definit le delai maximal d'une requete, avec une valeur
par defaut de 300 secondes. `-UserAgent` personnalise l'identifiant HTTP.

### Simuler avec -WhatIf

Le parametre commun PowerShell `-WhatIf` affiche les operations qui seraient
executees et leurs destinations sans telecharger de donnees, sans lancer
`export_endoflife_api.ps1`, sans creer de dossier et sans remplacer de fichier.

    .\export_security_references.ps1 -WhatIf

Il peut etre combine avec les selections et les destinations personnalisees
pour verifier une commande avant son execution :

    .\export_security_references.ps1 `
      -Extraction EPSS `
      -EpssCsvPath D:\Exports\epss.csv `
      -WhatIf

Retirer `-WhatIf` pour effectuer reellement les telechargements.

### Verification

Verifier la presence, la taille et la date des quatre fichiers :

    Get-Item .\Export\endoflife_api_v1_full_export.csv, `
      .\Export\endoflife_api_v1_full_export.json, `
      .\Export\epss_scores-current.csv, `
      .\Export\known_exploited_vulnerabilities.csv |
      Select-Object Name, Length, LastWriteTime

Les sources par defaut sont l'API v1 d'endoflife.date, le jeu quotidien
d'EPSS/FIRST et le catalogue KEV de la CISA.

## Générer un bundle Trivy offline (Windows)

Le script `trivy_offline.ps1` remplace l’ancien générateur monolithique. Il conserve les binaires dans `Offline\tools`, les bases dans `Offline\cache` et n’inclut dans le bundle que les éléments nécessaires à une utilisation hors ligne.

### Préparer puis empaqueter

```powershell
.\trivy_offline.ps1 update-trivy
.\trivy_offline.ps1 update-db
.\trivy_offline.ps1 package
```

La commande suivante enchaîne les trois étapes :

```powershell
.\trivy_offline.ps1 all
```

Les mises à jour nécessitent Internet. `package` travaille uniquement à partir du contenu déjà présent dans `Offline` et de `Extra`.

### Archives produites

Par défaut, les fichiers portent le nom `Export\trivy-offline-tools_VERSION_DATE` :

- si Python (`python` ou `py.exe`) est disponible, `package` produit une archive `.zip` et une archive `.tar.gz` ;
- si Python est absent, `package` réussit avec la seule archive `.zip` et n’essaie pas de produire le TAR.GZ.

`-OutArchive` accepte un nom terminé par `.tar.gz`, `.tgz` ou `.zip`. Le script utilise ce nom de base pour calculer les deux destinations possibles. Le ZIP repose sur le mécanisme de compression natif de Windows ; Python sert uniquement à créer le TAR.GZ portable.

### Contenu et exclusions

Le bundle contient `trivy.exe`, `trivy`, `trivy-version.json`, le dossier `cache`, le contenu distribuable de `Extra`, `offline-package.json` et `SHA256SUMS`.

Les fichiers de pilotage et de documentation suivants sont toujours exclus, même s’ils se trouvent dans `Extra` :

- `export_endoflife_api.ps1`
- `export_endoflife_api.py`
- `trivy_offline.ps1`
- `README.md`

Les répertoires locaux `Download`, `Work`, `Export` et `Offline` sont des répertoires générés et sont ignorés par Git.

### Paramètres utiles

- `-StateDir`, `-ToolsDir` et `-CacheDir` personnalisent le stockage persistant.
- `-DownloadDir` et `-WorkDir` personnalisent les répertoires temporaires.
- `-ExportDir` et `-OutArchive` personnalisent les destinations des archives.
- `-ExtraRootDir` sélectionne les fichiers additionnels distribuables.
- `-GitHubToken` évite les limites anonymes de l’API GitHub pendant les mises à jour.
- `-KeepTemp` conserve le répertoire temporaire de packaging pour diagnostic.
