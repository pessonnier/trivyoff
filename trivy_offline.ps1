[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet("all","update-trivy","update-db","package","update-cyclonedx")]
  [string]$Command="all",
  [string]$StateDir="",
  [string]$ToolsDir="",
  [string]$CacheDir="",
  [string]$DownloadDir="",
  [string]$WorkDir="",
  [string]$ExportDir="",
  [string]$ExtraRootDir="",
  [string]$LocalArchive="",
  [string]$CycloneDxInput="",
  [string]$CycloneDxOutput="",
  [string]$OutArchive="",
  [string]$GitHubToken="",
  [string]$ChecksBundleRepository="ghcr.io/aquasecurity/trivy-checks",
  [switch]$KeepTemp
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$ProgressPreference="SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$ScriptDir=if($PSScriptRoot){$PSScriptRoot}else{Split-Path -Parent $MyInvocation.MyCommand.Path}
function Full([string]$Value,[string]$Default){
  if([string]::IsNullOrWhiteSpace($Value)){return [IO.Path]::GetFullPath($Default)}
  return [IO.Path]::GetFullPath($Value)
}
function Ensure-Dir([string]$Path){
  if(-not(Test-Path -LiteralPath $Path)){New-Item -ItemType Directory -Force -Path $Path|Out-Null}
}
function Say([string]$Text){Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date),$Text)}
function Run([string]$Exe,[string[]]$Arguments,[string]$Label){
  Say ("$Label : $Exe "+($Arguments -join " "))
  & $Exe @Arguments
  if($LASTEXITCODE -ne 0){throw "Echec de '$Label' (code $LASTEXITCODE)."}
}
function Headers{
  $h=@{"User-Agent"="trivy_offline.ps1";"Accept"="application/vnd.github+json"}
  if($GitHubToken){$h.Authorization="Bearer $GitHubToken"}
  return $h
}
function Tar{
  $c=Get-Command tar.exe -ErrorAction SilentlyContinue
  if(-not$c){$c=Get-Command tar -ErrorAction SilentlyContinue}
  if(-not$c){throw "tar.exe est requis pour les archives .tar.gz."}
  return $c.Source
}
function Create-TarPackage([string]$Source,[string]$Archive){
  $python=Get-Command python -ErrorAction SilentlyContinue;$prefix=@()
  if(-not$python){$python=Get-Command py.exe -ErrorAction SilentlyContinue;$prefix=@("-3")}
  if(-not$python){
    Say "Python absent: archive TAR.GZ ignoree; seule l'archive ZIP sera produite."
    return $false
  }
  $code="import os, sys, tarfile
source, archive = sys.argv[1:3]
def add(tf, path, arcname):
    info = tf.gettarinfo(path, arcname)
    info.mode = 0o755 if info.isdir() or arcname == 'trivy' or arcname.endswith('.sh') else 0o644
    info.uid = info.gid = 0
    info.uname = info.gname = 'root'
    if info.isfile():
        with open(path, 'rb') as stream:
            tf.addfile(info, stream)
    else:
        tf.addfile(info)
with tarfile.open(archive, 'w:gz', format=tarfile.PAX_FORMAT) as tf:
    for base, dirs, files in os.walk(source):
        dirs.sort(); files.sort()
        for name in dirs + files:
            path = os.path.join(base, name)
            arcname = os.path.relpath(path, source).replace(os.sep, '/')
            add(tf, path, arcname)"
  Run $python.Source @($prefix+@("-c",$code,$Source,$Archive)) "Creation bundle"
  return $true
}
function Create-ZipPackage([string]$Source,[string]$Archive){
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $Source,$Archive,[System.IO.Compression.CompressionLevel]::Optimal,$false
  )
}

$StateDir=Full $StateDir (Join-Path $ScriptDir "Offline")
$ToolsDir=Full $ToolsDir (Join-Path $StateDir "tools")
$CacheDir=Full $CacheDir (Join-Path $StateDir "cache")
$DownloadDir=Full $DownloadDir (Join-Path $ScriptDir "Download")
$WorkDir=Full $WorkDir (Join-Path $ScriptDir "Work")
$ExportDir=Full $ExportDir (Join-Path $ScriptDir "Export")
$ExtraRootDir=Full $ExtraRootDir (Join-Path $ScriptDir "Extra")

