<#
.SYNOPSIS
export_endoflife_api_v1.ps1 - Export complet de l'API EndOfLife v1 (/products/full).

.DESCRIPTION
Ce script recupere le payload `/products/full`, ecrit le JSON brut et produit
un CSV aplati avec une ligne par release.

Les colonnes du CSV sont prefixees pour eviter les collisions :
- payload.* : metadonnees de la reponse
- product.* : attributs du produit
- release.* : attributs de la release

Les objets et tableaux sont conserves en JSON compact et aplatits recursivement,
par exemple `product.identifiers[0].type` ou `release.latest.link`.

Si deux chemins ne different que par la casse, un suffixe `__dupN` est ajoute
pour garantir des en-tetes CSV uniques sur les consommateurs case-insensitive.
#>

[CmdletBinding()]
param(
  [string]$OutputCsv = "endoflife_api_v1_full_export.csv",
  [string]$OutputJson = "",
  [string]$ApiBaseUrl = "https://endoflife.date/api/v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  & $env:ComSpec /d /c chcp 65001 > $null
}
catch {
}
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

function Invoke-ApiJson {
  param([Parameter(Mandatory = $true)][string]$Url)

  Invoke-RestMethod -Method Get -Uri $Url -Headers @{
    "User-Agent" = "export_endoflife_api_v1.ps1"
    "Accept"     = "application/json"
  }
}

function Get-ErrorDetails {
  param([Parameter(Mandatory = $true)]$Exception)

  if ($Exception.Response -and $Exception.Response.StatusCode) {
    return ("HTTP {0} ({1})" -f [int]$Exception.Response.StatusCode, $Exception.Response.StatusDescription)
  }

  if ($Exception.Exception -and $Exception.Exception.Message) {
    return $Exception.Exception.Message
  }

  return $Exception.ToString()
}

function Convert-ToCellValue {
  param($Value)

  if ($null -eq $Value) {
    return ""
  }

  if ($Value -is [bool]) {
    if ($Value) {
      return "true"
    }
    return "false"
  }

  if (
    $Value -is [string] -or
    $Value -is [char] -or
    $Value -is [byte] -or
    $Value -is [int16] -or
    $Value -is [int] -or
    $Value -is [int64] -or
    $Value -is [decimal] -or
    $Value -is [single] -or
    $Value -is [double]
  ) {
    return [string]$Value
  }

  return ($Value | ConvertTo-Json -Compress -Depth 100)
}

function Get-ObjectPropertyValue {
  param(
    $Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      return $Object[$Name]
    }
    return $null
  }

  if ($Object.PSObject.Properties.Name -contains $Name) {
    return $Object.$Name
  }

  return $null
}

function Get-ObjectPropertyNames {
  param($Object)

  if ($null -eq $Object) {
    return @()
  }

  if ($Object -is [System.Collections.IDictionary]) {
    return @($Object.Keys | ForEach-Object { [string]$_ })
  }

  return @($Object.PSObject.Properties.Name)
}

function Test-IsEnumerable {
  param($Value)

  return (
    $null -ne $Value -and
    $Value -is [System.Collections.IEnumerable] -and
    -not ($Value -is [string]) -and
    -not ($Value -is [pscustomobject]) -and
    -not ($Value -is [System.Collections.IDictionary])
  )
}

function Convert-ToObjectArray {
  param($Value)

  if ($null -eq $Value) {
    return @()
  }

  if (Test-IsEnumerable -Value $Value) {
    return @($Value)
  }

  return @($Value)
}

function Resolve-ColumnName {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$ColumnAliases,
    [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$UsedColumnNames
  )

  if ($ColumnAliases.ContainsKey($Path)) {
    return [string]$ColumnAliases[$Path]
  }

  $candidate = $Path
  if (-not $UsedColumnNames.Add($candidate.ToLowerInvariant())) {
    $suffix = 2
    do {
      $candidate = "{0}__dup{1}" -f $Path, $suffix
      $suffix++
    } while (-not $UsedColumnNames.Add($candidate.ToLowerInvariant()))
  }

  $ColumnAliases[$Path] = $candidate
  return $candidate
}

