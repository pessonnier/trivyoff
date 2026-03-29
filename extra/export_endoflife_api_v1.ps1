<#
.SYNOPSIS
export_endoflife_api_v1.ps1 - Export complet de l'API EndOfLife v1 au format CSV.

.DESCRIPTION
Ce script interroge l'API EndOfLife v1 en deux étapes:
1) récupération de la liste des produits via /products
2) récupération des releases de chaque produit via /products/{product}

Le résultat est aplati dans un seul CSV (1 ligne par release), avec:
- colonnes fixes: product, release_index
- colonnes dynamiques: union de toutes les clés JSON rencontrées dans les releases

Les valeurs complexes (objets/listes) sont sérialisées en JSON compact.

.PARAMETER OutputCsv
Chemin du fichier CSV de sortie.
Par défaut: ./endoflife_api_v1_full_export.csv

.PARAMETER ApiBaseUrl
URL de base de l'API EndOfLife v1.
Par défaut: https://endoflife.date/api/v1

.EXAMPLE
./export_endoflife_api_v1.ps1

.EXAMPLE
./export_endoflife_api_v1.ps1 -OutputCsv "D:\tmp\endoflife_api_v1_full_export.csv"

.EXAMPLE
./export_endoflife_api_v1.ps1 -ApiBaseUrl "https://endoflife.date/api/v1" -OutputCsv "./out/eol.csv"
#>

[CmdletBinding()]
param(
  [string]$OutputCsv = "endoflife_api_v1_full_export.csv",
  [string]$ApiBaseUrl = "https://endoflife.date/api/v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-ApiJson {
  param([Parameter(Mandatory=$true)][string]$Url)

  return Invoke-RestMethod -Method Get -Uri $Url -Headers @{
    "User-Agent" = "export_endoflife_api_v1.ps1"
    "Accept" = "application/json"
  }
}

function Convert-ToCellValue {
  param($Value)

  if ($null -eq $Value) {
    return ""
  }

  if ($Value -is [string] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bool]) {
    return [string]$Value
  }

  return ($Value | ConvertTo-Json -Compress -Depth 20)
}

function Get-ReleaseObjects {
  param($Payload)

  if ($Payload -is [System.Array]) {
    return @($Payload | Where-Object { $_ -is [pscustomobject] -or $_ -is [hashtable] })
  }

  if ($Payload -is [pscustomobject] -or $Payload -is [hashtable]) {
    foreach ($k in @("releases", "cycles", "data", "result", "items")) {
      if ($Payload.PSObject.Properties.Name -contains $k -and $Payload.$k -is [System.Array]) {
        return @($Payload.$k | Where-Object { $_ -is [pscustomobject] -or $_ -is [hashtable] })
      }
    }
  }

  return @()
}

$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
$productsUrl = "$ApiBaseUrl/products"

$products = Invoke-ApiJson -Url $productsUrl
if (-not ($products -is [System.Array])) {
  throw "La réponse de /products n'est pas une liste JSON."
}

$rows = New-Object System.Collections.Generic.List[object]
$dynamicColumns = New-Object System.Collections.Generic.HashSet[string]

foreach ($productItem in $products) {
  $product = ""

  if ($productItem -is [string]) {
    $product = $productItem
  } elseif ($productItem -is [pscustomobject] -or $productItem -is [hashtable]) {
    if ($productItem.PSObject.Properties.Name -contains "slug") {
      $product = [string]$productItem.slug
    } elseif ($productItem.PSObject.Properties.Name -contains "product") {
      $product = [string]$productItem.product
    }
  }

  $product = $product.Trim()
  if ([string]::IsNullOrWhiteSpace($product)) {
    continue
  }

  $productEncoded = [uri]::EscapeDataString($product)
  $productUrl = "$ApiBaseUrl/products/$productEncoded"

  $productPayload = Invoke-ApiJson -Url $productUrl
  $releases = Get-ReleaseObjects -Payload $productPayload

  $idx = 0
  foreach ($release in $releases) {
    $idx++

    $line = [ordered]@{
      product = $product
      release_index = [string]$idx
    }

    foreach ($prop in $release.PSObject.Properties) {
      $line[$prop.Name] = Convert-ToCellValue -Value $prop.Value
      $null = $dynamicColumns.Add($prop.Name)
    }

    $rows.Add([pscustomobject]$line)
  }
}

$outputDir = Split-Path -Parent $OutputCsv
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$finalColumns = @("product", "release_index") + @($dynamicColumns | Sort-Object)

$rows |
  Select-Object -Property $finalColumns |
  Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Export terminé: $OutputCsv ($($rows.Count) lignes)."