function Asset($Asset){
  Ensure-Dir $DownloadDir
  $dest=Join-Path $DownloadDir ([string]$Asset.name)
  if((Test-Path -LiteralPath $dest)-and(Get-Item -LiteralPath $dest).Length -eq [int64]$Asset.size){
    Say "Asset deja present: $dest";return $dest
  }
  $part="$dest.part";Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
  Say "Telechargement: $($Asset.browser_download_url)"
  Invoke-WebRequest -Uri $Asset.browser_download_url -Headers (Headers) -OutFile $part -UseBasicParsing
  if((Get-Item -LiteralPath $part).Length -ne [int64]$Asset.size){throw "Taille invalide: $($Asset.name)"}
  Move-Item -LiteralPath $part -Destination $dest -Force
  return $dest
}
function Update-Trivy{
  Ensure-Dir $WorkDir;$tmp=Join-Path $WorkDir ("update-trivy_"+[Guid]::NewGuid().ToString("N"));Ensure-Dir $tmp
  try{
    $release=Invoke-RestMethod -Uri "https://api.github.com/repos/aquasecurity/trivy/releases/latest" -Headers (Headers)
    $wa=$release.assets|Where-Object{$_.name -match 'windows-64bit\.zip$'}|Select-Object -First 1
    $la=$release.assets|Where-Object{$_.name -match 'Linux-64bit\.tar\.gz$'}|Select-Object -First 1
    $sa=$release.assets|Where-Object{$_.name -match '_checksums\.txt$'}|Select-Object -First 1
    if(-not$wa -or -not$la){throw "Assets Trivy Windows/Linux x64 introuvables."}
    $wz=Asset $wa;$lz=Asset $la
    if($sa){
      $sf=Asset $sa
      foreach($path in @($wz,$lz)){
        $name=Split-Path -Leaf $path
        $line=Get-Content -LiteralPath $sf|Where-Object{$_ -match ("\s+\*?"+[regex]::Escape($name)+"$")}|Select-Object -First 1
        if(-not$line){throw "Checksum absent pour $name."}
        $expected=(($line -split '\s+')[0]).ToLowerInvariant()
        $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if($expected -ne $actual){throw "Checksum invalide pour $name."}
      }
    }
    $wd=Join-Path $tmp "windows";$ld=Join-Path $tmp "linux";Ensure-Dir $wd;Ensure-Dir $ld
    Expand-Archive -LiteralPath $wz -DestinationPath $wd -Force
    Run (Tar) @("-xzf",$lz,"-C",$ld) "Extraction Linux"
    $win=Get-ChildItem -LiteralPath $wd -Recurse -File -Filter trivy.exe|Select-Object -First 1
    $lin=Get-ChildItem -LiteralPath $ld -Recurse -File|Where-Object{$_.Name -eq "trivy"}|Select-Object -First 1
    if(-not$win -or -not$lin){throw "Binaire Trivy absent apres extraction."}
    Run $win.FullName @("version","--quiet") "Validation Trivy";Ensure-Dir $ToolsDir
    Copy-Item -LiteralPath $win.FullName -Destination (Join-Path $ToolsDir "trivy.exe") -Force
    Copy-Item -LiteralPath $lin.FullName -Destination (Join-Path $ToolsDir "trivy") -Force
    $version=([string]$release.tag_name)-replace '^v',''
    [ordered]@{version=$version;release=$release.tag_name;updatedAtUtc=(Get-Date).ToUniversalTime().ToString("o")}|
      ConvertTo-Json|Set-Content -LiteralPath (Join-Path $ToolsDir "trivy-version.json") -Encoding UTF8
    Say "Executables Trivy $version installes dans $ToolsDir"
  }finally{
    if($KeepTemp){Say "Temp conserve: $tmp"}elseif(Test-Path -LiteralPath $tmp){Remove-Item $tmp -Recurse -Force}
  }
}

