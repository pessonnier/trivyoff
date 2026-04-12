@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ==========================================================
rem  Trivy scan wrapper - v1.3.2
rem
rem  Documentation des fonctionnalites
rem  ---------------------------------
rem  1) Objectif
rem     - Lance des analyses Trivy en mode offline et produit:
rem       * CycloneDX JSON
rem       * JSON detaille
rem       * TABLE texte
rem       * CSV d'historique des patchs Windows (PowerShell)
rem     - Regroupe les sorties dans une archive ZIP (1 ZIP par cible scannee).
rem
rem  2) Parametres supportes
rem     -p, --projet <nom>    : nom de projet pour le prefixe des fichiers.
rem     -m, --mode <mode>     : mode Trivy (rootfs/fs/k8s/image...).
rem     -c, --chemin <path>   : chemin a scanner explicitement.
rem                              Quand ce parametre est defini:
rem                              * SCAN_PATH est force sur ce chemin
rem                              * la detection et la boucle sur les lecteurs
rem                                locaux (DRIVES) sont ignorees.
rem     Tous les autres arguments sont retransmis a Trivy.
rem
rem  3) Comportement de scan
rem     - Sans -c/--chemin: detection des disques locaux (DriveType=3),
rem       puis scan disque par disque.
rem     - Avec -c/--chemin: un seul scan est execute sur le chemin fourni.
rem
rem  4) Notes Windows
rem     - Pour le mode rootfs, la commande Trivy utilise "filesystem".
rem     - Pour un scan de lecteur (ex: C:), le chemin est force en "C:\."
rem       pour eviter les problemes de parsing de chemin.
rem ==========================================================

chcp 65001 >nul
set "VERSION=1.3.2"

rem --- Timestamp (YYYYMMDD_HHMMSS) sans espaces
set "LDT="
for /f %%i in ('wmic os get LocalDateTime ^| find "."') do set "LDT=%%i"
set "DT=%LDT:~0,8%_%LDT:~8,6%"

rem --- Hostname
for /f "delims=" %%i in ('hostname') do set "HN=%%i"

rem --- Defaults
set "PROJECT_NAME=sansnom"
set "SCAN_MODE=rootfs"
set "CUSTOM_SCAN_PATH="
set "PARAM="

rem --- Script directory (ends with backslash)
set "TRIVY_DIR=%~dp0"
set "CACHE_DIR=%TRIVY_DIR%cache"

rem ==========================================================
rem  Args parsing
rem ==========================================================
:loop
if "%~1"=="" goto afterargs

if /I "%~1"=="-p" ( set "PROJECT_NAME=%~2" & shift & shift & goto loop )
if /I "%~1"=="--projet" ( set "PROJECT_NAME=%~2" & shift & shift & goto loop )

if /I "%~1"=="-m" ( set "SCAN_MODE=%~2" & shift & shift & goto loop )
if /I "%~1"=="--mode" ( set "SCAN_MODE=%~2" & shift & shift & goto loop )
if /I "%~1"=="-c" ( set "CUSTOM_SCAN_PATH=%~2" & shift & shift & goto loop )
if /I "%~1"=="--chemin" ( set "CUSTOM_SCAN_PATH=%~2" & shift & shift & goto loop )

rem Forward any other args to Trivy
set "PARAM=!PARAM! %~1"
shift
goto loop

:afterargs

rem ==========================================================
rem  Mode-dependent options
rem ==========================================================
set "SCANNERS=--scanners license"
set "SCANNERS_TABLE=--scanners misconfig,license"
set "IMAGE_CONFIG_SCANNERS="
set "SRC="

if /I "%SCAN_MODE%"=="fs" (
  set "SCANNERS=--scanners misconfig,secret,license"
  set "SCANNERS_TABLE=--scanners misconfig,secret,license"
  set "SRC=_src"
)

if /I "%SCAN_MODE%"=="k8s" (
  set "SCANNERS=--scanners misconfig,license"
  set "SCANNERS_TABLE=--scanners misconfig,license"
  set "SRC=_k8s"
)

