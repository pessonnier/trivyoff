#!/bin/bash

VERSION="1.2.2"
# Récupération de la date actuelle au format YYYYMMDD
DT=$(date +%Y%m%d_%H%M%S)

# Récupération du nom de l'hôte
HN=$(hostname)

# Initialisation des variables par défaut
# Nom du projet ou "sansnom" par défaut
PROJECT_NAME="sansnom"
# Chemin à analyser (par défaut /)
SCAN_PATH="/"
# Mode de scan (par défaut rootfs)
SCAN_MODE="rootfs"
# Les paramètres utilisés par Trivy
PARAM=""
# Le chemin absolu vers le script trivy
SCRIPT_PATH=$(realpath "$0")
TRIVY_DIR=$(dirname "$SCRIPT_PATH")

# Traitement des arguments
while [[ $# -gt 0 ]]
do
  key="$1"

  case $key in
    -p|--projet) # un nom de projet et de composant d'infrastructure pour distinguer plus facilement les fichiers générés
      PROJECT_NAME="$2"
      shift
      shift
      ;;
    -c|--path) # par défaut /, si -m fs alors idiquez le chemin des sources du projet
      SCAN_PATH="$2"
      shift
      shift
      ;;
    -m|--mode) # rootfs, fs, k8s, sbom, image
      SCAN_MODE="$2"
      shift
      shift
      ;;
    *)
      # Les autres paramètres sont ajoutés à PARAM, par exemple --skip-dirs /data ou /u01 pour exclure les fichiers d'une base de données
      PARAM="$PARAM $1"
      shift
      ;;
  esac
done

SCANNERS="--scanners license"
SCANNERS_TABLE="--scanners misconfig,license"
SRC=""
IMAGE_CONFIG_SCANNERS=""

if [ "$SCAN_MODE" == "fs" ];
then
   SCANNERS="--scanners misconfig,secret,license"
   SCANNERS_TABLE="--scanners misconfig,secret,license"
   SRC="_src"
fi

# k8s
# A FAIRE : utiliser --exclude-namespaces, --include_namespaces, --exclude-kinds et --include-kinds en fonction des règles de nommage
# A FAIRE : ajouter la génération d'un --report summary
# A FAIRE : comprendre et documenter dans la fiche les conséquence de --skip-images
# A FAIRE : il faudra un SCAN_PATH vide par défaut, si un fichier est indiqué alors il sera supposé être un kubconfig comme $HOME/.kube/config et la commande à générer sera --kubconfig ${SCAN_PATH}
if [ "$SCAN_MODE" == "k8s" ];
then
   SCANNERS="--scanners misconfig,secret,license"
   SCANNERS_TABLE="--scanners misconfig,secret,license"
   IMAGE_CONFIG_SCANNERS=
   SRC="_k8s"
fi

# image
if [ "$SCAN_MODE" == "image" ];
then
   SCANNERS="--scanners license"
   SCANNERS_TABLE="--scanners misconfig,license"
   IMAGE_CONFIG_SCANNERS="--image-config-scanners misconfig"
   SRC="_image"
fi

# Définition du fichier journal avec la date actuelle
LOGFILE="${PROJECT_NAME}.${DT}.trivy_scan.log"
FILEPREFIX="${PROJECT_NAME}_${HN}.${DT}.${SCAN_MODE}"
ARCHIVE_NAME="${PROJECT_NAME}${SRC}_${DT}_${HN}.tar.gz"

# Redirection de la sortie vers le fichier journal
echo "Début de l'analyse Trivy sur ${SCAN_PATH} à $(date +%T) depuis ${TRIVY_DIR}" | tee -a ${LOGFILE}
echo "version ${VERSION} paramètres ${SCAN_MODE} ${SCANNERS} ${PARAM}" | tee -a ${LOGFILE}

# Dernière mise à jour des paquets
if command -v dnf &> /dev/null; then
    LAST_UPDATE=$(dnf history list | grep " update \| upgrade " | head -1 | grep -Po "\b\d{4}-\d{2}-\d{2} +\d{2}:\d{2}:\d{2}\b" | tr -s " ")
