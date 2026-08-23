@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ==========================================================
rem  Trivy scan wrapper - v1.3.5
rem
rem  Documentation des fonctionnalites
rem  ---------------------------------
rem  1) Objectif
rem     - Lance des analyses Trivy en mode offline et produit:
rem       * CycloneDX JSON
rem       * JSON detaille
rem       * TABLE texte
rem       * CSV d'historique des patchs Windows (PowerShell)
rem       * TXT des produits installes Windows (une fois par execution)
rem     - Regroupe les sorties dans une archive ZIP par cible avec 7-Zip,
rem       ou avec Compress-Archive si 7-Zip n'est pas disponible.
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
rem     - En mode rootfs, la commande Trivy est resolue par cible:
rem       * racine de disque (ex: C:\, D:\, C:\.) ou scan global => rootfs
rem       * sous-repertoire explicite => bascule en filesystem avec trace console/log
rem     - Pour un scan de lecteur (ex: C:), le chemin est force en "C:\."
rem       pour eviter les problemes de parsing de chemin.
rem ==========================================================

chcp 65001 >nul
set "VERSION=1.3.5"

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
set "PARAM=%PARAM% %~1"
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
  set "SCANNERS=--scanners misconfig,secret,license"
  set "SCANNERS_TABLE=--scanners misconfig,secret,license"
  set "SRC=_k8s"
)

if /I "%SCAN_MODE%"=="image" (
  set "SCANNERS=--scanners license"
  set "SCANNERS_TABLE=--scanners misconfig,license"
  set "IMAGE_CONFIG_SCANNERS=--image-config-scanners misconfig"
  set "SRC=_image"
)

rem ==========================================================
rem  Commande Trivy resolue par cible dans :scan_target
rem ==========================================================
set "TRIVY_CMD=auto"

set "GLOBAL_LOG=%PROJECT_NAME%.%DT%.%HN%.trivy_scan.global.log"
set "PRODUCTS_TXT=%PROJECT_NAME%_%HN%.%DT%.installed_products.txt"

rem ==========================================================
rem  Le cache offline doit avoir ete prepare avant le scan
rem ==========================================================
if not exist "%CACHE_DIR%\" (
  echo ERREUR : le dossier de cache Trivy est introuvable : "%CACHE_DIR%"
  >>"%GLOBAL_LOG%" echo ERREUR : le dossier de cache Trivy est introuvable : "%CACHE_DIR%"
  exit /b 1
)

rem ==========================================================
rem  Resolution de 7-Zip : dossier du script, installations
rem  standards, puis PATH. Compress-Archive sert de secours.
rem ==========================================================
set "SEVENZIP_CMD="
if exist "%TRIVY_DIR%7z.exe" set "SEVENZIP_CMD=%TRIVY_DIR%7z.exe"
if not defined SEVENZIP_CMD if exist "%TRIVY_DIR%7zz.exe" set "SEVENZIP_CMD=%TRIVY_DIR%7zz.exe"
if not defined SEVENZIP_CMD if exist "%TRIVY_DIR%7za.exe" set "SEVENZIP_CMD=%TRIVY_DIR%7za.exe"
if not defined SEVENZIP_CMD if exist "%ProgramFiles%\7-Zip\7z.exe" set "SEVENZIP_CMD=%ProgramFiles%\7-Zip\7z.exe"
if not defined SEVENZIP_CMD if exist "%ProgramFiles(x86)%\7-Zip\7z.exe" set "SEVENZIP_CMD=%ProgramFiles(x86)%\7-Zip\7z.exe"
if not defined SEVENZIP_CMD for /f "delims=" %%I in ('where 7z.exe 2^>nul') do if not defined SEVENZIP_CMD set "SEVENZIP_CMD=%%~fI"
if not defined SEVENZIP_CMD for /f "delims=" %%I in ('where 7zz.exe 2^>nul') do if not defined SEVENZIP_CMD set "SEVENZIP_CMD=%%~fI"
if not defined SEVENZIP_CMD for /f "delims=" %%I in ('where 7za.exe 2^>nul') do if not defined SEVENZIP_CMD set "SEVENZIP_CMD=%%~fI"

if defined SEVENZIP_CMD (
  set "ARCHIVE_METHOD=7-Zip [%SEVENZIP_CMD%]"
) else (
  set "ARCHIVE_METHOD=PowerShell Compress-Archive"
)