function Update-Db{
  $trivy=Join-Path $ToolsDir "trivy.exe"
  if(-not(Test-Path -LiteralPath $trivy)){throw "Lancez d'abord: .\trivy_offline.ps1 update-trivy"}
  Ensure-Dir $WorkDir;$tmp=Join-Path $WorkDir ("update-db_"+[Guid]::NewGuid().ToString("N"))
  $fresh=Join-Path $tmp "cache";$seed=Join-Path $tmp "seed";Ensure-Dir $fresh;Ensure-Dir $seed
  try{
    Run $trivy @("image","--cache-dir",$fresh,"--download-db-only","--no-progress") "DB CVE"
    Run $trivy @("image","--cache-dir",$fresh,"--download-java-db-only","--no-progress") "DB Java"
    "FROM alpine:3.19"|Set-Content -LiteralPath (Join-Path $seed "Dockerfile") -Encoding ASCII
    Run $trivy @("config","--cache-dir",$fresh,"--checks-bundle-repository",$ChecksBundleRepository,
      "--format","json","--output",(Join-Path $tmp "checks.json"),"--quiet",$seed) "Checks misconfiguration"
    if(-not(Test-Path -LiteralPath (Join-Path $fresh "db\trivy.db"))){throw "DB CVE absente apres mise a jour."}
    [ordered]@{updatedAtUtc=(Get-Date).ToUniversalTime().ToString("o")}|
      ConvertTo-Json|Set-Content -LiteralPath (Join-Path $fresh "offline-cache.json") -Encoding UTF8
    $backup="$CacheDir.previous"
    if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
    if(Test-Path -LiteralPath $CacheDir){Move-Item $CacheDir $backup}
    try{
      Move-Item $fresh $CacheDir
      if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
    }catch{
      if((-not(Test-Path -LiteralPath $CacheDir))-and(Test-Path -LiteralPath $backup)){Move-Item $backup $CacheDir}
      throw
    }
    Say "Bases Trivy mises a jour dans $CacheDir"
  }finally{
    if($KeepTemp){Say "Temp conserve: $tmp"}elseif(Test-Path -LiteralPath $tmp){Remove-Item $tmp -Recurse -Force}
  }
}
function Copy-Safe([string]$Source,[string]$Destination){
  if(-not(Test-Path -LiteralPath $Source)){return}
  if(Test-Path -LiteralPath $Destination){throw "Collision: $Destination"}
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}
function Package{
  foreach($p in @((Join-Path $ToolsDir "trivy.exe"),(Join-Path $ToolsDir "trivy"),(Join-Path $CacheDir "db\trivy.db"))){
    if(-not(Test-Path -LiteralPath $p)){throw "Element requis absent: $p"}
  }
  if(-not(Test-Path -LiteralPath $ExtraRootDir -PathType Container)){throw "Extra introuvable: $ExtraRootDir"}
  $vf=Join-Path $ToolsDir "trivy-version.json";$version="unknown"
  if(Test-Path -LiteralPath $vf){try{$version=[string](Get-Content $vf -Raw|ConvertFrom-Json).version}catch{}}
  if(-not$OutArchive){
    $archiveBase=Join-Path $ExportDir ("trivy-offline-tools_{0}_{1}" -f $version,(Get-Date -Format yyyyMMdd))
    $tarArchive="$archiveBase.tar.gz"
    $zipArchive="$archiveBase.zip"
  }else{
    $requestedArchive=[IO.Path]::GetFullPath($OutArchive)
    if($requestedArchive -match '(?i).tar.gz$'){
      $tarArchive=$requestedArchive
      $zipArchive=$requestedArchive.Substring(0,$requestedArchive.Length-7)+".zip"
    }elseif($requestedArchive -match '(?i).tgz$'){
      $tarArchive=$requestedArchive
      $zipArchive=$requestedArchive.Substring(0,$requestedArchive.Length-4)+".zip"
    }elseif($requestedArchive -match '(?i).zip$'){
      $zipArchive=$requestedArchive
      $tarArchive=$requestedArchive.Substring(0,$requestedArchive.Length-4)+".tar.gz"
    }else{
      throw "Extension attendue pour -OutArchive: .zip, .tar.gz ou .tgz"
    }
  }
  Ensure-Dir $WorkDir
  Ensure-Dir (Split-Path -Parent $tarArchive)
  Ensure-Dir (Split-Path -Parent $zipArchive)
  $tmp=Join-Path $WorkDir ("package_"+[Guid]::NewGuid().ToString("N"));$stage=Join-Path $tmp "bundle";Ensure-Dir $stage
  try{
    Copy-Safe (Join-Path $ToolsDir "trivy.exe") (Join-Path $stage "trivy.exe")
    Copy-Safe (Join-Path $ToolsDir "trivy") (Join-Path $stage "trivy")
    Copy-Safe $vf (Join-Path $stage "trivy-version.json")
    Copy-Safe $CacheDir (Join-Path $stage "cache")
    $excludedPackageRootNames=@(
      "export_endoflife_api.ps1",
      "export_endoflife_api.py",
      "trivy_offline.ps1",
      "README.md"
    )
    foreach($i in Get-ChildItem -LiteralPath $ExtraRootDir -Force){
      if($excludedPackageRootNames -contains $i.Name){
        Say "Fichier source exclu du package: $($i.Name)"
        continue
      }
      $destination=Join-Path $stage $i.Name
      if(Test-Path -LiteralPath $destination){
        $isEmptyDirectory=$i.PSIsContainer -and -not(Get-ChildItem -LiteralPath $i.FullName -Force|Select-Object -First 1)
        if($isEmptyDirectory){Say "Dossier Extra reserve et vide ignore: $($i.Name)";continue}
        throw "Collision non vide avec un element gere: $($i.FullName)"
      }
      Copy-Safe $i.FullName $destination
    }
    [ordered]@{packageFormat="trivy-offline-tools";trivyVersion=$version;createdAtUtc=(Get-Date).ToUniversalTime().ToString("o")}|
      ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stage "offline-package.json") -Encoding UTF8
    $sums=foreach($f in Get-ChildItem -LiteralPath $stage -Recurse -File|Sort-Object FullName){
      $rel=$f.FullName.Substring($stage.Length).TrimStart('\').Replace('\','/')
      "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant(),$rel
    }
    $sums|Set-Content -LiteralPath (Join-Path $stage "SHA256SUMS") -Encoding ASCII
    $packageId=[Guid]::NewGuid().ToString("N")
    $temporaryTar=Join-Path (Split-Path -Parent $tarArchive) (".{0}.{1}.partial.tar.gz" -f (Split-Path -Leaf $tarArchive),$packageId)
    $temporaryZip=Join-Path (Split-Path -Parent $zipArchive) (".{0}.{1}.partial.zip" -f (Split-Path -Leaf $zipArchive),$packageId)
    try{
      Create-ZipPackage $stage $temporaryZip
      $tarCreated=Create-TarPackage $stage $temporaryTar
      $archivesToValidate=@($temporaryZip)
      if($tarCreated){$archivesToValidate+=$temporaryTar}
      foreach($archive in $archivesToValidate){
        if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw "Archive non produite: $archive"}
        if((Get-Item -LiteralPath $archive).Length -le 0){throw "Archive vide: $archive"}
      }
      Move-Item -LiteralPath $temporaryZip -Destination $zipArchive -Force
      if($tarCreated){
        Move-Item -LiteralPath $temporaryTar -Destination $tarArchive -Force
      }
    }finally{
      Remove-Item -LiteralPath $temporaryTar -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $temporaryZip -Force -ErrorAction SilentlyContinue
    }
    if($tarCreated){
      Say "Package TAR.GZ cree: $tarArchive"
    }else{
      Say "Package TAR.GZ non cree (Python indisponible)."
    }
    Say "Package ZIP cree: $zipArchive"
  }finally{
    if($KeepTemp){Say "Temp conserve: $tmp"}elseif(Test-Path -LiteralPath $tmp){Remove-Item $tmp -Recurse -Force}
  }
}
function Bundle-Path{
  if($LocalArchive){
    $p=[IO.Path]::GetFullPath($LocalArchive)
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Archive introuvable: $p"}
    return $p
  }
  $p=Get-ChildItem -LiteralPath $ExportDir -File -ErrorAction SilentlyContinue|
    Where-Object{$_.Name -match '^trivy-offline-(tools|bundle)_.+\.(tar\.gz|tgz|zip)$'}|
    Sort-Object LastWriteTime -Descending|Select-Object -First 1
  if(-not$p){throw "Aucun bundle local dans $ExportDir. Utilisez -LocalArchive."}
  return $p.FullName
}

