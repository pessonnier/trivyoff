@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ==========================================================
rem  Windows installed products export - v1.0.0
rem
rem  Liste les logiciels installes a partir des cles Uninstall
rem  du registre Windows (HKLM 64 bits, HKLM WOW6432Node, HKCU)
rem  et exporte le resultat en CSV UTF-8.
rem
rem  Usage:
rem    list_installed_products.bat
rem    list_installed_products.bat -o "C:\Temp\produits.csv"
rem    list_installed_products.bat --no-table
rem ==========================================================

chcp 65001 >nul

set "OUTPUT_CSV="
set "SHOW_TABLE=1"
set "STDOUT_ONLY="

:args
if "%~1"=="" goto afterargs

if /I "%~1"=="-o" (
  set "OUTPUT_CSV=%~2"
  shift
  shift
  goto args
)

if /I "%~1"=="--output" (
  set "OUTPUT_CSV=%~2"
  shift
  shift
  goto args
)

if /I "%~1"=="--no-table" (
  set "SHOW_TABLE="
  shift
  goto args
)

if /I "%~1"=="--stdout-only" (
  set "STDOUT_ONLY=1"
  shift
  goto args
)

if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help

echo Parametre inconnu : %~1
echo Utilisez --help pour l'aide.
exit /b 1

:afterargs
if defined STDOUT_ONLY goto run_export
if defined OUTPUT_CSV goto run_export

for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "[DateTime]::Now.ToString('yyyyMMdd_HHmmss')"`) do set "DT=%%i"
for /f "delims=" %%i in ('hostname') do set "HN=%%i"
set "OUTPUT_CSV=%CD%\installed_products.%HN%.%DT%.csv"

:run_export
if defined STDOUT_ONLY goto run_export_stdout
echo Export des produits installes vers:
echo   %OUTPUT_CSV%
echo.

:run_export_stdout
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$output = [Environment]::GetEnvironmentVariable('OUTPUT_CSV');" ^
  "$showTable = [Environment]::GetEnvironmentVariable('SHOW_TABLE');" ^
  "$stdoutOnly = [Environment]::GetEnvironmentVariable('STDOUT_ONLY');" ^
  "$paths = @(" ^
  "  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'," ^
  "  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'," ^
  "  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'" ^
  ");" ^
  "$items = foreach ($path in $paths) {" ^
  "  if (-not (Test-Path $path)) { continue }" ^
  "  $scope = if ($path -like 'HKCU:*') { 'CurrentUser' } elseif ($path -like '*WOW6432Node*') { 'LocalMachine32' } else { 'LocalMachine64' };" ^
  "  Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |" ^
  "    Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |" ^
  "    ForEach-Object {" ^
  "      [pscustomobject]@{" ^
  "        Name = $_.DisplayName;" ^
  "        Version = $_.DisplayVersion;" ^
  "        Publisher = $_.Publisher;" ^
  "        InstallDate = if ($_.InstallDate -match '^\d{8}$') { try { ([datetime]::ParseExact([string]$_.InstallDate, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd') } catch { $_.InstallDate } } else { $_.InstallDate };" ^
  "        InstallLocation = $_.InstallLocation;" ^
  "        RegistryScope = $scope" ^
  "      }" ^
  "    }" ^
  "};" ^
  "$items = @($items | Sort-Object Name, Version, Publisher, RegistryScope -Unique);" ^
  "$rendered = if ($items.Count -gt 0) { $items | Format-Table -Wrap -AutoSize Name, Version, Publisher, InstallDate, RegistryScope | Out-String -Width 4096 } else { '' };" ^
  "if ($stdoutOnly -eq '1') {" ^
  "  if ($items.Count -eq 0) {" ^
  "    Write-Output 'Aucun produit installe trouve dans les cles Uninstall.';" ^
  "  } else {" ^
  "    Write-Output ('Produits trouves : ' + $items.Count);" ^
  "    Write-Output '';" ^
  "    Write-Output $rendered.TrimEnd();" ^
  "  }" ^
  "} else {" ^
  "  if ($items.Count -eq 0) {" ^
  "    'Name,Version,Publisher,InstallDate,InstallLocation,RegistryScope' | Set-Content -Path $output -Encoding utf8;" ^
  "    Write-Host 'Aucun produit installe trouve dans les cles Uninstall.';" ^
  "  } else {" ^
  "    $items | Export-Csv -Path $output -NoTypeInformation -Encoding utf8;" ^
  "    Write-Host ('Produits exportes : ' + $items.Count);" ^
  "    if ($showTable -eq '1') {" ^
  "      Write-Host '';" ^
  "      Write-Host $rendered.TrimEnd();" ^
  "    }" ^
  "  }" ^
  "  Write-Host ('CSV : ' + $output);" ^
  "}"

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Echec de l'export des produits installes. Code=%RC%
  exit /b %RC%
)

exit /b 0

:help
echo.
echo Usage:
echo   %~nx0 [-o ^<fichier.csv^>] [--no-table] [--stdout-only]
echo.
echo Options:
echo   -o, --output   Chemin du CSV de sortie.
echo   --no-table     N'affiche pas le tableau dans la console.
echo   --stdout-only  N'exporte pas de CSV et affiche uniquement la liste en texte.
echo   -h, --help     Affiche cette aide.
echo.
exit /b 0