rem ==========================================================
rem  Global log (résumé)
rem ==========================================================
>>"%GLOBAL_LOG%" echo ==========================================================
>>"%GLOBAL_LOG%" echo Trivy wrapper version %VERSION%
>>"%GLOBAL_LOG%" echo DateTime=%DT% Host=%HN%
>>"%GLOBAL_LOG%" echo TRIVY_DIR=%TRIVY_DIR%
>>"%GLOBAL_LOG%" echo CACHE_DIR=%CACHE_DIR%
>>"%GLOBAL_LOG%" echo ARCHIVE_METHOD=%ARCHIVE_METHOD%
>>"%GLOBAL_LOG%" echo PRODUCTS_TXT=%PRODUCTS_TXT%
>>"%GLOBAL_LOG%" echo SCAN_MODE=%SCAN_MODE%  TRIVY_CMD=%TRIVY_CMD% ^(resolved per target^)
>>"%GLOBAL_LOG%" echo PARAM=%PARAM%
>>"%GLOBAL_LOG%" echo ==========================================================

echo Trivy wrapper version %VERSION%
echo DateTime=%DT% Host=%HN%
echo TRIVY_DIR=[%TRIVY_DIR%]
echo CACHE_DIR=[%CACHE_DIR%]
echo SCAN_MODE=[%SCAN_MODE%]
echo ARCHIVE_METHOD=[%ARCHIVE_METHOD%]
echo PRODUCTS_TXT=[%PRODUCTS_TXT%]
echo CUSTOM_SCAN_PATH=[%CUSTOM_SCAN_PATH%]
echo PARAM=[%PARAM%]

call :export_installed_products

rem ==========================================================
rem  Si un chemin explicite est fourni, on ne boucle pas sur DRIVES
rem ==========================================================
if defined CUSTOM_SCAN_PATH goto custom_scan

rem ==========================================================
rem  Detect local disks (DriveType=3) -> exclude network
rem ==========================================================
set "DRIVES="
for /f "tokens=1" %%A in ('wmic logicaldisk where "DriveType=3" get DeviceID ^| find ":"') do (
  call set "DRIVES=%%DRIVES%% %%A"
)

if not defined DRIVES goto no_drives

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
call :refresh_global_log_in_archives
goto :eof

:custom_scan
set "SCAN_PATH=%CUSTOM_SCAN_PATH%"
set "SCAN_LABEL=CUSTOM"
if /I "%SCAN_PATH:~1,1%"==":" set "SCAN_LABEL=%SCAN_PATH:~0,1%"
echo Scan cible unique force par -c/--chemin : [%SCAN_PATH%]
>>"%GLOBAL_LOG%" echo Scan cible unique force par -c/--chemin : [%SCAN_PATH%]
call :scan_target "%SCAN_PATH%" "%SCAN_LABEL%"
echo.
echo Operation terminee. Voir %GLOBAL_LOG% et le ZIP genere.
>>"%GLOBAL_LOG%" echo Operation terminee.
call :refresh_global_log_in_archives
goto :eof

:no_drives
echo Aucun disque local ^(DriveType=3^) detecte.
>>"%GLOBAL_LOG%" echo Aucun disque local ^(DriveType=3^) detecte.
goto :eof


rem ==========================================================
rem  Scan a target path
rem   %1 = scan path (ex: C:\. ou D:\data)
rem   %2 = label pour fichiers (ex: C, D, CUSTOM)
rem ==========================================================
:scan_target
setlocal DisableDelayedExpansion

set "SCAN_PATH=%~1"
set "TARGET_LABEL=%~2"
if not defined TARGET_LABEL set "TARGET_LABEL=SCAN"
set "TARGET_LABEL=%TARGET_LABEL::=%"
set "TARGET_LABEL=%TARGET_LABEL:\=%"
set "TARGET_LABEL=%TARGET_LABEL:.=%"

set "LOGFILE=%PROJECT_NAME%.%DT%.%HN%.%TARGET_LABEL%.trivy_scan.log"
set "FILEPREFIX=%PROJECT_NAME%_%HN%.%DT%.%SCAN_MODE%.%TARGET_LABEL%"
set "ARCHIVE_NAME=%PROJECT_NAME%%SRC%_%DT%_%HN%_%TARGET_LABEL%.zip"
set "PATCHFILE=%FILEPREFIX%.patch.csv"
call :resolve_trivy_cmd "%SCAN_MODE%" "%SCAN_PATH%"

