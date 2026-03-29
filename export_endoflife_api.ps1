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
./export_endoflife_api.ps1

.EXAMPLE
./export_endoflife_api.ps1 -OutputCsv "D:\tmp\endoflife_api_v1_full_export.csv"

.EXAMPLE
./export_endoflife_api.ps1 -ApiBaseUrl "https://endoflife.date/api/v1" -OutputCsv "./out/eol.csv"
#>

[CmdletBinding()]
param(
  [string]$OutputCsv = "endoflife_api_v1_full_export.csv",
  [string]$ApiBaseUrl = "https://endoflife.date/api/v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Force l'UTF-8 pour l'affichage console afin d'éviter les accents illisibles (ex: dÃ©faut).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

function Invoke-ApiJson {
  param([Parameter(Mandatory=$true)][string]$Url)

  return Invoke-RestMethod -Method Get -Uri $Url -Headers @{
    "User-Agent" = "export_endoflife_api_v1.ps1"
    "Accept" = "application/json"
  }
}

function Get-ErrorDetails {
  param([Parameter(Mandatory=$true)]$Exception)

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

function Get-ProductList {
  param($Payload)

  if ($Payload -is [System.Array]) {
    return @($Payload)
  }

  if ($Payload -is [pscustomobject] -or $Payload -is [hashtable]) {
    foreach ($k in @("products", "items", "data", "result")) {
      if ($Payload.PSObject.Properties.Name -contains $k -and $Payload.$k -is [System.Array]) {
        return @($Payload.$k)
      }
    }
  }

  return @()
}

$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
$productsUrl = "$ApiBaseUrl/products"

$productsPayload = Invoke-ApiJson -Url $productsUrl
$products = Get-ProductList -Payload $productsPayload
if ($products.Count -eq 0) {
  $payloadType = if ($null -eq $productsPayload) { "null" } else { $productsPayload.GetType().FullName }
  throw ("La réponse de /products ne contient pas de liste de produits reconnue. Type reçu: {0}" -f $payloadType)
}
Write-Host ("[INFO] {0} produits trouvés." -f $products.Count)

$rows = New-Object System.Collections.Generic.List[object]
$dynamicColumns = New-Object System.Collections.Generic.HashSet[string]
$errors = New-Object System.Collections.Generic.List[string]
$totalProducts = $products.Count
$currentProduct = 0

foreach ($productItem in $products) {
  $currentProduct++
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
    Write-Warning ("[{0}/{1}] Produit ignoré (nom vide)." -f $currentProduct, $totalProducts)
    continue
  }

  Write-Progress -Activity "Export EndOfLife API" -Status ("Produit {0}/{1}: {2}" -f $currentProduct, $totalProducts, $product) -PercentComplete (($currentProduct / $totalProducts) * 100)
  Write-Host ("[{0}/{1}] [INFO] Extraction des releases pour '{2}'..." -f $currentProduct, $totalProducts, $product)

  $productEncoded = [uri]::EscapeDataString($product)
  $productUrl = "$ApiBaseUrl/products/$productEncoded"

  try {
    $productPayload = Invoke-ApiJson -Url $productUrl
  }
  catch {
    $details = Get-ErrorDetails -Exception $_
    $message = ("[{0}/{1}] [ERROR] Echec pour '{2}': {3}" -f $currentProduct, $totalProducts, $product, $details)
    Write-Error $message
    $errors.Add($message) | Out-Null
    continue
  }
  $releases = Get-ReleaseObjects -Payload $productPayload
  Write-Host ("[{0}/{1}] [OK] {2}: {3} release(s) récupérée(s)." -f $currentProduct, $totalProducts, $product, $releases.Count)

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

Write-Progress -Activity "Export EndOfLife API" -Completed

$outputDir = Split-Path -Parent $OutputCsv
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$finalColumns = @("product", "release_index") + @($dynamicColumns | Sort-Object)

$rows |
  Select-Object -Property $finalColumns |
  Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

if ($errors.Count -gt 0) {
  Write-Warning ("Export terminé avec {0} erreur(s) produit. Consultez les messages [ERROR] ci-dessus." -f $errors.Count)
} else {
  Write-Host "[INFO] Export terminé sans erreur produit."
}

Write-Host "Export terminé: $OutputCsv ($($rows.Count) lignes)."
