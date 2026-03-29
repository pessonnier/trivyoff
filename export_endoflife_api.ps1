<#
.SYNOPSIS
export_endoflife_api_v1.ps1 - Export complet de l'API EndOfLife v1 au format CSV.

.DESCRIPTION
Ce script interroge l'API EndOfLife v1 en deux etapes:
1) recuperation de la liste des produits via /products
2) recuperation des releases de chaque produit via /products/{product}

Le resultat est aplati dans un seul CSV (1 ligne par release), avec:
- colonnes fixes: product, release_index
- colonnes dynamiques: union de toutes les cles JSON rencontrees dans les releases

Les valeurs complexes (objets/listes) sont serialisees en JSON compact.
#>

[CmdletBinding()]
param(
  [string]$OutputCsv = "endoflife_api_v1_full_export.csv",
  [string]$ApiBaseUrl = "https://endoflife.date/api/v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Force UTF-8 for the attached console and for file output.
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

  return Invoke-RestMethod -Method Get -Uri $Url -Headers @{
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

  if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bool]) {
    return [string]$Value
  }

  return ($Value | ConvertTo-Json -Compress -Depth 20)
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

function Convert-ToObjectArray {
  param($Value)

  if ($null -eq $Value -or $Value -is [string]) {
    return @()
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject]) -and -not ($Value -is [hashtable]) -and -not ($Value -is [System.Collections.IDictionary])) {
    return @($Value)
  }

  return @($Value)
}

function Get-ReleaseObjects {
  param($Payload)

  if ($null -eq $Payload) {
    return @()
  }

  if ($Payload -is [System.Collections.IEnumerable] -and -not ($Payload -is [string]) -and -not ($Payload -is [pscustomobject]) -and -not ($Payload -is [hashtable]) -and -not ($Payload -is [System.Collections.IDictionary])) {
    return @($Payload | Where-Object {
      $_ -is [pscustomobject] -or $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary]
    })
  }

  $containers = New-Object System.Collections.Generic.List[object]
  $containers.Add($Payload) | Out-Null

  foreach ($rootKey in @("result", "data")) {
    $rootValue = Get-ObjectPropertyValue -Object $Payload -Name $rootKey
    if ($null -ne $rootValue) {
      $containers.Add($rootValue) | Out-Null
    }
  }

  foreach ($container in $containers) {
    foreach ($candidate in (Convert-ToObjectArray -Value $container)) {
      if ($candidate -is [pscustomobject] -or $candidate -is [hashtable] -or $candidate -is [System.Collections.IDictionary]) {
        foreach ($key in @("releases", "cycles", "items")) {
          $value = Get-ObjectPropertyValue -Object $candidate -Name $key
          if ($null -eq $value -or $value -is [string]) {
            continue
          }

          $items = @((Convert-ToObjectArray -Value $value) | Where-Object {
            $_ -is [pscustomobject] -or $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary]
          })
          if ($items.Count -gt 0) {
            return $items
          }
        }
      }
    }
  }

  return @()
}

function Get-ProductPayload {
  param(
    [Parameter(Mandatory = $true)][string]$ApiBaseUrl,
    [Parameter(Mandatory = $true)][string]$Product,
    [string]$ProductUri
  )

  $productEncoded = [uri]::EscapeDataString($Product)
  $candidateUrls = @(
    $ProductUri,
    "$ApiBaseUrl/products/$productEncoded/",
    "$ApiBaseUrl/products/$productEncoded",
    "$ApiBaseUrl/products/$productEncoded/releases",
    "$ApiBaseUrl/$productEncoded"
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  $lastError = $null
  foreach ($candidateUrl in $candidateUrls) {
    try {
      return Invoke-ApiJson -Url $candidateUrl
    }
    catch {
      $lastError = $_
    }
  }

  if ($null -ne $lastError) {
    throw $lastError
  }

  throw ("Impossible de recuperer les releases pour '{0}'." -f $Product)
}

function Get-ProductList {
  param($Payload)

  if ($null -eq $Payload) {
    return @()
  }

  foreach ($candidate in (Convert-ToObjectArray -Value $Payload)) {
    if ($candidate -is [string]) {
      return @($Payload)
    }

    if ($candidate -is [pscustomobject] -or $candidate -is [hashtable] -or $candidate -is [System.Collections.IDictionary]) {
      foreach ($key in @("products", "items", "data", "result")) {
        $value = Get-ObjectPropertyValue -Object $candidate -Name $key
        if ($null -ne $value -and -not ($value -is [string])) {
          return @(Convert-ToObjectArray -Value $value)
        }
      }
    }
  }

  return @()
}

function Resolve-ProductName {
  param($ProductItem)

  if ($ProductItem -is [string]) {
    return $ProductItem.Trim()
  }

  if ($ProductItem -is [pscustomobject] -or $ProductItem -is [hashtable] -or $ProductItem -is [System.Collections.IDictionary]) {
    foreach ($key in @("slug", "product", "name", "id")) {
      $value = Get-ObjectPropertyValue -Object $ProductItem -Name $key
      if ($null -ne $value) {
        $candidate = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
          return $candidate.Trim()
        }
      }
    }
  }

  return ""
}

