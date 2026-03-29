<#
.SYNOPSIS
maj_trivy_offline.ps1 - Construit une archive offline Trivy (tar.gz) contenant :
- trivy.exe (Windows x64) + trivy (Linux x64)
- un cache Trivy préchargé (DB vulnérabilités, Java DB, checks bundle misconfig)
- des fichiers additionnels fournis par l'utilisateur à la racine de l'archive
- optionnellement : dossiers "seed-misconfig" et/ou "contrib"

.DESCRIPTION
Spécification (suffisamment précise pour réimplémenter le script) :

Objectif
- Télécharger la dernière release Trivy depuis GitHub Releases (assets Windows x64 et Linux x64).
  - *Windows-64bit.zip
  - *Linux-64bit.tar.gz
- Utiliser le trivy.exe téléchargé pour précharger un cache offline :
  - DB vulnérabilités via trivy image --cache-dir <cache> --download-db-only
  - Java DB via trivy image --cache-dir <cache> --download-java-db-only
  - Checks bundle misconfig via trivy config (déclenche le téléchargement du checks bundle misconfig dans le cache) Pour éviter d'afficher des misconfigurations : sortie JSON vers un fichier temporaire, supprimé ensuite.
- Assembler un répertoire "bundle-root" à archiver en tar.gz :
  - ./trivy.exe
  - ./trivy (Linux, doit être exécutable après extraction : mode 0755 enregistré dans l’archive)
  - ./cache/...
  - + contenu de ExtraRootDir copié à la racine (sans collisions)
  - + optionnellement : ./seed-misconfig/ (switch)
  - + optionnellement : ./contrib/ si présent dans l’asset (switch)
- Créer l’archive finale via Python uniquement (pas de WSL, pas de tar.exe) en fixant explicitement :
  - répertoires en 0755
  - fichier "./trivy" en 0755
  - autres fichiers en 0644

Entrées
- ExtraRootDir (obligatoire) : les fichiers/dossiers qu’il contient sont copiés à la RACINE de l’archive.
- OutArchive (optionnel) : chemin du tar.gz final. Par défaut : <dossier_du_script>\trivy-offline-bundle_<version_trivy>_<yyyymmdd_db>.tar.gz
- LogFile (optionnel) : log. Par défaut : <dossier_du_script>\maj_trivy_offline_yyyyMMdd_HHmmss.log
- DownloadDir (optionnel) : dossier de téléchargement des releases Trivy.
  Par défaut : <dossier_courant>\Download
- Work (optionnel) : dossier de travail utilisé pour extraction/cache/bundle.
  Par défaut : <dossier_courant>\Work
- ExportDir (optionnel) : dossier de sortie pour l'archive et les exports CSV additionnels.
  Par défaut : <dossier_du_script>\Export
- PythonExePath (optionnel) : chemin d’un exécutable Python à utiliser (ex: C:\Python311\python.exe). Si renseigné, il est prioritaire.
- UsePyLauncher (switch) : force l’utilisation de py.exe (launcher Python). Le script utilise alors typiquement "py.exe -3".
- GitHubToken (optionnel) : token GitHub pour API/download (403/429).
- ChecksBundleRepository (optionnel) : repository OCI du checks bundle (défaut officiel).
- IncludeSeedMisconfig (switch) : inclure seed-misconfig/ dans l’archive.
- IncludeContrib (switch) : inclure contrib/ dans l’archive si détecté.
- UseTarForArchive (switch) : crée l’archive finale avec tar.exe au lieu de Python.
- Use7ZipForArchive (switch) : crée l’archive finale avec 7z.exe au lieu de Python.
- UsePythonForArchive (switch) : force la création de l’archive finale via Python.
- NoCleanupMisconfigSeed (switch) : conserve le fichier JSON de sortie misconfig dans seed-misconfig/misconfig_seed.json
  (implique l’inclusion de seed-misconfig/ dans l’archive).
- KeepWorkDir (switch) : conserve le workdir temporaire.
- Si aucun switch de mode d'archive n'est fourni : sélection auto dans l'ordre 7zip, tar, puis python.

Sorties
- Archive tar.gz : OutArchive
- Journal : LogFile
- Console : messages courts (toutes les sorties détaillées vont dans le log)

Pré-requis et invariants
- PowerShell 5.1 : le bloc param() DOIT être la première instruction (hors commentaires) sinon erreur de parsing.
- Un outil "tar" doit être présent (Windows 10/11 en fournissent souvent un via bsdtar).
- Pour garantir que "./trivy" (Linux) reste exécutable après extraction : l'archive tar.gz doit stocker un mode 0755. Le script utilise Python (recommandé) pour créer le tar.gz en fixant explicitement le mode (0755 pour ./trivy).
- Journalisation robuste : pas de redirection vers le log pendant que le log est ouvert.

Dossiers utilisés
- <script>\                : assets GitHub téléchargés/réutilisés (pas dans %TEMP%)
- <work>\extract_windows\  : zip Windows extrait
- <work>\extract_linux\    : tar.gz Linux extrait (mode auto : 7zip > tar > python, ou mode force)
- <work>\cache\            : cache Trivy préchargé
- <work>\seed-misconfig\   : fichiers “appâts” + éventuel misconfig_seed.json
- <work>\bundle-root\      : racine du contenu à archiver

Références documentaires
- Trivy installation depuis release assets (tar -xzf, chmod +x) :
  https://trivy.dev/docs/latest/getting-started/installation/
- Trivy self-hosting / --download-db-only / --cache-dir :
  https://trivy.dev/docs/latest/guide/advanced/self-hosting/
- Trivy DB configuration flags (db-repository / java-db-repository / checks-bundle-repository) :
  https://trivy.dev/docs/latest/configuration/db/
- PowerShell comment-based help :
  https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_comment_based_help

.EXAMPLE
# Minimal : archive + log à côté du script
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra"