echo.
echo --- Cible %TARGET_LABEL% ---
echo SCAN_PATH=[%SCAN_PATH%]
echo TRIVY_CMD=[%TRIVY_CMD%]
echo LOGFILE=[%LOGFILE%]
echo FILEPREFIX=[%FILEPREFIX%]
echo ARCHIVE_NAME=[%ARCHIVE_NAME%]
echo PATCHFILE=[%PATCHFILE%]
echo PRODUCTS_TXT=[%PRODUCTS_TXT%]
if defined TRIVY_SWITCH_MSG echo %TRIVY_SWITCH_MSG%

>>"%GLOBAL_LOG%" echo --- Cible %TARGET_LABEL% --- LOG=%LOGFILE% ZIP=%ARCHIVE_NAME%
if defined TRIVY_SWITCH_MSG >>"%GLOBAL_LOG%" echo %TARGET_LABEL% : %TRIVY_SWITCH_MSG%

>>"%LOGFILE%" echo ==========================================================
>>"%LOGFILE%" echo Debut analyse Trivy cible=%TARGET_LABEL% path="%SCAN_PATH%" a %TIME%
>>"%LOGFILE%" echo Version wrapper=%VERSION% scan_mode=%SCAN_MODE% trivy_cmd=%TRIVY_CMD%
>>"%LOGFILE%" echo TRIVY_DIR=%TRIVY_DIR%
>>"%LOGFILE%" echo CACHE_DIR=%CACHE_DIR%
>>"%LOGFILE%" echo FILEPREFIX=%FILEPREFIX%
>>"%LOGFILE%" echo PARAM=%PARAM%
if defined TRIVY_SWITCH_MSG >>"%LOGFILE%" echo %TRIVY_SWITCH_MSG%
>>"%LOGFILE%" echo ==========================================================

set "COMMON=--skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 30m --cache-dir "%CACHE_DIR%" --skip-files "%TRIVY_DIR%trivy.exe" --skip-files "%TRIVY_DIR%trivy""
set "SKIP="
if /I "%SCAN_PATH:~1,2%"==":\" goto scan_target_drive_skip
goto scan_target_after_skip

:scan_target_drive_skip
set "DRIVE_ROOT=%SCAN_PATH:~0,2%"
set "SKIP=--skip-dirs "%DRIVE_ROOT%\Windows" --skip-dirs "%DRIVE_ROOT%\System Volume Information" --skip-dirs "%DRIVE_ROOT%\$Recycle.Bin" --skip-dirs "%DRIVE_ROOT%\Recovery""

:scan_target_after_skip

rem 1) CycloneDX
>>"%LOGFILE%" echo ---- TRIVY CycloneDX ----
>>"%LOGFILE%" echo CMD="%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% --format cyclonedx --output "%FILEPREFIX%.cyclonedx.json" "%SCAN_PATH%"

"%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% ^
  --format cyclonedx --output "%FILEPREFIX%.cyclonedx.json" "%SCAN_PATH%" >>"%LOGFILE%" 2>&1
set "RC1=%ERRORLEVEL%"
>>"%LOGFILE%" echo RC=%RC1%

rem 2) JSON
>>"%LOGFILE%" echo ---- TRIVY JSON ----
>>"%LOGFILE%" echo CMD="%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% --list-all-pkgs --format json --output "%FILEPREFIX%.json" "%SCAN_PATH%"

"%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% ^
  --list-all-pkgs --format json --output "%FILEPREFIX%.json" "%SCAN_PATH%" >>"%LOGFILE%" 2>&1
set "RC2=%ERRORLEVEL%"
>>"%LOGFILE%" echo RC=%RC2%

rem 3) TABLE
>>"%LOGFILE%" echo ---- TRIVY TABLE ----
>>"%LOGFILE%" echo CMD="%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS_TABLE% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% --format table --dependency-tree --output "%FILEPREFIX%.config.licence.CVE.txt" "%SCAN_PATH%"