elif command -v yum &> /dev/null; then
    LAST_UPDATE=$(yum history list | grep " update \| upgrade " | head -1 | grep -Po "\b\d{4}-\d{2}-\d{2} +\d{2}:\d{2}:\d{2}\b" | tr -s " ")
elif command -v apt &> /dev/null; then
    LAST_UPDATE=$(cat /var/log/apt/history.log | grep -P -B 1 "Commandline:.*upgrade" | grep -Po "\d{4}-\d{2}-\d{2} +\d{2}:\d{2}:\d{2}" | tr -s " ")
else
    echo "Avertissement: lors de la vérification des mises à jour. Ni dnf, ni ym, ni apt n'a été trouvé sur le système" | tee -a ${LOGFILE}
fi

if echo "$LAST_UPDATE" | grep -qPo "^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2][0-9]|3[0-1]) (0[0-9]|1[0-9]|2[0-3]):(0[0-9]|[1-5][0-9]):(0[0-9]|[1-5][0-9])$"; then
    echo "Dernière mise à jour système : ${LAST_UPDATE:0:10}T${LAST_UPDATE:11:8}Z" | tee -a ${LOGFILE}
else
    echo "Avertissement: Format de date invalide pour la dernière mise à jour ($LAST_UPDATE)" | tee -a ${LOGFILE}
fi

# Analyse CycloneDX
# A FAIRE : supp --skip-policy-update et vérifier
echo "Commande Trivy CycloneDX : ${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --format cyclonedx --output ${FILEPREFIX}.cyclonedx.json ${SCAN_PATH}" | tee -a ${LOGFILE}
${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --format cyclonedx --output ${FILEPREFIX}.cyclonedx.json ${SCAN_PATH} >> ${LOGFILE} 2>&1
if [ $? -ne 0 ]; then
  echo "Erreur lors de la génération du CycloneDX. Consultez le fichier journal pour plus de détails." | tee -a ${LOGFILE}
  exit 1
fi
echo "Génération du CycloneDX terminée" | tee -a ${LOGFILE}

# Analyse de la liste des paquets en JSON
echo "Commande Trivy JSON : ${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS_TABLE} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --list-all-pkgs --format json --output ${FILEPREFIX}.json ${SCAN_PATH}" | tee -a ${LOGFILE}
${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS_TABLE} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --list-all-pkgs --format json --output ${FILEPREFIX}.json ${SCAN_PATH} >> ${LOGFILE} 2>&1
if [ $? -ne 0 ]; then
  echo "Erreur lors de la génération du format Trivy. Consultez le fichier journal pour plus de détails." | tee -a ${LOGFILE}
  exit 1
fi
echo "Génération du format Trivy terminée" | tee -a ${LOGFILE}

# Analyse de configuration, des licences et des CVE au format tableau
echo "Commande Trivy Tableau : ${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS_TABLE} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --format table --dependency-tree --output ${FILEPREFIX}.config.licence.CVE.txt ${SCAN_PATH}" | tee -a ${LOGFILE}
${TRIVY_DIR}/trivy ${SCAN_MODE} --skip-java-db-update --skip-check-update --skip-version-check --disable-telemetry --offline-scan --timeout 10m --skip-files ${TRIVY_DIR}/trivy.exe --skip-files ${TRIVY_DIR}/trivy --cache-dir ${TRIVY_DIR}/cache ${SCANNERS_TABLE} ${IMAGE_CONFIG_SCANNERS} ${PARAM} --format table --dependency-tree --output ${FILEPREFIX}.config.licence.CVE.txt ${SCAN_PATH} >> ${LOGFILE} 2>&1
if [ $? -ne 0 ]; then
  echo "Erreur lors de la génération des défauts de configuration, du tableau des CVE et des licences. Consultez le fichier journal pour plus de détails." | tee -a ${LOGFILE}
  exit 1
fi
echo "Génération des défauts de configuration, du tableau des CVE et des licences terminée" | tee -a ${LOGFILE}

# Création de l'archive TAR.GZ
tar -czf ${ARCHIVE_NAME} ${FILEPREFIX}.* ${LOGFILE}
echo "Archive TAR.GZ créée : $ARCHIVE_NAME" | tee -a ${LOGFILE}