if /I "%SCAN_MODE%"=="image" (
  set "SCANNERS=--scanners license"
  set "SCANNERS_TABLE=--scanners misconfig,license"
  set "IMAGE_CONFIG_SCANNERS=--image-config-scanners misconfig"
  set "SRC=_image"
)

set "TRIVY_CMD=%SCAN_MODE%"

rem ==========================================================
rem  Prepare cache dir
rem ==========================================================
if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%" >nul 2>&1

rem ==========================================================
rem  Global log (résumé)
rem ==========================================================
set "GLOBAL_LOG=%PROJECT_NAME%.%DT%.%HN%.trivy_scan.global.log"

>>"%GLOBAL_LOG%" echo ==========================================================
>>"%GLOBAL_LOG%" echo Trivy wrapper version %VERSION%
>>"%GLOBAL_LOG%" echo DateTime=%DT% Host=%HN%
>>"%GLOBAL_LOG%" echo TRIVY_DIR=%TRIVY_DIR%
>>"%GLOBAL_LOG%" echo CACHE_DIR=%CACHE_DIR%
>>"%GLOBAL_LOG%" echo SCAN_MODE=%SCAN_MODE%  TRIVY_CMD=%TRIVY_CMD%
>>"%GLOBAL_LOG%" echo PARAM=%PARAM%
>>"%GLOBAL_LOG%" echo ==========================================================

echo Trivy wrapper version %VERSION%
echo DateTime=%DT% Host=%HN%
echo TRIVY_DIR=[%TRIVY_DIR%]
echo CACHE_DIR=[%CACHE_DIR%]
echo SCAN_MODE=[%SCAN_MODE%]
echo CUSTOM_SCAN_PATH=[%CUSTOM_SCAN_PATH%]
echo PARAM=[%PARAM%]

rem ==========================================================
rem  Si un chemin explicite est fourni, on ne boucle pas sur DRIVES
rem ==========================================================
rem TODO : une erreur se déclanche qui parle de "set" mais qui semble venir du if car le message DEBUG1 s'affiche mais pas DEBUG2 comment expliquer ce phenomene ?
echo DEBUG1
if defined CUSTOM_SCAN_PATH (
  echo DEBUG2
  set "SCAN_PATH=%CUSTOM_SCAN_PATH%"
  set "SCAN_LABEL=CUSTOM"
  if /I "%SCAN_PATH:~1,1%"==":" set "SCAN_LABEL=%SCAN_PATH:~0,1%"
  echo Scan cible unique force par -c/--chemin : [%SCAN_PATH%]
  >>"%GLOBAL_LOG%" echo Scan cible unique force par -c/--chemin : [%SCAN_PATH%]
  call :scan_target "%SCAN_PATH%" "%SCAN_LABEL%"
  echo.
  echo Operation terminee. Voir %GLOBAL_LOG% et le ZIP genere.
  >>"%GLOBAL_LOG%" echo Operation terminee.
  goto :eof
)

rem ==========================================================
rem  Detect local disks (DriveType=3) -> exclude network
rem ==========================================================
set "DRIVES="
for /f "tokens=1" %%A in ('wmic logicaldisk where "DriveType=3" get DeviceID ^| find ":"') do (
  set "DRIVES=!DRIVES! %%A"
)

if not defined DRIVES (
  echo Aucun disque local ^(DriveType=3^) detecte.
  >>"%GLOBAL_LOG%" echo Aucun disque local ^(DriveType=3^) detecte.
  goto :eof
)

echo Disques detectes ^(locaux^) : %DRIVES%
>>"%GLOBAL_LOG%" echo Disques detectes ^(locaux^) : %DRIVES%

rem ==========================================================
rem  Loop disks
rem ==========================================================
for %%D in (%DRIVES%) do (
  call :scan_target "%%D\." "%%D"
)

echo.
echo Operation terminee. Voir %GLOBAL_LOG% et les ZIP par disque.
>>"%GLOBAL_LOG%" echo Operation terminee.
goto :eof