function CycloneDx{
  if(-not$CycloneDxInput){throw "-CycloneDxInput est obligatoire."}
  $input=[IO.Path]::GetFullPath($CycloneDxInput)
  if(-not(Test-Path -LiteralPath $input -PathType Leaf)){throw "CycloneDX introuvable: $input"}
  try{$bom=Get-Content -LiteralPath $input -Raw|ConvertFrom-Json}catch{throw "JSON invalide: $($_.Exception.Message)"}
  if([string]$bom.bomFormat -ne "CycloneDX"){throw "Le fichier n'est pas un CycloneDX JSON."}
  if($CycloneDxOutput){$output=[IO.Path]::GetFullPath($CycloneDxOutput)}
  else{$output=Join-Path (Split-Path -Parent $input) (([IO.Path]::GetFileNameWithoutExtension($input))+".updated.json")}
  $archive=Bundle-Path
  Ensure-Dir $WorkDir
  $tmp=Join-Path $WorkDir ("cyclonedx_"+[Guid]::NewGuid().ToString("N"));$extract=Join-Path $tmp "bundle";Ensure-Dir $extract
  try{
    Say "Bundle local uniquement: $archive"
    if($archive -match '\.zip$'){Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force}
    else{Run (Tar) @("-xzf",$archive,"-C",$extract) "Extraction bundle local"}
    $trivy=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter trivy.exe|
      Where-Object{Test-Path -LiteralPath (Join-Path $_.Directory.FullName "cache")}|Select-Object -First 1
    if(-not$trivy){throw "trivy.exe et cache associe introuvables."}
    $bc=Join-Path $trivy.Directory.FullName "cache"
    if(-not(Test-Path -LiteralPath (Join-Path $bc "db\trivy.db"))){throw "cache\db\trivy.db absent."}
    Ensure-Dir (Split-Path -Parent $output)
    $atomic=Join-Path $tmp "updated.json";$saved=@{}
    foreach($name in @("TRIVY_DISABLE_TELEMETRY","TRIVY_OFFLINE_SCAN","TRIVY_SKIP_DB_UPDATE","TRIVY_SKIP_JAVA_DB_UPDATE","TRIVY_SKIP_VERSION_CHECK")){
      $saved[$name]=[Environment]::GetEnvironmentVariable($name,"Process")
      [Environment]::SetEnvironmentVariable($name,"true","Process")
    }
    try{
      Run $trivy.FullName @("sbom","--cache-dir",$bc,"--offline-scan","--skip-db-update","--skip-java-db-update",
        "--skip-vex-repo-update","--skip-version-check","--disable-telemetry","--scanners","vuln",
        "--format","cyclonedx","--output",$atomic,$input) "CVE CycloneDX hors ligne"
    }finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],"Process")}}
    $check=Get-Content -LiteralPath $atomic -Raw|ConvertFrom-Json
    if([string]$check.bomFormat -ne "CycloneDX"){throw "Sortie CycloneDX invalide."}
    Move-Item -LiteralPath $atomic -Destination $output -Force
    Say "CycloneDX mis a jour sans Internet: $output"
  }finally{
    if($KeepTemp){Say "Temp conserve: $tmp"}elseif(Test-Path -LiteralPath $tmp){Remove-Item $tmp -Recurse -Force}
  }
}
switch($Command.ToLowerInvariant()){
  "update-trivy"{Update-Trivy}
  "update-db"{Update-Db}
  "package"{Package}
  "update-cyclonedx"{CycloneDx}
  "all"{Update-Trivy;Update-Db;Package}
}
