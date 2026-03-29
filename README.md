# Trivy Offline Scripts

Ce dépôt contient des scripts pour **préparer un bundle Trivy offline** et **lancer des scans Trivy** sur Linux et Windows.

## Contenu du dépôt

- `maj_trivy_offline.ps1` : construit une archive offline (binaires Trivy + cache préchargé + fichiers additionnels).  
- `trivy_scan_1.2.2.sh` : wrapper Linux pour exécuter un scan Trivy offline et produire plusieurs formats de sortie.  
- `trivy_scan_1.3.1.bat` : wrapper Windows pour scanner un chemin ou tous les disques locaux.  
- `export_windows_patch_history.ps1` : exporte l’historique des patchs Windows au format CSV (utilisé par le script `.bat`).

## Prérequis

### Pour créer le bundle offline

- Windows + PowerShell 5.1+
- Accès internet (pour télécharger Trivy et les bases lors de la préparation)
- Python disponible (`python` ou `py.exe`), ou préciser `-PythonExePath`

### Pour exécuter les scans offline

- Les binaires `trivy` (Linux) et/ou `trivy.exe` (Windows)
- Un dossier `cache/` Trivy préchargé (généré par `maj_trivy_offline.ps1`)
- Scripts et binaires dans le même répertoire (recommandé)

## 1) Générer un bundle Trivy offline (Windows)

Script : `maj_trivy_offline.ps1`

### Exemple minimal

```powershell
.\maj_trivy_offline.ps1
```

### Exemples utiles

```powershell
# Définir archive et log
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" `
  -OutArchive "D:\trivy\out\trivy_bundle.tar.gz" `
  -LogFile "D:\trivy\out\build.log"

# Forcer py.exe
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" -UsePyLauncher

# Inclure seed-misconfig et contrib
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" -IncludeSeedMisconfig -IncludeContrib

# Créer l'archive avec tar.exe plutôt qu'avec Python
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" -UseTarForArchive

# Créer l'archive avec 7z.exe plutôt qu'avec Python
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" -Use7ZipForArchive

# Forcer explicitement l'archive via Python
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\trivy\extra" -UsePythonForArchive
```

### Paramètres principaux

- `-ExtraRootDir` : contenu copié à la racine de l’archive (défaut : `.\\Extra` depuis le dossier courant).
- `-OutArchive` : chemin du `.tar.gz` final.
- `-LogFile` : fichier de log.
- `-DownloadDir` : dossier des releases Trivy téléchargées (défaut : `.\Download` depuis le dossier courant).
- `-Work` : dossier de travail pour extraction/cache/bundle (défaut : `.\Work` depuis le dossier courant).
- `-ExportDir` : dossier de sortie pour l’archive et les exports CSV additionnels (défaut : `.\\Export` depuis le dossier courant).
- `-PythonExePath` / `-UsePyLauncher` : sélection de l’exécutable Python.
- `-UseTarForArchive` : génère l’archive finale avec `tar.exe` (au lieu de Python).
- `-Use7ZipForArchive` : génère l’archive finale avec `7z.exe`/`7za.exe` (au lieu de Python).
- `-UsePythonForArchive` : force la génération de l’archive finale avec Python.
- `-GitHubToken` : recommandé en cas de limite API GitHub.
- `-IncludeSeedMisconfig`, `-IncludeContrib`, `-KeepWorkDir` : options avancées.

> Les switches `-UseTarForArchive`, `-Use7ZipForArchive` et `-UsePythonForArchive` sont mutuellement exclusifs.  
> Si aucun n’est fourni, le mode est choisi automatiquement dans l’ordre : **7zip**, puis **tar**, puis **python**.
> Ce même mode (forcé ou auto) est aussi utilisé pour **l’extraction des assets release Trivy** (`Windows-64bit.zip` et `Linux-64bit.tar.gz`).

## 2) Scanner en offline sous Linux

Script : `trivy_scan_1.2.2.sh`

### Exemple

```bash
chmod +x trivy_scan_1.2.2.sh
./trivy_scan_1.2.2.sh -p monprojet -m fs -c /opt/app --skip-dirs /opt/app/tmp
```

### Options

- `-p`, `--projet` : nom du projet (préfixe des fichiers générés).
- `-c`, `--path` : chemin cible.
- `-m`, `--mode` : mode Trivy (`rootfs`, `fs`, `k8s`, `image`, ...).
- Tout autre argument est transmis tel quel à Trivy.

### Fichiers générés

- `<prefix>.cyclonedx.json`
- `<prefix>.json`
- `<prefix>.config.licence.CVE.txt`
- `<projet>.<date>.trivy_scan.log`
- Archive finale `.tar.gz`

## 3) Scanner en offline sous Windows

Script : `trivy_scan_1.3.1.bat`

### Exemple (scan d’un chemin précis)

```bat
trivy_scan_1.3.1.bat -p monprojet -m rootfs -c C:\
```

### Exemple (scan automatique des disques locaux)

```bat
trivy_scan_1.3.1.bat -p monprojet -m rootfs
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

## Conseils d’utilisation

- Décompresser/placer le bundle dans un dossier dédié, puis lancer les scripts depuis ce dossier.
- Vérifier la présence du dossier `cache/` avant scan.
- En environnement strictement offline, utiliser `--offline-scan` (déjà forcé dans les wrappers).
- Consulter les fichiers `.log` en priorité en cas d’échec.
