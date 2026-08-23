<#
.SYNOPSIS
Telecharge les referentiels EndOfLife API v1, EPSS et CISA KEV.

.DESCRIPTION
Avec les valeurs par defaut, le script produit dans le dossier Export situe a
cote du script :

- endoflife_api_v1_full_export.csv
- endoflife_api_v1_full_export.json
- epss_scores-current.csv
- known_exploited_vulnerabilities.csv

L'export EndOfLife est delegue a export_endoflife_api.ps1 et produit un CSV
simplifie avec une ligne par release et 21 colonnes de cycle de vie fixes.
EPSS est telecharge
au format CSV compresse avec gzip, puis decompresse. Le catalogue CISA KEV est
telecharge directement au format CSV.

Les telechargements EPSS et CISA ainsi que les sorties EndOfLife sont d'abord
ecrits dans des fichiers temporaires. Les destinations finales ne sont
remplacees qu'apres validation des fichiers produits.

.PARAMETER Extraction
Referentiels a produire. Valeurs possibles : All, EndOfLife, EPSS, CisaKev.
La valeur par defaut est All.

.PARAMETER OutputDirectory
Dossier utilise pour les noms de fichiers par defaut. Par defaut : Export a
cote du script.

.EXAMPLE
.\export_security_references.ps1

.EXAMPLE
.\export_security_references.ps1 -Extraction EPSS,CisaKev

.EXAMPLE
.\export_security_references.ps1 -Extraction EndOfLife -OutputDirectory D:\Exports

.EXAMPLE
.\export_security_references.ps1 -EpssUrl https://serveur.exemple/epss.csv.gz -EpssCsvPath D:\Exports\epss.csv
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Alias("Only", "Sources")]
  [ValidateSet("All", "EndOfLife", "EPSS", "CisaKev")]
  [string[]]$Extraction = @("All"),

  [string]$OutputDirectory = "",

  [uri]$EndOfLifeApiBaseUrl = "https://endoflife.date/api/v1",
  [uri]$EpssUrl = "https://epss.empiricalsecurity.com/epss_scores-current.csv.gz",
  [uri]$CisaKevUrl = "https://www.cisa.gov/sites/default/files/csv/known_exploited_vulnerabilities.csv",

  [string]$EndOfLifeExporterPath = "",
  [string]$EndOfLifeCsvPath = "",
  [string]$EndOfLifeJsonPath = "",
  [string]$EpssCsvPath = "",
  [string]$CisaKevCsvPath = "",

  [ValidateRange(10, 3600)]
  [int]$RequestTimeoutSec = 300,

  [ValidateNotNullOrEmpty()]
  [string]$UserAgent = "trivyoff-security-reference-export/1.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  if ([IO.Path]::IsPathRooted($Path)) {
    return [IO.Path]::GetFullPath($Path)
  }

  return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-OutputPath {
  param(
    [string]$ConfiguredPath,
    [Parameter(Mandatory = $true)][string]$DefaultName,
    [Parameter(Mandatory = $true)][string]$DefaultDirectory
  )

  if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
    return [IO.Path]::GetFullPath((Join-Path $DefaultDirectory $DefaultName))
  }

  return Resolve-AbsolutePath -Path $ConfiguredPath -BasePath (Get-Location).Path
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function New-TemporarySiblingPath {
  param([Parameter(Mandatory = $true)][string]$DestinationPath)

  $parent = Split-Path -Parent $DestinationPath
  $leaf = Split-Path -Leaf $DestinationPath
  return Join-Path $parent (".{0}.{1}.partial" -f $leaf, [guid]::NewGuid().ToString("N"))
}

function Remove-TemporaryFile {
  param([string]$Path)

  if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Remove-Item -LiteralPath $Path -Force
  }
}

function Assert-NonEmptyFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Description n'a pas ete produit : $Path"
  }

  $item = Get-Item -LiteralPath $Path
  if ($item.Length -le 0) {
    throw "$Description est vide : $Path"
  }
}

function Assert-CsvHeader {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$HeaderPattern,
    [Parameter(Mandatory = $true)][string]$Description
  )

  Assert-NonEmptyFile -Path $Path -Description $Description
  $headerFound = @(Get-Content -LiteralPath $Path -TotalCount 10 | Where-Object { $_ -match $HeaderPattern }).Count -gt 0
  if (-not $headerFound) {
    throw "$Description ne contient pas l'en-tete CSV attendu : $Path"
  }
}

function Invoke-DownloadFile {
  param(
    [Parameter(Mandatory = $true)][uri]$Uri,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$DownloadUserAgent
  )

  Write-Host "[INFO] Telechargement : $Uri"
  Invoke-WebRequest -Method Get -Uri $Uri -OutFile $DestinationPath -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent $DownloadUserAgent
  Assert-NonEmptyFile -Path $DestinationPath -Description "Telechargement"
}