rem ==========================================================
rem  Scan a target path
rem   %1 = scan path (ex: C:\. ou D:\data)
rem   %2 = label pour fichiers (ex: C, D, CUSTOM)
rem ==========================================================
:scan_target
setlocal EnableDelayedExpansion

set "SCAN_PATH=%~1"
set "TARGET_LABEL=%~2"
if not defined TARGET_LABEL set "TARGET_LABEL=SCAN"
set "TARGET_LABEL=!TARGET_LABEL::=!"
set "TARGET_LABEL=!TARGET_LABEL:\=!"
set "TARGET_LABEL=!TARGET_LABEL:.=!"

set "LOGFILE=%PROJECT_NAME%.%DT%.%HN%.!TARGET_LABEL!.trivy_scan.log"
set "FILEPREFIX=%PROJECT_NAME%_%HN%.%DT%.%SCAN_MODE%.!TARGET_LABEL!"
set "ARCHIVE_NAME=%PROJECT_NAME%%SRC%_%DT%_%HN%_!TARGET_LABEL!.zip"
set "PATCHFILE=!FILEPREFIX!.patch.csv"

echo.
echo --- Cible !TARGET_LABEL! ---
echo SCAN_PATH=[!SCAN_PATH!]
echo LOGFILE=[!LOGFILE!]
echo FILEPREFIX=[!FILEPREFIX!]
echo ARCHIVE_NAME=[!ARCHIVE_NAME!]
echo PATCHFILE=[!PATCHFILE!]

>>"%GLOBAL_LOG%" echo --- Cible !TARGET_LABEL! --- LOG=!LOGFILE! ZIP=!ARCHIVE_NAME!

>>"!LOGFILE!" echo ==========================================================
>>"!LOGFILE!" echo Debut analyse Trivy cible=!TARGET_LABEL! path="!SCAN_PATH!" a %TIME%
>>"!LOGFILE!" echo Version wrapper=%VERSION% scan_mode=%SCAN_MODE% trivy_cmd=%TRIVY_CMD%
>>"!LOGFILE!" echo TRIVY_DIR=!TRIVY_DIR!
>>"!LOGFILE!" echo CACHE_DIR=!CACHE_DIR!
>>"!LOGFILE!" echo FILEPREFIX=!FILEPREFIX!
>>"!LOGFILE!" echo PARAM=!PARAM!
>>"!LOGFILE!" echo ==========================================================

set "COMMON=--skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 30m --cache-dir "!CACHE_DIR!" --skip-files "!TRIVY_DIR!trivy.exe" --skip-files "!TRIVY_DIR!trivy""
set "SKIP="
if /I "!SCAN_PATH:~1,2!"==":\" (
  set "DRIVE_ROOT=!SCAN_PATH:~0,2!"
  set "SKIP=--skip-dirs "!DRIVE_ROOT!\System Volume Information" --skip-dirs "!DRIVE_ROOT!\$Recycle.Bin" --skip-dirs "!DRIVE_ROOT!\Recovery""
)

rem 1) CycloneDX
>>"!LOGFILE!" echo ---- TRIVY CycloneDX ----
>>"!LOGFILE!" echo CMD="!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! --format cyclonedx --output "!FILEPREFIX!.cyclonedx.json" "!SCAN_PATH!"

"!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! ^
  --format cyclonedx --output "!FILEPREFIX!.cyclonedx.json" "!SCAN_PATH!" >>"!LOGFILE!" 2>&1
set "RC1=!ERRORLEVEL!"
>>"!LOGFILE!" echo RC=!RC1!

rem 2) JSON
>>"!LOGFILE!" echo ---- TRIVY JSON ----
>>"!LOGFILE!" echo CMD="!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! --list-all-pkgs --format json --output "!FILEPREFIX!.json" "!SCAN_PATH!"

"!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! ^
  --list-all-pkgs --format json --output "!FILEPREFIX!.json" "!SCAN_PATH!" >>"!LOGFILE!" 2>&1
set "RC2=!ERRORLEVEL!"
>>"!LOGFILE!" echo RC=!RC2!