function Set-FlattenedValue {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Row,
    [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$DynamicColumns,
    [Parameter(Mandatory = $true)][hashtable]$ColumnAliases,
    [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$UsedColumnNames,
    [Parameter(Mandatory = $true)][string]$Prefix,
    $Value
  )

  $columnName = Resolve-ColumnName -Path $Prefix -ColumnAliases $ColumnAliases -UsedColumnNames $UsedColumnNames
  $null = $DynamicColumns.Add($columnName)

  if (
    $null -eq $Value -or
    $Value -is [string] -or
    $Value -is [char] -or
    $Value -is [byte] -or
    $Value -is [int16] -or
    $Value -is [int] -or
    $Value -is [int64] -or
    $Value -is [decimal] -or
    $Value -is [single] -or
    $Value -is [double] -or
    $Value -is [bool]
  ) {
    $Row[$columnName] = Convert-ToCellValue -Value $Value
    return
  }

  if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
    $Row[$columnName] = Convert-ToCellValue -Value $Value
    foreach ($name in Get-ObjectPropertyNames -Object $Value) {
      $childValue = Get-ObjectPropertyValue -Object $Value -Name $name
      Set-FlattenedValue -Row $Row -DynamicColumns $DynamicColumns -ColumnAliases $ColumnAliases -UsedColumnNames $UsedColumnNames -Prefix ("{0}.{1}" -f $Prefix, $name) -Value $childValue
    }
    return
  }

  if (Test-IsEnumerable -Value $Value) {
    $items = @($Value)
    $Row[$columnName] = Convert-ToCellValue -Value $Value
    for ($index = 0; $index -lt $items.Count; $index++) {
      Set-FlattenedValue -Row $Row -DynamicColumns $DynamicColumns -ColumnAliases $ColumnAliases -UsedColumnNames $UsedColumnNames -Prefix ("{0}[{1}]" -f $Prefix, $index) -Value $items[$index]
    }
    return
  }

  $Row[$columnName] = Convert-ToCellValue -Value $Value
}

function Copy-OrderedDictionary {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Source)

  $target = [ordered]@{}
  foreach ($key in $Source.Keys) {
    $target[$key] = $Source[$key]
  }
  return $target
}

$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
  $OutputJson = [System.IO.Path]::ChangeExtension($OutputCsv, ".json")
}

$fullUrl = "$ApiBaseUrl/products/full"
Write-Host "[INFO] Recuperation du payload complet: $fullUrl"

try {
  $payload = Invoke-ApiJson -Url $fullUrl
}
catch {
  $details = Get-ErrorDetails -Exception $_
  throw ("Echec de recuperation de /products/full: {0}" -f $details)
}

$products = @(Convert-ToObjectArray -Value (Get-ObjectPropertyValue -Object $payload -Name "result") | Where-Object { $_ -is [pscustomobject] -or $_ -is [System.Collections.IDictionary] })
if ($products.Count -eq 0) {
  $payloadType = if ($null -eq $payload) { "null" } else { $payload.GetType().FullName }
  throw ("La reponse de /products/full ne contient pas de liste 'result' exploitable. Type recu: {0}" -f $payloadType)
}
Write-Host ("[INFO] {0} produit(s) trouves dans /products/full." -f $products.Count)

$jsonDir = Split-Path -Parent $OutputJson
if (-not [string]::IsNullOrWhiteSpace($jsonDir)) {
  New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
}
$jsonText = $payload | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($OutputJson, ($jsonText + [Environment]::NewLine), $Utf8NoBom)
Write-Host "[INFO] JSON brut ecrit: $OutputJson"

$rows = New-Object System.Collections.Generic.List[object]
$dynamicColumns = New-Object System.Collections.Generic.HashSet[string]
$columnAliases = @{}
$usedColumnNames = New-Object System.Collections.Generic.HashSet[string]
$null = $dynamicColumns.Add("product")
$null = $dynamicColumns.Add("release_index")
$null = $usedColumnNames.Add("product")
$null = $usedColumnNames.Add("release_index")