function Expand-GzipFile {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $source = [IO.File]::OpenRead($SourcePath)
  try {
    $gzip = [IO.Compression.GzipStream]::new($source, [IO.Compression.CompressionMode]::Decompress)
    try {
      $destination = [IO.File]::Create($DestinationPath)
      try {
        $gzip.CopyTo($destination)
      }
      finally {
        $destination.Dispose()
      }
    }
    finally {
      $gzip.Dispose()
    }
  }
  finally {
    $source.Dispose()
  }
}

function Move-ValidatedOutput {
  param(
    [Parameter(Mandatory = $true)][string]$TemporaryPath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  Move-Item -LiteralPath $TemporaryPath -Destination $DestinationPath -Force
}

function Export-EndOfLifeData {
  param(
    [Parameter(Mandatory = $true)][string]$ExporterPath,
    [Parameter(Mandatory = $true)][uri]$ApiBaseUrl,
    [Parameter(Mandatory = $true)][string]$CsvPath,
    [Parameter(Mandatory = $true)][string]$JsonPath
  )

  if (-not (Test-Path -LiteralPath $ExporterPath -PathType Leaf)) {
    throw "Script EndOfLife introuvable : $ExporterPath"
  }

  Ensure-ParentDirectory -Path $CsvPath
  Ensure-ParentDirectory -Path $JsonPath
  $temporaryCsv = New-TemporarySiblingPath -DestinationPath $CsvPath
  $temporaryJson = New-TemporarySiblingPath -DestinationPath $JsonPath

  try {
    Write-Host "[INFO] Export EndOfLife API v1 via : $ExporterPath"
    & $ExporterPath -OutputCsv $temporaryCsv -OutputJson $temporaryJson -ApiBaseUrl $ApiBaseUrl.AbsoluteUri.TrimEnd('/')
    Assert-CsvHeader -Path $temporaryCsv -HeaderPattern '^(?:\xEF\xBB\xBF|\xFEFF)?"product","cycle","eol","latest","release_date","latest_release_date","lts","extendedSupport","support_date","is_supported","eol_date","is_eol","lts_date","is_lts","discontinued_date","is_discontinued","extended_support_date","is_extended_support","link","www","discontinued"\s*$' -Description "CSV EndOfLife simplifie"
    Assert-NonEmptyFile -Path $temporaryJson -Description "JSON EndOfLife"
    Move-ValidatedOutput -TemporaryPath $temporaryCsv -DestinationPath $CsvPath
    Move-ValidatedOutput -TemporaryPath $temporaryJson -DestinationPath $JsonPath
  }
  finally {
    Remove-TemporaryFile -Path $temporaryCsv
    Remove-TemporaryFile -Path $temporaryJson
  }
}

function Export-EpssData {
  param(
    [Parameter(Mandatory = $true)][uri]$Uri,
    [Parameter(Mandatory = $true)][string]$CsvPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$DownloadUserAgent
  )

  Ensure-ParentDirectory -Path $CsvPath
  $temporaryCsv = New-TemporarySiblingPath -DestinationPath $CsvPath
  $temporaryGzip = "$temporaryCsv.gz"

  try {
    Invoke-DownloadFile -Uri $Uri -DestinationPath $temporaryGzip -TimeoutSec $TimeoutSec -DownloadUserAgent $DownloadUserAgent
    Expand-GzipFile -SourcePath $temporaryGzip -DestinationPath $temporaryCsv
    Assert-CsvHeader -Path $temporaryCsv -HeaderPattern '^(?:\xEF\xBB\xBF|\xFEFF)?cve,epss,percentile\s*$' -Description "CSV EPSS"
    Move-ValidatedOutput -TemporaryPath $temporaryCsv -DestinationPath $CsvPath
  }
  finally {
    Remove-TemporaryFile -Path $temporaryGzip
    Remove-TemporaryFile -Path $temporaryCsv
  }
}

function Export-CisaKevData {
  param(
    [Parameter(Mandatory = $true)][uri]$Uri,
    [Parameter(Mandatory = $true)][string]$CsvPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$DownloadUserAgent
  )

  Ensure-ParentDirectory -Path $CsvPath
  $temporaryCsv = New-TemporarySiblingPath -DestinationPath $CsvPath

  try {
    Invoke-DownloadFile -Uri $Uri -DestinationPath $temporaryCsv -TimeoutSec $TimeoutSec -DownloadUserAgent $DownloadUserAgent
    Assert-CsvHeader -Path $temporaryCsv -HeaderPattern '^(?:\xEF\xBB\xBF|\xFEFF)?cveID,vendorProject,product,' -Description "CSV CISA KEV"
    Move-ValidatedOutput -TemporaryPath $temporaryCsv -DestinationPath $CsvPath
  }
  finally {
    Remove-TemporaryFile -Path $temporaryCsv
  }
}

$baseDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  Join-Path $PSScriptRoot "Export"
}
else {
  Resolve-AbsolutePath -Path $OutputDirectory -BasePath (Get-Location).Path
}
$baseDirectory = [IO.Path]::GetFullPath($baseDirectory)