"%TRIVY_DIR%trivy.exe" %TRIVY_CMD% %COMMON% %SCANNERS_TABLE% %IMAGE_CONFIG_SCANNERS% %SKIP% %PARAM% ^
  --format table --dependency-tree --output "%FILEPREFIX%.config.licence.CVE.txt" "%SCAN_PATH%" >>"%LOGFILE%" 2>&1
set "RC3=%ERRORLEVEL%"
>>"%LOGFILE%" echo RC=%RC3%

rem 4) Patch CSV export
>>"%LOGFILE%" echo ---- WINDOWS PATCH CSV ----
if /I "%SCAN_PATH:~1,2%"==":\" goto scan_target_patch_drive
>"%PATCHFILE%" echo export_status,error_message
>>"%PATCHFILE%" echo skipped,"Patch CSV export requires a local drive target (ex: C:\)."
>>"%LOGFILE%" echo PATCH_RC=0 ^(skipped: non-drive target^)
goto scan_target_after_patch

:scan_target_patch_drive
>>"%LOGFILE%" echo CMD=powershell -NoProfile -ExecutionPolicy Bypass -File "%TRIVY_DIR%export_windows_patch_history.ps1" "%PATCHFILE%" "%HN%" "%DT%" "%SCAN_MODE%" "%SCAN_PATH:~0,2%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TRIVY_DIR%export_windows_patch_history.ps1" "%PATCHFILE%" "%HN%" "%DT%" "%SCAN_MODE%" "%SCAN_PATH:~0,2%" >>"%LOGFILE%" 2>&1
set "RC4=%ERRORLEVEL%"
>>"%LOGFILE%" echo PATCH_RC=%RC4%
if "%RC4%"=="0" goto scan_target_after_patch
>"%PATCHFILE%" echo export_status,error_message
>>"%PATCHFILE%" echo failed,"Patch CSV export failed. See %LOGFILE% for details."

:scan_target_after_patch

rem Check outputs
set "OUT_OK=0"
if exist "%FILEPREFIX%.cyclonedx.json" set "OUT_OK=1"
if exist "%FILEPREFIX%.json" set "OUT_OK=1"
if exist "%FILEPREFIX%.config.licence.CVE.txt" set "OUT_OK=1"

if not "%OUT_OK%"=="0" goto scan_target_zip
>>"%LOGFILE%" echo Aucun fichier de sortie Trivy genere -> ZIP non cree
>>"%GLOBAL_LOG%" echo %TARGET_LABEL% : aucun output => pas de ZIP
endlocal & exit /b 0

rem ZIP
:scan_target_zip
set "ARCHIVE_FILE_CDX=%FILEPREFIX%.cyclonedx.json"
set "ARCHIVE_FILE_JSON=%FILEPREFIX%.json"
set "ARCHIVE_FILE_TABLE=%FILEPREFIX%.config.licence.CVE.txt"
set "ARCHIVE_FILE_PATCH=%PATCHFILE%"
set "ARCHIVE_FILE_PRODUCTS=%PRODUCTS_TXT%"
set "ARCHIVE_FILE_TARGET_LOG=%LOGFILE%"
set "ARCHIVE_FILE_GLOBAL_LOG=%GLOBAL_LOG%"
set "ARCHIVE_OUTPUT=%ARCHIVE_NAME%"

if defined SEVENZIP_CMD goto scan_target_zip_7zip

rem Secours natif Windows
powershell -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { $files = @($env:ARCHIVE_FILE_CDX, $env:ARCHIVE_FILE_JSON, $env:ARCHIVE_FILE_TABLE, $env:ARCHIVE_FILE_PATCH, $env:ARCHIVE_FILE_PRODUCTS, $env:ARCHIVE_FILE_TARGET_LOG, $env:ARCHIVE_FILE_GLOBAL_LOG); $existing = @($files | Where-Object { $_ -and (Test-Path -LiteralPath $_) }); Compress-Archive -LiteralPath $existing -DestinationPath $env:ARCHIVE_OUTPUT -Force; exit 0 } catch { exit 1 }" >nul 2>&1
set "ZRC=%ERRORLEVEL%"
goto scan_target_zip_result

:scan_target_zip_7zip
set "ZRC=0"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_CDX%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_JSON%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_TABLE%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_PATCH%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_PRODUCTS%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_TARGET_LOG%"
if errorlevel 1 set "ZRC=1"
call :archive_add_7zip "%ARCHIVE_NAME%" "%ARCHIVE_FILE_GLOBAL_LOG%"
if errorlevel 1 set "ZRC=1"