function Resolve-ProductUri {
  param($ProductItem)

  if ($ProductItem -is [pscustomobject] -or $ProductItem -is [hashtable] -or $ProductItem -is [System.Collections.IDictionary]) {
    $value = Get-ObjectPropertyValue -Object $ProductItem -Name "uri"
    if ($null -ne $value) {
      $candidate = [string]$value
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        return $candidate.Trim()
      }
    }
  }

  return ""
}

function Get-CollectionCount {
  param($Value)

  if ($null -eq $Value) {
    return 0
  }

  if ($Value -is [System.Collections.ICollection]) {
    return $Value.Count
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    return @($Value).Count
  }

  return 1
}

$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
$productsUrl = "$ApiBaseUrl/products"

$productsPayload = Invoke-ApiJson -Url $productsUrl
$products = Get-ProductList -Payload $productsPayload
$productsCount = Get-CollectionCount -Value $products
if ($productsCount -eq 0) {
  $payloadType = if ($null -eq $productsPayload) { "null" } else { $productsPayload.GetType().FullName }
  throw ("La reponse de /products ne contient pas de liste de produits reconnue. Type recu: {0}" -f $payloadType)
}
Write-Host ("[INFO] {0} produits trouves." -f $productsCount)

$rows = New-Object System.Collections.Generic.List[object]
$dynamicColumns = New-Object System.Collections.Generic.HashSet[string]
$errors = New-Object System.Collections.Generic.List[string]
$totalProducts = $productsCount
$currentProduct = 0

foreach ($productItem in $products) {
  $currentProduct++
  $product = Resolve-ProductName -ProductItem $productItem
  $productUri = Resolve-ProductUri -ProductItem $productItem

  if ([string]::IsNullOrWhiteSpace($product)) {
    $productItemJson = Convert-ToCellValue -Value $productItem
    if ($productItemJson.Length -gt 240) {
      $productItemJson = $productItemJson.Substring(0, 240) + "..."
    }
    Write-Warning ("[{0}/{1}] Produit ignore (nom vide). Item brut: {2}" -f $currentProduct, $totalProducts, $productItemJson)
    continue
  }

  Write-Progress -Activity "Export EndOfLife API" -Status ("Produit {0}/{1}: {2}" -f $currentProduct, $totalProducts, $product) -PercentComplete (($currentProduct / $totalProducts) * 100)
  Write-Host ("[{0}/{1}] [INFO] Extraction des releases pour '{2}'..." -f $currentProduct, $totalProducts, $product)

  try {
    $productPayload = Get-ProductPayload -ApiBaseUrl $ApiBaseUrl -Product $product -ProductUri $productUri
  }
  catch {
    $details = Get-ErrorDetails -Exception $_
    $message = ("[{0}/{1}] [ERROR] Echec pour '{2}': {3}" -f $currentProduct, $totalProducts, $product, $details)
    Write-Error $message
    $errors.Add($message) | Out-Null
    continue
  }

  $releases = Get-ReleaseObjects -Payload $productPayload
  $releasesCount = Get-CollectionCount -Value $releases
  Write-Host ("[{0}/{1}] [OK] {2}: {3} release(s) recuperee(s)." -f $currentProduct, $totalProducts, $product, $releasesCount)

  $idx = 0
  foreach ($release in $releases) {
    $idx++

    $line = [ordered]@{
      product       = $product
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

if ($rows.Count -gt 0) {
  $csvLines = $rows |
    Select-Object -Property $finalColumns |
    ConvertTo-Csv -NoTypeInformation
  [System.IO.File]::WriteAllLines(
    $OutputCsv,
    $csvLines,
    [System.Text.UTF8Encoding]::new($true)
  )
}
else {
  [System.IO.File]::WriteAllText(
    $OutputCsv,
    (($finalColumns -join ",") + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($true)
  )
}

if ($errors.Count -gt 0) {
  Write-Warning ("Export termine avec {0} erreur(s) produit. Consultez les messages [ERROR] ci-dessus." -f $errors.Count)
}
else {
  Write-Host "[INFO] Export termine sans erreur produit."
}

Write-Host "Export termine: $OutputCsv ($($rows.Count) lignes)."