$payloadPropertyNames = @(Get-ObjectPropertyNames -Object $payload | Where-Object { $_ -ne "result" })
$totalProducts = $products.Count
$currentProduct = 0

foreach ($productItem in $products) {
  $currentProduct++
  $productName = [string](Get-ObjectPropertyValue -Object $productItem -Name "name")
  if ([string]::IsNullOrWhiteSpace($productName)) {
    $productName = [string](Get-ObjectPropertyValue -Object $productItem -Name "label")
  }
  $productName = $productName.Trim()

  $releasesValue = Get-ObjectPropertyValue -Object $productItem -Name "releases"
  $releases = @(Convert-ToObjectArray -Value $releasesValue | Where-Object { $_ -is [pscustomobject] -or $_ -is [System.Collections.IDictionary] })

  Write-Progress -Activity "Export EndOfLife API" -Status ("Produit {0}/{1}: {2}" -f $currentProduct, $totalProducts, $productName) -PercentComplete (($currentProduct / [Math]::Max($totalProducts, 1)) * 100)
  Write-Host ("[{0}/{1}] [INFO] Aplatissement de '{2}' ({3} release(s))." -f $currentProduct, $totalProducts, $productName, $releases.Count)

  $baseRow = [ordered]@{
    product       = $productName
    release_index = ""
  }

  foreach ($name in $payloadPropertyNames) {
    $value = Get-ObjectPropertyValue -Object $payload -Name $name
    Set-FlattenedValue -Row $baseRow -DynamicColumns $dynamicColumns -ColumnAliases $columnAliases -UsedColumnNames $usedColumnNames -Prefix ("payload.{0}" -f $name) -Value $value
  }

  foreach ($name in Get-ObjectPropertyNames -Object $productItem) {
    if ($name -eq "releases") {
      continue
    }
    $value = Get-ObjectPropertyValue -Object $productItem -Name $name
    Set-FlattenedValue -Row $baseRow -DynamicColumns $dynamicColumns -ColumnAliases $columnAliases -UsedColumnNames $usedColumnNames -Prefix ("product.{0}" -f $name) -Value $value
  }
  Set-FlattenedValue -Row $baseRow -DynamicColumns $dynamicColumns -ColumnAliases $columnAliases -UsedColumnNames $usedColumnNames -Prefix "product.releases_count" -Value $releases.Count

  if ($releases.Count -gt 0) {
    $releaseIndex = 0
    foreach ($release in $releases) {
      $releaseIndex++
      $row = Copy-OrderedDictionary -Source $baseRow
      $row["release_index"] = [string]$releaseIndex
      Set-FlattenedValue -Row $row -DynamicColumns $dynamicColumns -ColumnAliases $columnAliases -UsedColumnNames $usedColumnNames -Prefix "release" -Value $release
      $rows.Add([pscustomobject]$row) | Out-Null
    }
  }
  else {
    $rows.Add([pscustomobject](Copy-OrderedDictionary -Source $baseRow)) | Out-Null
  }
}

Write-Progress -Activity "Export EndOfLife API" -Completed

$outputDir = Split-Path -Parent $OutputCsv
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$finalColumns = @("product", "release_index") + @($dynamicColumns | Where-Object { $_ -notin @("product", "release_index") } | Sort-Object)

if ($rows.Count -gt 0) {
  $csvLines = $rows |
    Select-Object -Property $finalColumns |
    ConvertTo-Csv -NoTypeInformation
  [System.IO.File]::WriteAllLines($OutputCsv, $csvLines, [System.Text.UTF8Encoding]::new($true))
}
else {
  [System.IO.File]::WriteAllText($OutputCsv, (($finalColumns -join ",") + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($true))
}

Write-Host "[INFO] CSV aplati ecrit: $OutputCsv"
Write-Host "Export termine: $OutputCsv ($($rows.Count) lignes). JSON: $OutputJson"