:scan_target_zip_result
>>"%LOGFILE%" echo ZIP_RC=%ZRC% METHOD=%ARCHIVE_METHOD%
if not "%ZRC%"=="0" goto scan_target_zip_error
>>"%GLOBAL_LOG%" echo %TARGET_LABEL% : ZIP OK ^(%ARCHIVE_METHOD%^) => %ARCHIVE_NAME%
endlocal & exit /b 0

:scan_target_zip_error
>>"%GLOBAL_LOG%" echo %TARGET_LABEL% : erreur ZIP code=%ZRC% methode=%ARCHIVE_METHOD%
endlocal & exit /b 0

:archive_add_7zip
if not exist "%~2" exit /b 0
"%SEVENZIP_CMD%" a -tzip "%~1" "%~2" >nul 2>&1
exit /b %ERRORLEVEL%

:export_installed_products
>>"%GLOBAL_LOG%" echo ---- WINDOWS INSTALLED PRODUCTS TXT ----
if exist "%TRIVY_DIR%list_installed_products.bat" goto export_installed_products_run
>"%PRODUCTS_TXT%" echo list_installed_products.bat not found in %TRIVY_DIR%
>>"%GLOBAL_LOG%" echo PRODUCTS_RC=0 ^(skipped: list_installed_products.bat not found^)
exit /b 0

:export_installed_products_run
>>"%GLOBAL_LOG%" echo CMD="%TRIVY_DIR%list_installed_products.bat" --stdout-only ^> "%PRODUCTS_TXT%"
call "%TRIVY_DIR%list_installed_products.bat" --stdout-only >"%PRODUCTS_TXT%" 2>>"%GLOBAL_LOG%"
set "PRODUCTS_RC=%ERRORLEVEL%"
>>"%GLOBAL_LOG%" echo PRODUCTS_RC=%PRODUCTS_RC%
if "%PRODUCTS_RC%"=="0" exit /b 0
>"%PRODUCTS_TXT%" echo Installed products export failed. See %GLOBAL_LOG% for details.
exit /b 0

:refresh_global_log_in_archives
setlocal DisableDelayedExpansion
set "REFRESH_GLOBAL_LOG=%GLOBAL_LOG%"
for %%Z in ("%PROJECT_NAME%%SRC%_%DT%_%HN%_*.zip") do (
  if exist "%%~fZ" (
    if defined SEVENZIP_CMD (
      "%SEVENZIP_CMD%" a -tzip "%%~fZ" "%GLOBAL_LOG%" >nul 2>&1
    ) else (
      set "REFRESH_ARCHIVE=%%~fZ"
      powershell -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { Compress-Archive -LiteralPath $env:REFRESH_GLOBAL_LOG -DestinationPath $env:REFRESH_ARCHIVE -Update; exit 0 } catch { exit 1 }" >nul 2>&1
    )
  )
)
endlocal & exit /b 0

:resolve_trivy_cmd
setlocal
set "RESOLVED_TRIVY_CMD=%~1"
set "RESOLVED_TRIVY_MSG="
set "RESOLVED_SCAN_PATH=%~2"

if /I "%~1"=="rootfs" (
  if /I "%RESOLVED_SCAN_PATH:~-2%"=="\." set "RESOLVED_SCAN_PATH=%RESOLVED_SCAN_PATH:~0,-1%"
  if defined RESOLVED_SCAN_PATH (
    set "IS_DRIVE_ROOT="
    if /I "%RESOLVED_SCAN_PATH:~1,2%"==":\" if "%RESOLVED_SCAN_PATH:~3,1%"=="" set "IS_DRIVE_ROOT=1"
    if not defined IS_DRIVE_ROOT (
      set "RESOLVED_TRIVY_CMD=filesystem"
      set "RESOLVED_TRIVY_MSG=INFO: cible \"%~2\" non racine de disque, bascule de rootfs vers filesystem."
    )
  )
)

endlocal & (
  set "TRIVY_CMD=%RESOLVED_TRIVY_CMD%"
  set "TRIVY_SWITCH_MSG=%RESOLVED_TRIVY_MSG%"
)
exit /b 0