rem 3) TABLE
>>"!LOGFILE!" echo ---- TRIVY TABLE ----
>>"!LOGFILE!" echo CMD="!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS_TABLE% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! --format table --dependency-tree --output "!FILEPREFIX!.config.licence.CVE.txt" "!SCAN_PATH!"

"!TRIVY_DIR!trivy.exe" !TRIVY_CMD! !COMMON! %SCANNERS_TABLE% %IMAGE_CONFIG_SCANNERS% !SKIP! !PARAM! ^
  --format table --output "!FILEPREFIX!.config.licence.CVE.txt" "!SCAN_PATH!" >>"!LOGFILE!" 2>&1
set "RC3=!ERRORLEVEL!"
>>"!LOGFILE!" echo RC=!RC3!

rem 4) Patch CSV export
>>"!LOGFILE!" echo ---- WINDOWS PATCH CSV ----
if /I "!SCAN_PATH:~1,2!"==":\" (
  >>"!LOGFILE!" echo CMD=powershell -NoProfile -ExecutionPolicy Bypass -File "!TRIVY_DIR!export_windows_patch_history.ps1" "!PATCHFILE!" "%HN%" "%DT%" "%SCAN_MODE%" "!SCAN_PATH:~0,2!"
  powershell -NoProfile -ExecutionPolicy Bypass -File "!TRIVY_DIR!export_windows_patch_history.ps1" "!PATCHFILE!" "%HN%" "%DT%" "%SCAN_MODE%" "!SCAN_PATH:~0,2!" >>"!LOGFILE!" 2>&1
  set "RC4=!ERRORLEVEL!"
  >>"!LOGFILE!" echo PATCH_RC=!RC4!
  if not "!RC4!"=="0" (
    >"!PATCHFILE!" echo export_status,error_message
    >>"!PATCHFILE!" echo failed,"Patch CSV export failed. See !LOGFILE! for details."
  )
) else (
  >"!PATCHFILE!" echo export_status,error_message
  >>"!PATCHFILE!" echo skipped,"Patch CSV export requires a local drive target (ex: C:\)."
  >>"!LOGFILE!" echo PATCH_RC=0 ^(skipped: non-drive target^)
)

rem Check outputs
set "OUT_OK=0"
if exist "!FILEPREFIX!.cyclonedx.json" set "OUT_OK=1"
if exist "!FILEPREFIX!.json" set "OUT_OK=1"
if exist "!FILEPREFIX!.config.licence.CVE.txt" set "OUT_OK=1"

if "!OUT_OK!"=="0" (
  >>"!LOGFILE!" echo Aucun fichier de sortie Trivy genere -> ZIP non cree
  >>"%GLOBAL_LOG%" echo !TARGET_LABEL! : aucun output => pas de ZIP
  endlocal & exit /b 0
)

rem ZIP
if exist "C:\Program Files\7-Zip\7z.exe" (
  "C:\Program Files\7-Zip\7z.exe" a -tzip "!ARCHIVE_NAME!" ^
    "!FILEPREFIX!.cyclonedx.json" ^
    "!FILEPREFIX!.json" ^
    "!FILEPREFIX!.config.licence.CVE.txt" ^
    "!PATCHFILE!" >>"!LOGFILE!" 2>&1

  set "ZRC=!ERRORLEVEL!"
  >>"!LOGFILE!" echo ZIP_RC=!ZRC!

  if "!ZRC!"=="0" (
    "C:\Program Files\7-Zip\7z.exe" a -tzip "!ARCHIVE_NAME!" "!LOGFILE!" >nul 2>&1
    >>"%GLOBAL_LOG%" echo !TARGET_LABEL! : ZIP OK => !ARCHIVE_NAME!
  ) else (
    >>"%GLOBAL_LOG%" echo !TARGET_LABEL! : erreur ZIP code=!ZRC!
  )
) else (
  >>"!LOGFILE!" echo 7-Zip non trouve -> ZIP non cree
  >>"%GLOBAL_LOG%" echo !TARGET_LABEL! : 7z absent => pas de ZIP
)

endlocal & exit /b 0