.EXAMPLE
# Spécifier l’archive et le log
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" `
  -OutArchive "D:\bureau\trivy\out\trivy_bundle.tar.gz" `
  -LogFile "D:\bureau\trivy\out\build.log"

.EXAMPLE
# Ajouter le token GitHub (optionnel)
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -GitHubToken "<TOKEN>"

.EXAMPLE
# Forcer l’utilisation de py.exe (launcher)
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -UsePyLauncher

.EXAMPLE
# Spécifier explicitement le Python à utiliser
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -PythonExePath "C:\Python311\python.exe"

.EXAMPLE
# Inclure seed-misconfig/ et contrib/
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -IncludeSeedMisconfig -IncludeContrib

.EXAMPLE
# Créer l'archive finale avec tar.exe (au lieu de Python)
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -UseTarForArchive

.EXAMPLE
# Créer l'archive finale avec 7z.exe (au lieu de Python)
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -Use7ZipForArchive

.EXAMPLE
# Créer l'archive finale explicitement avec Python
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -UsePythonForArchive

.EXAMPLE
# Conserver le JSON misconfig de seed (implique l’inclusion du seed)
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -NoCleanupMisconfigSeed

.EXAMPLE
# Conserver le workdir temporaire pour audit
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -KeepWorkDir

.EXAMPLE
# Définir un dossier alternatif pour l’archive et les CSV additionnels
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -ExportDir "D:\bureau\trivy\out"

.EXAMPLE
# Exporter l'API EndOfLife v1 en CSV via PowerShell
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -ExportEndOfLifeApiCsv

.EXAMPLE
# Exporter l'API EndOfLife v1 en CSV via Python et chemin personnalisé
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" `
  -ExportEndOfLifeApiCsv -EndOfLifeExportImplementation Python `
  -EndOfLifeCsvPath "D:\bureau\trivy\out\endoflife_api_v1_full_export.csv"

.EXAMPLE
# Désactiver l'export EndOfLife CSV
.\maj_trivy_offline.ps1 -ExtraRootDir "D:\bureau\trivy\extra" -DisableEndOfLifeApiCsv
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$ExtraRootDir,

  [string]$OutArchive = "",

  [string]$LogFile = "",

  [string]$PythonExePath = "",

  [switch]$UsePyLauncher,

  [string]$DownloadDir = "",

  [string]$Work = "",

  [string]$ExportDir = "",

  [string]$GitHubToken = "",

  [string]$ChecksBundleRepository = "ghcr.io/aquasecurity/trivy-checks",

  [switch]$IncludeSeedMisconfig,

  [switch]$IncludeContrib,

  [switch]$UseTarForArchive,

  [switch]$Use7ZipForArchive,

  [switch]$UsePythonForArchive,

  [switch]$NoCleanupMisconfigSeed,

  [switch]$KeepWorkDir,

  [switch]$ExportEndOfLifeApiCsv,

  [switch]$DisableEndOfLifeApiCsv,

  [string]$EndOfLifeCsvPath = "",

  [ValidateSet("PowerShell", "Python")]
  [string]$EndOfLifeExportImplementation = "PowerShell",

  [string]$EndOfLifeApiBaseUrl = "https://endoflife.date/api/v1"
)

$VERSION = "1.1.0"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

# Force l'UTF-8 pour l'affichage console afin d'éviter les accents illisibles (ex: dÃ©faut).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

# Préfixe d’arguments pour Python (ex: @('-3') si utilisation de py.exe)
$script:PythonPrefixArgs = @()

# --- Dossier du script (robuste) ---
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$CurrentDir = (Get-Location).Path
if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
  $DownloadDir = Join-Path $CurrentDir "Download"
} else {
  $DownloadDir = [System.IO.Path]::GetFullPath($DownloadDir)
}

if ([string]::IsNullOrWhiteSpace($Work)) {
  $Work = Join-Path $CurrentDir "Work"
} else {
  $Work = [System.IO.Path]::GetFullPath($Work)
}

if ([string]::IsNullOrWhiteSpace($ExportDir)) {
  $ExportDir = Join-Path $ScriptDir "Export"
} else {
  $ExportDir = [System.IO.Path]::GetFullPath($ExportDir)
}

# --- Défauts OutArchive / LogFile ---
$OutArchiveProvided = -not [string]::IsNullOrWhiteSpace($OutArchive)
if ($OutArchiveProvided) {
  $OutArchive = [System.IO.Path]::GetFullPath($OutArchive)
}

if ([string]::IsNullOrWhiteSpace($LogFile)) {
  $LogFile = Join-Path $ScriptDir ("maj_trivy_offline_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
} else {
  $LogFile = [System.IO.Path]::GetFullPath($LogFile)
}

function New-Dir([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

# --- Logger (StreamWriter unique => pas de conflits Out-File/Add-Content) ---
$null = New-Dir (Split-Path -Parent $LogFile)
$global:LogWriter = New-Object System.IO.StreamWriter($LogFile, $true, [System.Text.Encoding]::UTF8)
$global:LogWriter.AutoFlush = $true

function Log([string]$Message) {
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
  Write-Host $line
  $global:LogWriter.WriteLine($line)
}

function Close-Log() {
  if ($global:LogWriter) {
    $global:LogWriter.Flush()
    $global:LogWriter.Dispose()
    $global:LogWriter = $null
  }
}

function Get-HttpHeaders() {
  $h = @{
    "User-Agent" = "maj_trivy_offline.ps1"
    "Accept"     = "application/vnd.github+json"
  }
  if ($GitHubToken -and $GitHubToken.Trim().Length -gt 0) {
    $h["Authorization"] = "Bearer $GitHubToken"
  }
  return $h
}

function Download-File([string]$Url, [string]$OutFile) {
  Log "Download: $Url -> $OutFile"
  try {
    Invoke-WebRequest -Uri $Url -Headers (Get-HttpHeaders) -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
    $len = (Get-Item -LiteralPath $OutFile).Length
    Log ("Downloaded OK: {0} bytes" -f $len)
  } catch {
    Log ("ERREUR download: " + $_.Exception.Message)
    throw
  }
}

function Get-TrivyAssetVersionFromName([string]$AssetName) {
  if ([string]::IsNullOrWhiteSpace($AssetName)) { return $null }
  if ($AssetName -match '^trivy_([^_]+)_(?:windows-64bit\.zip|Linux-64bit\.tar\.gz)$') {
    return $Matches[1]
  }
  return $null
}

function Ensure-TrivyAsset([object]$Asset, [string]$DestinationDir) {
  if (-not $Asset) { throw "Asset invalide (null)." }
  $assetName = [string]$Asset.name
  if ([string]::IsNullOrWhiteSpace($assetName)) { throw "Asset sans nom." }
  if (-not (Test-Path -LiteralPath $DestinationDir)) {
    New-Dir $DestinationDir
  }

  $destFile = Join-Path $DestinationDir $assetName
  $releaseVersion = Get-TrivyAssetVersionFromName $assetName

  $pattern = if ($assetName -match 'windows-64bit\.zip$') {
    'trivy_*_windows-64bit.zip'
  } elseif ($assetName -match 'Linux-64bit\.tar\.gz$') {
    'trivy_*_Linux-64bit.tar.gz'
  } else {
    $null
  }

  if ($pattern) {
    $localCandidates = @(Get-ChildItem -LiteralPath $DestinationDir -File -Filter $pattern -ErrorAction SilentlyContinue)
    if ($localCandidates.Count -gt 0) {
      $localVersions = @(
        $localCandidates |
          ForEach-Object { Get-TrivyAssetVersionFromName $_.Name } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Sort-Object -Unique
      )
      if ($localVersions.Count -gt 0) {
        Log ("Assets locaux detectes ({0}): versions=[{1}] ; release={2}" -f $pattern, ($localVersions -join ", "), $releaseVersion)
      } else {
        Log ("Assets locaux detectes ({0}) mais version non extraite depuis les noms de fichier." -f $pattern)
      }
    }
  }

  if (Test-Path -LiteralPath $destFile) {
    $existing = Get-Item -LiteralPath $destFile
    if ($existing.Length -eq [int64]$Asset.size) {
      Log ("Asset deja present et valide (meme version/meme taille) -> skip download: {0}" -f $destFile)
      return $destFile
    }
    Log ("Asset present mais taille differente (local={0} release={1}) -> re-download: {2}" -f $existing.Length, $Asset.size, $destFile)
  } else {
    Log ("Asset de la release absent localement (version release={0}) -> download requis: {1}" -f $releaseVersion, $destFile)
  }

  Download-File $Asset.browser_download_url $destFile
  return $destFile
}

function Resolve-Python([string]$PythonExePath, [switch]$UsePyLauncher) {
  # Retourne : @{ Exe = <chemin_exe>; PrefixArgs = @(<args>) }

  if ($PythonExePath -and $PythonExePath.Trim().Length -gt 0) {
    $full = [System.IO.Path]::GetFullPath($PythonExePath)
    if (-not (Test-Path -LiteralPath $full)) {
      throw "PythonExePath fourni mais introuvable: $full"
    }
    return @{ Exe = $full; PrefixArgs = @() }
  }

  if ($UsePyLauncher) {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $py) { throw "UsePyLauncher demandé mais py.exe est introuvable." }
    return @{ Exe = $py.Source; PrefixArgs = @('-3') }
  }

  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) {
    $src = $python.Source
    $isWindowsApps = $src -match "\\WindowsApps\\python\.exe$"
    if ($isWindowsApps) {
      $py = Get-Command py.exe -ErrorAction SilentlyContinue
      if ($py) {
        return @{ Exe = $py.Source; PrefixArgs = @('-3') }
      }
    }
    return @{ Exe = $src; PrefixArgs = @() }
  }

  $py2 = Get-Command py.exe -ErrorAction SilentlyContinue
  if ($py2) {
    return @{ Exe = $py2.Source; PrefixArgs = @('-3') }
  }

  throw "Python introuvable. Installe Python ou indique -PythonExePath, ou utilise -UsePyLauncher (py.exe)."
}

function Ensure-TarWithPermission() {
  $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
  if ($tar) { Log "tar.exe present: $($tar.Source)"; return }

  Log "tar.exe absent (non bloquant : le script n’en depend pas)."
  $answer = Read-Host "Voulez-vous tenter d’installer tar via winget (Git.Git) ? (O/N)"
  if ($answer -match '^(o|oui|y|yes)$') {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { Log "INCERTAIN: winget.exe absent => installation auto impossible."; return }
    Start-Process -FilePath $winget.Source -ArgumentList @("install","-e","--id","Git.Git") -Wait -NoNewWindow | Out-Null
    Log "Installation winget demandee. Un nouveau shell peut etre requis pour le PATH."
  } else {
    Log "Installation tar.exe refusee."
  }
}

function Get-TarExePath() {
  $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
  if ($tar) { return $tar.Source }
  return $null
}

function Get-7ZipExePath() {
  $names = @("7z.exe","7za.exe")
  foreach ($name in $names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Escape-WinArg([string]$s) {
  # Quoting CreateProcess-compatible (espaces, guillemets, antislashs)
  if ($null -eq $s -or $s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0

  foreach ($ch in $s.ToCharArray()) {
    if ($ch -eq '\') { $bs++; continue }
    if ($ch -eq '"') {
      [void]$sb.Append(('\' * ($bs * 2 + 1)))
      [void]$sb.Append('"')
      $bs = 0
      continue
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }

  if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
  [void]$sb.Append('"')
  $sb.ToString()
}

function Join-WinCmdline([string[]]$ArgList) {
  if (-not $ArgList -or $ArgList.Count -eq 0) { return "" }
  ($ArgList | ForEach-Object { Escape-WinArg $_ }) -join ' '
}

function Run-ExternalLogged([string]$Label, [string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$Work) {
  $stdout = Join-Path $Work ("stdout_{0}.log" -f $Label)
  $stderr = Join-Path $Work ("stderr_{0}.log" -f $Label)
  if (Test-Path $stdout) { Remove-Item $stdout -Force -ErrorAction SilentlyContinue }
  if (Test-Path $stderr) { Remove-Item $stderr -Force -ErrorAction SilentlyContinue }

  $argLine = Join-WinCmdline $ArgList
  if ([string]::IsNullOrWhiteSpace($argLine)) { Log "CMD [$Label]: $Exe" }
  else { Log "CMD [$Label]: $Exe $argLine" }

  $startParams = @{
    FilePath               = $Exe
    WorkingDirectory       = $WorkDir
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = $stdout
    RedirectStandardError  = $stderr
  }
  if (-not [string]::IsNullOrWhiteSpace($argLine)) {
    # PS 5.1 : passer UNE chaîne d’arguments, déjà quotée
    $startParams.ArgumentList = $argLine
  }

  $p = Start-Process @startParams

  $stdoutStarted = $false
  $stderrStarted = $false
  $lastStdoutLine = 0
  $lastStderrLine = 0
  $lastHeartbeat = Get-Date
  $heartbeatIntervalSec = 30

  while (-not $p.HasExited) {
    if (Test-Path -LiteralPath $stdout) {
      $stdoutLines = @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue)
      if ($stdoutLines.Count -gt $lastStdoutLine) {
        if (-not $stdoutStarted) {
          $global:LogWriter.WriteLine("----- STDOUT [$Label] -----")
          $stdoutStarted = $true
        }
        for ($i = $lastStdoutLine; $i -lt $stdoutLines.Count; $i++) {
          $global:LogWriter.WriteLine($stdoutLines[$i])
        }
        $lastStdoutLine = $stdoutLines.Count
      }
    }

    if (Test-Path -LiteralPath $stderr) {
      $stderrLines = @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
      if ($stderrLines.Count -gt $lastStderrLine) {
        if (-not $stderrStarted) {
          $global:LogWriter.WriteLine("----- STDERR [$Label] -----")
          $stderrStarted = $true
        }
        for ($i = $lastStderrLine; $i -lt $stderrLines.Count; $i++) {
          $global:LogWriter.WriteLine($stderrLines[$i])
        }
        $lastStderrLine = $stderrLines.Count
      }
    }

    $now = Get-Date
    if ((New-TimeSpan -Start $lastHeartbeat -End $now).TotalSeconds -ge $heartbeatIntervalSec) {
      Log ("[{0}] commande en cours..." -f $Label)
      $lastHeartbeat = $now
    }

    Start-Sleep -Milliseconds 500
  }

  if (Test-Path -LiteralPath $stdout) {
    $stdoutLines = @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue)
    if ($stdoutLines.Count -gt $lastStdoutLine) {
      if (-not $stdoutStarted) {
        $global:LogWriter.WriteLine("----- STDOUT [$Label] -----")
        $stdoutStarted = $true
      }
      for ($i = $lastStdoutLine; $i -lt $stdoutLines.Count; $i++) {
        $global:LogWriter.WriteLine($stdoutLines[$i])
      }
    }
  }
  if (Test-Path -LiteralPath $stderr) {
    $stderrLines = @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
    if ($stderrLines.Count -gt $lastStderrLine) {
      if (-not $stderrStarted) {
        $global:LogWriter.WriteLine("----- STDERR [$Label] -----")
        $stderrStarted = $true
      }
      for ($i = $lastStderrLine; $i -lt $stderrLines.Count; $i++) {
        $global:LogWriter.WriteLine($stderrLines[$i])
      }
    }
  }
  $global:LogWriter.WriteLine("----- END [$Label] (exit={0}) -----" -f $p.ExitCode)

  if ($p.ExitCode -ne 0) {
    throw ("Echec commande [{0}] (code={1}). Voir log: {2}" -f $Label, $p.ExitCode, $LogFile)
  }
}

function Invoke-WithRetry([string]$Label, [scriptblock]$Action, [int]$MaxAttempts = 3, [int]$DelaySeconds = 5) {
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      if ($attempt -gt 1) {
        Log ("REPRISE [{0}] - tentative {1}/{2}" -f $Label, $attempt, $MaxAttempts)
      }
      & $Action
      return
    } catch {
      if ($attempt -ge $MaxAttempts) {
        Log ("ECHEC DEFINITIF [{0}] apres {1} tentative(s)." -f $Label, $MaxAttempts)
        throw
      }
      Log ("Echec [{0}] tentative {1}/{2}: {3}" -f $Label, $attempt, $MaxAttempts, $_.Exception.Message)
      Log ("Nouvelle tentative dans {0}s..." -f $DelaySeconds)
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

function Py-RunScript([string]$PythonExe, [string]$ScriptContent, [string]$Label, [string]$Work, [string]$WorkDir) {
  $tmpPy = Join-Path $Work ("py_{0}_{1}.py" -f $Label, ([Guid]::NewGuid().ToString("N")))
  Set-Content -LiteralPath $tmpPy -Value $ScriptContent -Encoding UTF8
  try {
    $argList = @()
    if ($script:PythonPrefixArgs -and $script:PythonPrefixArgs.Count -gt 0) { $argList += $script:PythonPrefixArgs }
    $argList += @($tmpPy)
    Run-ExternalLogged -Label ("python_"+$Label) -Exe $PythonExe -ArgList $argList -WorkDir $WorkDir -Work $Work
  } finally {
    Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue
  }
}

function Py-ExtractTarGz([string]$PythonExe, [string]$TarGzPath, [string]$DestDir, [string]$Work) {
  $script = @"
import os, tarfile
tgz = r'''$TarGzPath'''
dst = r'''$DestDir'''
os.makedirs(dst, exist_ok=True)
with tarfile.open(tgz, "r:gz") as tf:
    tf.extractall(dst)
print("OK")
"@
  Py-RunScript -PythonExe $PythonExe -ScriptContent $script -Label "extract_tgz" -Work $Work -WorkDir $Work
}

function Py-ExtractZip([string]$PythonExe, [string]$ZipPath, [string]$DestDir, [string]$Work) {
  $script = @"
import os, zipfile
z = r'''$ZipPath'''
dst = r'''$DestDir'''
os.makedirs(dst, exist_ok=True)
with zipfile.ZipFile(z, "r") as zf:
    zf.extractall(dst)
print("OK")
"@
  Py-RunScript -PythonExe $PythonExe -ScriptContent $script -Label "extract_zip" -Work $Work -WorkDir $Work
}

function Extract-ZipWithTar([string]$TarExe, [string]$ZipPath, [string]$DestDir, [string]$Work) {
  if (-not $TarExe) { throw "tar.exe introuvable." }
  Run-ExternalLogged -Label "extract_zip_tar" -Exe $TarExe -ArgList @(
    "-xf", $ZipPath,
    "-C", $DestDir
  ) -WorkDir (Split-Path -Parent $ZipPath) -Work $Work
}

function Extract-TarGzWithTar([string]$TarExe, [string]$TarGzPath, [string]$DestDir, [string]$Work) {
  if (-not $TarExe) { throw "tar.exe introuvable." }
  Run-ExternalLogged -Label "extract_tgz_tar" -Exe $TarExe -ArgList @(
    "-xzf", $TarGzPath,
    "-C", $DestDir
  ) -WorkDir (Split-Path -Parent $TarGzPath) -Work $Work
}

function Extract-ZipWith7Zip([string]$SevenZipExe, [string]$ZipPath, [string]$DestDir, [string]$Work) {
  if (-not $SevenZipExe) { throw "7z.exe/7za.exe introuvable." }
  Run-ExternalLogged -Label "extract_zip_7zip" -Exe $SevenZipExe -ArgList @(
    "x",
    "-y",
    "-o$DestDir",
    $ZipPath
  ) -WorkDir (Split-Path -Parent $ZipPath) -Work $Work
}

function Extract-TarGzWith7Zip([string]$SevenZipExe, [string]$TarGzPath, [string]$DestDir, [string]$Work) {
  if (-not $SevenZipExe) { throw "7z.exe/7za.exe introuvable." }
  $tmpTar = Join-Path $Work ("extract_{0}.tar" -f ([Guid]::NewGuid().ToString("N")))
  try {
    Run-ExternalLogged -Label "extract_tgz_to_tar_7zip" -Exe $SevenZipExe -ArgList @(
      "e",
      "-y",
      "-o$Work",
      $TarGzPath
    ) -WorkDir (Split-Path -Parent $TarGzPath) -Work $Work

    $tmpTarByName = Join-Path $Work (([System.IO.Path]::GetFileNameWithoutExtension($TarGzPath)))
    if (-not (Test-Path -LiteralPath $tmpTarByName)) {
      throw "Extraction 7zip du .tar intermediaire introuvable: $tmpTarByName"
    }
    Move-Item -LiteralPath $tmpTarByName -Destination $tmpTar -Force

    Run-ExternalLogged -Label "extract_tar_7zip" -Exe $SevenZipExe -ArgList @(
      "x",
      "-y",
      "-o$DestDir",
      $tmpTar
    ) -WorkDir $Work -Work $Work
  } finally {
    Remove-Item -LiteralPath $tmpTar -Force -ErrorAction SilentlyContinue
  }
}

function Expand-TrivyReleaseAssets(
  [string]$Mode,
  [string]$SevenZipExe,
  [string]$TarExe,
  [string]$PythonExe,
  [string]$WinZip,
  [string]$LinTgz,
  [string]$ExtractW,
  [string]$ExtractL,
  [string]$Work
) {
  switch ($Mode) {
    "7zip" {
      if (-not $SevenZipExe) { throw "Mode extraction 7zip selectionne mais 7z.exe/7za.exe est introuvable." }
      Log "Extract release assets via 7zip (zip + tar.gz)."
      Extract-ZipWith7Zip -SevenZipExe $SevenZipExe -ZipPath $WinZip -DestDir $ExtractW -Work $Work
      Extract-TarGzWith7Zip -SevenZipExe $SevenZipExe -TarGzPath $LinTgz -DestDir $ExtractL -Work $Work
    }
    "tar" {
      if (-not $TarExe) { throw "Mode extraction tar selectionne mais tar.exe est introuvable." }
      Log "Extract release assets via tar.exe (zip + tar.gz)."
      Extract-ZipWithTar -TarExe $TarExe -ZipPath $WinZip -DestDir $ExtractW -Work $Work
      Extract-TarGzWithTar -TarExe $TarExe -TarGzPath $LinTgz -DestDir $ExtractL -Work $Work
    }
    default {
      Log "Extract release assets via Python (zip + tar.gz)."
      Py-ExtractZip -PythonExe $PythonExe -ZipPath $WinZip -DestDir $ExtractW -Work $Work
      Py-ExtractTarGz -PythonExe $PythonExe -TarGzPath $LinTgz -DestDir $ExtractL -Work $Work
    }
  }
}

function Py-CreateTarGzWithModes([string]$PythonExe, [string]$SourceDir, [string]$OutFile, [string]$Work) {
  $script = @"
import os, tarfile
src = r'''$SourceDir'''
out = r'''$OutFile'''

def filt(ti: tarfile.TarInfo):
    name = ti.name.lstrip("./")
    base = os.path.basename(name)
    if ti.isdir():
        ti.mode = 0o755
    else:
        ti.mode = 0o755 if base == "trivy" else 0o644
    ti.uid = 0
    ti.gid = 0
    ti.uname = "root"
    ti.gname = "root"
    return ti

with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as tf:
    for root, dirs, files in os.walk(src):
        for d in dirs:
            p = os.path.join(root, d)
            arc = os.path.relpath(p, src).replace("\\\\","/")
            tf.add(p, arcname=arc, recursive=False, filter=filt)
        for f in files:
            p = os.path.join(root, f)
            arc = os.path.relpath(p, src).replace("\\\\","/")
            tf.add(p, arcname=arc, recursive=False, filter=filt)
print("OK")
"@
  Py-RunScript -PythonExe $PythonExe -ScriptContent $script -Label "create_tgz" -Work $Work -WorkDir $Work
}

function Create-TarGzWithTar([string]$TarExe, [string]$SourceDir, [string]$OutFile, [string]$Work) {
  if (-not $TarExe) { throw "tar.exe introuvable." }
  $srcParent = Split-Path -Parent $SourceDir
  $srcName = Split-Path -Leaf $SourceDir

  # tar -a choisit le format d'archive en fonction de l'extension (.tar.gz ici)
  Run-ExternalLogged -Label "create_tgz_tar" -Exe $TarExe -ArgList @(
    "-a",
    "-c",
    "-f", $OutFile,
    "-C", $srcParent,
    $srcName
  ) -WorkDir $srcParent -Work $Work
}

function Create-TarGzWith7Zip([string]$SevenZipExe, [string]$SourceDir, [string]$OutFile, [string]$Work) {
  if (-not $SevenZipExe) { throw "7z.exe/7za.exe introuvable." }
  $srcParent = Split-Path -Parent $SourceDir
  $srcName = Split-Path -Leaf $SourceDir
  $tmpTar = Join-Path $Work ("bundle_{0}.tar" -f ([Guid]::NewGuid().ToString("N")))
  try {
    Run-ExternalLogged -Label "create_tar_7zip" -Exe $SevenZipExe -ArgList @(
      "a",
      "-ttar",
      $tmpTar,
      $srcName
    ) -WorkDir $srcParent -Work $Work

    Run-ExternalLogged -Label "create_tgz_7zip" -Exe $SevenZipExe -ArgList @(
      "a",
      "-tgzip",
      $OutFile,
      $tmpTar
    ) -WorkDir $Work -Work $Work
  } finally {
    Remove-Item -LiteralPath $tmpTar -Force -ErrorAction SilentlyContinue
  }
}

function Add-ExtraRootContent([string]$FromDir, [string]$ToDir) {
  $items = Get-ChildItem -Force -LiteralPath $FromDir
  foreach ($it in $items) {
    $dest = Join-Path $ToDir $it.Name
    if (Test-Path -LiteralPath $dest) {
      throw "Collision: '$dest' existe deja (nom: $($it.Name))."
    }
    Copy-Item -LiteralPath $it.FullName -Destination $dest -Recurse -Force
  }
}

function Show-Plan([hashtable]$P) {
  Log "----- Plan / chemins -----"
  foreach ($k in $P.Keys | Sort-Object) { Log ("{0,-24}: {1}" -f $k, $P[$k]) }
  Log "-------------------------"
}

try {
  Log ("==== start {0} ====" -f (Get-Date))

  $ExtraRootDir = [System.IO.Path]::GetFullPath($ExtraRootDir)
  if (-not (Test-Path -LiteralPath $ExtraRootDir)) { throw "ExtraRootDir introuvable: $ExtraRootDir" }
  if (-not (Get-Item -LiteralPath $ExtraRootDir).PSIsContainer) { throw "ExtraRootDir n'est pas un dossier: $ExtraRootDir" }

  $pyInfo = Resolve-Python -PythonExePath $PythonExePath -UsePyLauncher:$UsePyLauncher
  $PythonExe = $pyInfo.Exe
  $script:PythonPrefixArgs = $pyInfo.PrefixArgs
  Log "Python: $PythonExe"
  if ($script:PythonPrefixArgs -and $script:PythonPrefixArgs.Count -gt 0) {
    Log ("Python prefix args: " + ($script:PythonPrefixArgs -join ' '))
  }

  # validation rapide Python (utile si python.exe est un alias Store)
  $pyVerArgs = @()
  if ($script:PythonPrefixArgs -and $script:PythonPrefixArgs.Count -gt 0) { $pyVerArgs += $script:PythonPrefixArgs }
  $pyVerArgs += @("-c","import sys;print(sys.version);print(sys.executable)")
  Run-ExternalLogged -Label "python_version" -Exe $PythonExe -ArgList $pyVerArgs -WorkDir $ScriptDir -Work $env:TEMP

  Ensure-TarWithPermission
  $tarExe = Get-TarExePath
  $sevenZipExe = Get-7ZipExePath

  $archiveModeSwitchCount = 0
  if ($Use7ZipForArchive) { $archiveModeSwitchCount++ }
  if ($UseTarForArchive) { $archiveModeSwitchCount++ }
  if ($UsePythonForArchive) { $archiveModeSwitchCount++ }
  if ($archiveModeSwitchCount -gt 1) {
    throw "Use7ZipForArchive, UseTarForArchive et UsePythonForArchive sont mutuellement exclusifs."
  }

  $archiveMode = "python"
  if ($Use7ZipForArchive) {
    $archiveMode = "7zip"
  } elseif ($UseTarForArchive) {
    $archiveMode = "tar"
  } elseif ($UsePythonForArchive) {
    $archiveMode = "python"
  } else {
    if ($sevenZipExe) {
      $archiveMode = "7zip"
    } elseif ($tarExe) {
      $archiveMode = "tar"
    } else {
      $archiveMode = "python"
    }
    Log "Archive mode auto-selected: $archiveMode (ordre: 7zip > tar > python)"
  }

  $IncludeSeedEffective = $IncludeSeedMisconfig -or $NoCleanupMisconfigSeed
  if ($NoCleanupMisconfigSeed -and -not $IncludeSeedMisconfig) {
    Log "NoCleanupMisconfigSeed => inclusion implicite de seed-misconfig/ dans l'archive."
  }

  # Workdir
  New-Dir $Work

  $downloads = $DownloadDir
  New-Dir $downloads
  $extractW  = Join-Path $Work "extract_windows"
  $extractL  = Join-Path $Work "extract_linux"
  $cacheDir  = Join-Path $Work "cache"
  $seedDir   = Join-Path $Work "seed-misconfig"
  $bundleDir = Join-Path $Work "bundle-root"

  New-Dir $extractW
  New-Dir $extractL
  New-Dir $cacheDir
  New-Dir $seedDir
  New-Dir $bundleDir

  Show-Plan @{
    "ScriptDir"              = $ScriptDir
    "ExtraRootDir"           = $ExtraRootDir
    "OutArchive"             = $OutArchive
    "LogFile"                = $LogFile
    "GitHubTokenProvided"    = ([bool]($GitHubToken -and $GitHubToken.Trim().Length -gt 0))
    "ChecksBundleRepository" = $ChecksBundleRepository
    "IncludeSeedMisconfig"   = $IncludeSeedMisconfig
    "IncludeContrib"         = $IncludeContrib
    "NoCleanupMisconfigSeed" = $NoCleanupMisconfigSeed
    "KeepWorkDir"            = $KeepWorkDir
    "WorkDir"                = $Work
    "downloads"              = $downloads
    "extract_windows"        = $extractW
    "extract_linux"          = $extractL
    "cache"                  = $cacheDir
    "seed-misconfig"         = $seedDir
    "bundle-root"            = $bundleDir
  }

  # GitHub latest release
  $api = "https://api.github.com/repos/aquasecurity/trivy/releases/latest"
  Log "Fetch release: $api"
  $release = Invoke-RestMethod -Uri $api -Headers (Get-HttpHeaders) -ErrorAction Stop
  $tag = $release.tag_name
  if (-not $tag) { $tag = "latest" }
  Log "Release: $tag"

  $archiveVersion = ($tag -replace '^v','')
  if ([string]::IsNullOrWhiteSpace($archiveVersion)) { $archiveVersion = "latest" }
  $archiveVersion = $archiveVersion -replace '[^0-9A-Za-z._-]', '_'

  $assets = $release.assets
  if (-not $assets) { throw "Aucun asset trouve dans la release." }

  $winAsset = $assets | Where-Object { $_.name -match 'windows-64bit\.zip$' } | Select-Object -First 1
  $linAsset = $assets | Where-Object { $_.name -match 'Linux-64bit\.tar\.gz$' } | Select-Object -First 1
  if (-not $winAsset) { throw "Asset Windows-64bit.zip introuvable." }
  if (-not $linAsset) { throw "Asset Linux-64bit.tar.gz introuvable." }

  Log ("Asset Windows: {0} size={1}" -f $winAsset.name, $winAsset.size)
  Log ("Asset Linux  : {0} size={1}" -f $linAsset.name, $linAsset.size)

  $winZip = Ensure-TrivyAsset -Asset $winAsset -DestinationDir $downloads
  $linTgz = Ensure-TrivyAsset -Asset $linAsset -DestinationDir $downloads

  Log ("Extraction mode: {0} (regles identiques a l'archive finale; ordre auto: 7zip > tar > python)" -f $archiveMode)
  Expand-TrivyReleaseAssets -Mode $archiveMode -SevenZipExe $sevenZipExe -TarExe $tarExe -PythonExe $PythonExe -WinZip $winZip -LinTgz $linTgz -ExtractW $extractW -ExtractL $extractL -Work $Work

  $trivyExe = Get-ChildItem -LiteralPath $extractW -Recurse -File -Filter "trivy.exe" | Select-Object -First 1
  if (-not $trivyExe) { throw "trivy.exe introuvable apres extraction Windows." }

  $trivyLin = Get-ChildItem -LiteralPath $extractL -Recurse -File |
    Where-Object { $_.Name -eq "trivy" -and $_.Extension -ne ".exe" } |
    Select-Object -First 1
  if (-not $trivyLin) { throw "Binaire Linux 'trivy' introuvable apres extraction Linux." }

  Log "trivy.exe: $($trivyExe.FullName)"
  Run-ExternalLogged -Label "trivy_version" -Exe $trivyExe.FullName -ArgList @("version","--quiet") -WorkDir $ScriptDir -Work $Work
  Log "trivy (Linux): $($trivyLin.FullName)"

  $contribDir = $null
  if ($IncludeContrib) {
    $contribDir = Get-ChildItem -LiteralPath $extractW -Recurse -Directory -Filter "contrib" | Select-Object -First 1
    if (-not $contribDir) { $contribDir = Get-ChildItem -LiteralPath $extractL -Recurse -Directory -Filter "contrib" | Select-Object -First 1 }
    if ($contribDir) { Log "contrib: $($contribDir.FullName)" } else { Log "IncludeContrib: contrib/ non trouve." }
  }

  $vulnDbDownloadDate = Get-Date
  $dbDateStamp = $vulnDbDownloadDate.ToString("yyyyMMdd")

  if (-not $OutArchiveProvided) {
    $defaultArchiveName = "trivy-offline-bundle_{0}_{1}.tar.gz" -f $archiveVersion, $dbDateStamp
    $OutArchive = Join-Path $ExportDir $defaultArchiveName
    Log "OutArchive auto: $OutArchive"
  }

  Log "Preload vuln DB -> $cacheDir (date=$dbDateStamp)"
  Invoke-WithRetry -Label "download_db" -MaxAttempts 3 -DelaySeconds 5 -Action {
    Run-ExternalLogged -Label "download_db" -Exe $trivyExe.FullName -ArgList @("image","--cache-dir",$cacheDir,"--download-db-only","--no-progress") -WorkDir $ScriptDir -Work $Work
  }

  Log "Preload java DB -> $cacheDir"
  Invoke-WithRetry -Label "download_java_db" -MaxAttempts 3 -DelaySeconds 5 -Action {
    Run-ExternalLogged -Label "download_java_db" -Exe $trivyExe.FullName -ArgList @("image","--cache-dir",$cacheDir,"--download-java-db-only","--no-progress") -WorkDir $ScriptDir -Work $Work
  }

  # seed-misconfig
  @"
FROM alpine:3.19
"@ | Set-Content -Encoding ASCII (Join-Path $seedDir "Dockerfile")

  @"
apiVersion: v1
kind: Pod
metadata:
  name: trivy-seed
spec:
  containers:
  - name: c
    image: alpine:3.19
    command: ["sh","-c","sleep 3600"]
"@ | Set-Content -Encoding UTF8 (Join-Path $seedDir "pod.yaml")

  $allMisconfigScanners = "azure-arm,cloudformation,dockerfile,helm,kubernetes,terraform,terraformplan-json,terraformplan-snapshot"

  $misconfOut = if ($NoCleanupMisconfigSeed) { Join-Path $seedDir "misconfig_seed.json" } else { Join-Path $Work "misconfig_seed.json" }
  Log "Preload checks bundle misconfig -> $cacheDir (JSON output: $misconfOut)"
  Run-ExternalLogged -Label "download_checks_bundle" -Exe $trivyExe.FullName -ArgList @(
    "config",
    "--cache-dir", $cacheDir,
    "--misconfig-scanners", $allMisconfigScanners,
    "--checks-bundle-repository", $ChecksBundleRepository,
    "--format", "json",
    "--output", $misconfOut,
    "--quiet",
    $seedDir
  ) -WorkDir $ScriptDir -Work $Work

  if (-not $NoCleanupMisconfigSeed) {
    Remove-Item -LiteralPath $misconfOut -Force -ErrorAction SilentlyContinue
  } else {
    Log "NoCleanupMisconfigSeed: conservation de $misconfOut"
  }

  Log "Assemble bundle-root"
  Copy-Item -LiteralPath $trivyExe.FullName -Destination (Join-Path $bundleDir "trivy.exe") -Force
  Copy-Item -LiteralPath $trivyLin.FullName -Destination (Join-Path $bundleDir "trivy") -Force
  Copy-Item -LiteralPath $cacheDir -Destination (Join-Path $bundleDir "cache") -Recurse -Force

  if ($IncludeSeedEffective) {
    Log "Include seed-misconfig/ in archive"
    Copy-Item -LiteralPath $seedDir -Destination (Join-Path $bundleDir "seed-misconfig") -Recurse -Force
  }

  if ($IncludeContrib -and $contribDir) {
    Log "Include contrib/ in archive"
    Copy-Item -LiteralPath $contribDir.FullName -Destination (Join-Path $bundleDir "contrib") -Recurse -Force
  }

  Log "Copy ExtraRootDir content to archive root (collision check)"
  Add-ExtraRootContent -FromDir $ExtraRootDir -ToDir $bundleDir

  Log "bundle-root entries:"
  Get-ChildItem -LiteralPath $bundleDir -Force | ForEach-Object { Log ("  - " + $_.Name) }

  New-Dir (Split-Path -Parent $OutArchive)
  switch ($archiveMode) {
    "7zip" {
      if (-not $sevenZipExe) {
        throw "Mode 7zip selectionne mais 7z.exe/7za.exe est introuvable."
      }
      Log "Create tar.gz via 7z.exe -> $OutArchive"
      Create-TarGzWith7Zip -SevenZipExe $sevenZipExe -SourceDir $bundleDir -OutFile $OutArchive -Work $Work
      break
    }
    "tar" {
      if (-not $tarExe) {
        throw "Mode tar selectionne mais tar.exe est introuvable."
      }
      Log "Create tar.gz via tar.exe -> $OutArchive"
      Create-TarGzWithTar -TarExe $tarExe -SourceDir $bundleDir -OutFile $OutArchive -Work $Work
      break
    }
    default {
      Log "Create tar.gz via Python only -> $OutArchive"
      Py-CreateTarGzWithModes -PythonExe $PythonExe -SourceDir $bundleDir -OutFile $OutArchive -Work $Work
      break
    }
  }

  Log "Archive created: $OutArchive"
  Log ("Extraction Linux: tar -xzf {0} ; ./trivy version" -f (Split-Path -Leaf $OutArchive))

  $outDir = $ExportDir
  $additionalFiles = @(
    "https://epss.cyentia.com/epss_scores-current.csv.gz",
    "https://www.cisa.gov/sites/default/files/csv/known_exploited_vulnerabilities.csv",
    "https://raw.githubusercontent.com/adriens/endoflife-date-snapshots/main/data/details-with-headers.csv"
  )

  Log "Download additional CSV files -> $outDir"
  New-Dir $outDir
  foreach ($url in $additionalFiles) {
    $fileName = [System.IO.Path]::GetFileName(([System.Uri]$url).AbsolutePath)
    $destFile = Join-Path $outDir $fileName
    Download-File -Url $url -OutFile $destFile
  }

  if ($DisableEndOfLifeApiCsv) {
    Log "Export EndOfLife API v1 désactivé via -DisableEndOfLifeApiCsv."
  } else {
    if (-not $ExportEndOfLifeApiCsv) {
      Log "Export EndOfLife API v1 actif par défaut (même sans -ExportEndOfLifeApiCsv)."
    }

    if ([string]::IsNullOrWhiteSpace($EndOfLifeCsvPath)) {
      $EndOfLifeCsvPath = Join-Path $outDir "endoflife_api_v1_full_export.csv"
    } else {
      $EndOfLifeCsvPath = [System.IO.Path]::GetFullPath($EndOfLifeCsvPath)
    }

    $eolPsScript = Join-Path $ScriptDir "export_endoflife_api.ps1"
    $eolPyScript = Join-Path $ScriptDir "export_endoflife_api.py"

    switch ($EndOfLifeExportImplementation) {
      "Python" {
        if (-not (Test-Path -LiteralPath $eolPyScript)) {
          throw "Script introuvable: $eolPyScript"
        }
        Log "Export EndOfLife API v1 via Python -> $EndOfLifeCsvPath"
        $args = @($script:PythonPrefixArgs + @($eolPyScript, "--base-url", $EndOfLifeApiBaseUrl, "--output", $EndOfLifeCsvPath))
        Run-ExternalLogged -Label "Export endOfLife en Python" -Exe $PythonExe -Args $args -WorkDir $ScriptDir -Work $Work
        break
      }
      default {
        if (-not (Test-Path -LiteralPath $eolPsScript)) {
          throw "Script introuvable: $eolPsScript"
        }
        Log "Export EndOfLife API v1 via PowerShell -> $EndOfLifeCsvPath"
        Run-ExternalLogged -Label "Export endOfLife en PowerShell" -Exe "powershell.exe" -Args @(
          "-NoProfile",
          "-ExecutionPolicy", "Bypass",
          "-File", $eolPsScript,
          "-ApiBaseUrl", $EndOfLifeApiBaseUrl,
          "-OutputCsv", $EndOfLifeCsvPath
        ) -WorkDir $ScriptDir -Work $Work
        break
      }
    }
  }
}
catch {
  Log ("ERREUR: " + $_.Exception.Message)
  throw
}
finally {
  if ($KeepWorkDir) {
    Log "Workdir kept: $Work"
  } else {
    if ($Work -and (Test-Path -LiteralPath $Work)) {
      Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Log ("==== end {0} ====" -f (Get-Date))
  Close-Log
}