$exporterPath = if ([string]::IsNullOrWhiteSpace($EndOfLifeExporterPath)) {
  Join-Path $PSScriptRoot "export_endoflife_api.ps1"
}
else {
  Resolve-AbsolutePath -Path $EndOfLifeExporterPath -BasePath (Get-Location).Path
}

$resolvedEndOfLifeCsv = Resolve-OutputPath -ConfiguredPath $EndOfLifeCsvPath -DefaultName "endoflife_api_v1_full_export.csv" -DefaultDirectory $baseDirectory
$resolvedEndOfLifeJson = Resolve-OutputPath -ConfiguredPath $EndOfLifeJsonPath -DefaultName "endoflife_api_v1_full_export.json" -DefaultDirectory $baseDirectory
$resolvedEpssCsv = Resolve-OutputPath -ConfiguredPath $EpssCsvPath -DefaultName "epss_scores-current.csv" -DefaultDirectory $baseDirectory
$resolvedCisaKevCsv = Resolve-OutputPath -ConfiguredPath $CisaKevCsvPath -DefaultName "known_exploited_vulnerabilities.csv" -DefaultDirectory $baseDirectory

$selected = @{}
if ($Extraction -contains "All") {
  foreach ($name in @("EndOfLife", "EPSS", "CisaKev")) {
    $selected[$name] = $true
  }
}
else {
  foreach ($name in $Extraction) {
    $selected[$name] = $true
  }
}

$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

if ($selected.ContainsKey("EndOfLife") -and $PSCmdlet.ShouldProcess("$resolvedEndOfLifeCsv ; $resolvedEndOfLifeJson", "Exporter EndOfLife API v1")) {
  try {
    Export-EndOfLifeData -ExporterPath $exporterPath -ApiBaseUrl $EndOfLifeApiBaseUrl -CsvPath $resolvedEndOfLifeCsv -JsonPath $resolvedEndOfLifeJson
    foreach ($path in @($resolvedEndOfLifeCsv, $resolvedEndOfLifeJson)) {
      $item = Get-Item -LiteralPath $path
      $results.Add([pscustomobject]@{ Extraction = "EndOfLife"; Path = $item.FullName; Bytes = $item.Length }) | Out-Null
    }
  }
  catch {
    $failures.Add("EndOfLife : $($_.Exception.Message)") | Out-Null
    Write-Warning $failures[$failures.Count - 1]
  }
}

if ($selected.ContainsKey("EPSS") -and $PSCmdlet.ShouldProcess($resolvedEpssCsv, "Telecharger et decomprimer EPSS")) {
  try {
    Export-EpssData -Uri $EpssUrl -CsvPath $resolvedEpssCsv -TimeoutSec $RequestTimeoutSec -DownloadUserAgent $UserAgent
    $item = Get-Item -LiteralPath $resolvedEpssCsv
    $results.Add([pscustomobject]@{ Extraction = "EPSS"; Path = $item.FullName; Bytes = $item.Length }) | Out-Null
  }
  catch {
    $failures.Add("EPSS : $($_.Exception.Message)") | Out-Null
    Write-Warning $failures[$failures.Count - 1]
  }
}

if ($selected.ContainsKey("CisaKev") -and $PSCmdlet.ShouldProcess($resolvedCisaKevCsv, "Telecharger CISA KEV")) {
  try {
    Export-CisaKevData -Uri $CisaKevUrl -CsvPath $resolvedCisaKevCsv -TimeoutSec $RequestTimeoutSec -DownloadUserAgent $UserAgent
    $item = Get-Item -LiteralPath $resolvedCisaKevCsv
    $results.Add([pscustomobject]@{ Extraction = "CisaKev"; Path = $item.FullName; Bytes = $item.Length }) | Out-Null
  }
  catch {
    $failures.Add("CisaKev : $($_.Exception.Message)") | Out-Null
    Write-Warning $failures[$failures.Count - 1]
  }
}

if ($results.Count -gt 0) {
  Write-Host ""
  Write-Host "[INFO] Fichiers produits :"
  $results | Format-Table -AutoSize | Out-Host
}

if ($failures.Count -gt 0) {
  throw ("Une ou plusieurs extractions ont echoue :`n- {0}" -f ($failures -join "`n- "))
}

Write-Host ("[INFO] Export termine : {0} fichier(s)." -f $results.Count)
