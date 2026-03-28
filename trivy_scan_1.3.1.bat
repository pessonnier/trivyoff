@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ==========================================================
rem  Trivy scan wrapper - v1.3.1 (multi-disques, 1 zip / disque)
rem  NOTE Windows: on utilise "filesystem" (pas "rootfs") pour scanner C:\ etc.
rem ==========================================================

chcp 65001 >nul
set "VERSION=1.3.1"

rem --- Timestamp (YYYYMMDD_HHMMSS) sans espaces
set "LDT="
for /f %%i in ('wmic os get LocalDateTime ^| find "."') do set "LDT=%%i"
set "DT=%LDT:~0,8%_%LDT:~8,6%"

rem --- Hostname
for /f "delims=" %%i in ('hostname') do set "HN=%%i"

rem --- Defaults
set "PROJECT_NAME=sansnom"
set "SCAN_MODE=rootfs"
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

rem ==========================================================
rem  IMPORTANT Windows: rootfs => on scanne en "filesystem"
rem ==========================================================
set "TRIVY_CMD=%SCAN_MODE%"
if /I "%SCAN_MODE%"=="rootfs" set "TRIVY_CMD=filesystem"

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
echo PARAM=[%PARAM%]

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
  call :scan_disk %%D
)

echo.
echo Operation terminee. Voir %GLOBAL_LOG% et les ZIP par disque.
>>"%GLOBAL_LOG%" echo Operation terminee.
goto :eof


rem ==========================================================
rem  Scan a disk
rem   %1 = drive like C:
rem ==========================================================
:scan_disk
setlocal EnableDelayedExpansion

set "DRIVE=%~1"
set "DRIVE_LETTER=!DRIVE:~0,1!"

rem !!! FIX WINDOWS: ne pas passer "C:\" -> utiliser "C:\." pour éviter C:" !!!
set "SCAN_PATH=!DRIVE!\."

set "LOGFILE=%PROJECT_NAME%.%DT%.%HN%.!DRIVE_LETTER!.trivy_scan.log"
set "FILEPREFIX=%PROJECT_NAME%_%HN%.%DT%.%SCAN_MODE%.!DRIVE_LETTER!"
set "ARCHIVE_NAME=%PROJECT_NAME%%SRC%_%DT%_%HN%_!DRIVE_LETTER!.zip"
set "PATCHFILE=!FILEPREFIX!.patch.csv"

echo.
echo --- Disque !DRIVE! ---
echo SCAN_PATH=[!SCAN_PATH!]
echo LOGFILE=[!LOGFILE!]
echo FILEPREFIX=[!FILEPREFIX!]
echo ARCHIVE_NAME=[!ARCHIVE_NAME!]
echo PATCHFILE=[!PATCHFILE!]

>>"%GLOBAL_LOG%" echo --- Disque !DRIVE! --- LOG=!LOGFILE! ZIP=!ARCHIVE_NAME!

>>"!LOGFILE!" echo ==========================================================
>>"!LOGFILE!" echo Debut analyse Trivy disque=!DRIVE! path="!SCAN_PATH!" a %TIME%
>>"!LOGFILE!" echo Version wrapper=%VERSION% scan_mode=%SCAN_MODE% trivy_cmd=%TRIVY_CMD%
>>"!LOGFILE!" echo TRIVY_DIR=!TRIVY_DIR!
>>"!LOGFILE!" echo CACHE_DIR=!CACHE_DIR!
>>"!LOGFILE!" echo FILEPREFIX=!FILEPREFIX!
>>"!LOGFILE!" echo PARAM=!PARAM!
>>"!LOGFILE!" echo ==========================================================

set "COMMON=--skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 30m --cache-dir "!CACHE_DIR!" --skip-files "!TRIVY_DIR!trivy.exe" --skip-files "!TRIVY_DIR!trivy""
set "SKIP=--skip-dirs "!DRIVE!\System Volume Information" --skip-dirs "!DRIVE!\$Recycle.Bin" --skip-dirs "!DRIVE!\Recovery""

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
>>"!LOGFILE!" echo CMD=powershell -NoProfile -ExecutionPolicy Bypass -File "!TRIVY_DIR!export_windows_patch_history.ps1" "!PATCHFILE!" "%HN%" "%DT%" "%SCAN_MODE%" "!DRIVE!"
powershell -NoProfile -ExecutionPolicy Bypass -File "!TRIVY_DIR!export_windows_patch_history.ps1" "!PATCHFILE!" "%HN%" "%DT%" "%SCAN_MODE%" "!DRIVE!" >>"!LOGFILE!" 2>&1
set "RC4=!ERRORLEVEL!"
>>"!LOGFILE!" echo PATCH_RC=!RC4!
if not "!RC4!"=="0" (
  >"!PATCHFILE!" echo export_status,error_message
  >>"!PATCHFILE!" echo failed,"Patch CSV export failed. See !LOGFILE! for details."
)

rem Check outputs
set "OUT_OK=0"
if exist "!FILEPREFIX!.cyclonedx.json" set "OUT_OK=1"
if exist "!FILEPREFIX!.json" set "OUT_OK=1"
if exist "!FILEPREFIX!.config.licence.CVE.txt" set "OUT_OK=1"

if "!OUT_OK!"=="0" (
  >>"!LOGFILE!" echo Aucun fichier de sortie Trivy genere -> ZIP non cree
  >>"%GLOBAL_LOG%" echo !DRIVE! : aucun output => pas de ZIP
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
    >>"%GLOBAL_LOG%" echo !DRIVE! : ZIP OK => !ARCHIVE_NAME!
  ) else (
    >>"%GLOBAL_LOG%" echo !DRIVE! : erreur ZIP code=!ZRC!
  )
) else (
  >>"!LOGFILE!" echo 7-Zip non trouve -> ZIP non cree
  >>"%GLOBAL_LOG%" echo !DRIVE! : 7z absent => pas de ZIP
)

endlocal & exit /b 0
