#!/bin/bash

# Fehler in dd-/sha256sum-Pipelines sollen den Exit-Code der Pipeline
# bestimmen — so führt ein fehlgeschlagener Vergleich (sha256sum -c) zu
# einem Fehler-Exit des jeweiligen Teil-Jobs.
set -o pipefail

# Set the input and output file names
#OUTPUT_PATH=/dev
#OUTPUT_FILE_BASENAME=sdi
#OUTPUT_FILE="${OUTPUT_PATH}/${OUTPUT_FILE_BASENAME}"
#OUTPUT_FILE_TYPE="$(file -b $OUTPUT_FILE)"
BASE_PATH=""
BASE_FILE_NAME=""
INTERNAL_EXITCODE=0
NUM_JOBS=4
BLOCKSIZEBYTES=1048576
REMOTE=0
REMOTE_HOST=""
SSH_SOCKET_PATH="/tmp/ssh_socket_ddpar"
DEBUG=0

function show_help {
  SCRIPT_NAME=$(basename "$0")
  echo "$SCRIPT_NAME - Verify consistency of source, backup or destination."
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-b PATH         Der Basisname (opt. mit Pfad) des geteilten Abbildes"
  echo "-s PATH         Source to compare against"
  echo "-d PATH         Destination to compare against"
  echo "-j NUM          Anzahl der Jobs für den Clone-Check (Default: 4, nur ohne -b)"
  echo "-B NUM          Blockgröße in Bytes für den Clone-Check (Default: 1048576, nur ohne -b)"
  echo "-r [n]          Remote-Check über SSH (nur unkomprimiert). Die gesicherte/geklonte"
  echo "                Seite (-b bzw. bei Clone-Check -d) liegt auf dem Remote-Host."
  echo "-R user@host    Angabe des Remote-Host"
  echo "-h, --help      Zeigt diese Hilfemeldung an"
}

function establish_ssh_connection {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  local target=$1
  local control_path=$2
  local password=$3
  if [ -n "$password" ]; then
    if ! which sshpass > /dev/null; then
      echo "Der Befehl \"sshpass\" existiert nicht. Bitte installieren Sie das entsprechende Paket über ihren Paketmanager."
      exit 1
    fi
    SSHPASS="$password" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
  else
    echo "Verbindungsaufbau mit Sockel ${control_path} zu ${target}"
    ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
  fi
  return $?
}

function is_ssh_socket_alive {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  ssh -o ControlPath="${SSH_SOCKET_PATH}" -O check "${REMOTE_HOST}" 2>/dev/null
  return $?
}

function connect_ssh {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  if [ -z "${REMOTE_HOST}" ]; then
    echo "Fehler: Kein Remote-Host angegeben."
    exit 1
  fi
  if is_ssh_socket_alive; then
    echo "SSH-Verbindung zu ${REMOTE_HOST} besteht bereits."
    return 0
  fi
  output=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 ${REMOTE_HOST} true 2>&1)
  if [[ $? -eq 0 ]]; then
    echo "Passwortloser Verbindungsaufbau war erfolgreich."
    establish_ssh_connection "${REMOTE_HOST}" "${SSH_SOCKET_PATH}"
  elif echo "$output" | grep -q "Permission denied"; then
    echo "Host ist erreichbar, aber passwortlose Authentifizierung fehlgeschlagen."
    echo -n "Bitte geben Sie das SSH-Passwort für ${REMOTE_HOST} ein: "
    read -s USER_PASSWORD
    echo
    establish_ssh_connection "${REMOTE_HOST}" "${SSH_SOCKET_PATH}" "$USER_PASSWORD"
    if [ $? -ne 0 ]; then
      echo "Verbindung zu ${REMOTE_HOST} konnte nicht hergestellt werden."
      exit 1
    fi
  else
    echo "Unbekannter Fehler oder Host nicht erreichbar. Ausgabe:"
    echo "$output"
  fi
  echo "SSH-Verbindung zu ${REMOTE_HOST} wurde erfolgreich aufgebaut."
}

function execute_remote_command {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  local command=$1
  if [ -z "${command}" ]; then
    echo "Fehler: Kein Befehl zum Ausführen angegeben."
    return 1
  fi
  ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "${command}"
  return $?
}

function close_ssh_connection {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  ssh -S "${SSH_SOCKET_PATH}" -O exit "${REMOTE_HOST}"
  if [ $? -ne 0 ]; then
    echo "Warnung: Fehler beim Schließen der SSH-Verbindung zu ${REMOTE_HOST}."
  fi
}

# Verwaltung der parallelen Vergleichs-Jobs:
# Jeder Teil-Vergleich wird mit PID und Beschreibung registriert, damit
# wait_for_jobs die Exit-Codes einzeln einsammeln kann. So endet das Skript
# mit Exit-Code != 0, sobald ein Segment nicht übereinstimmt.
JOB_PIDS=()
JOB_LABELS=()

function register_job {
  JOB_PIDS+=("$1")
  JOB_LABELS+=("$2")
}

function wait_for_jobs {
  local failed=0
  local i rc
  for i in "${!JOB_PIDS[@]}"; do
    wait "${JOB_PIDS[$i]}"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "Fehler: ${JOB_LABELS[$i]} meldet Abweichung oder Lesefehler (Exit-Code ${rc})."
      failed=$((failed + 1))
    fi
  done
  JOB_PIDS=()
  JOB_LABELS=()
  if [ $failed -gt 0 ]; then
    echo "Prüfung FEHLGESCHLAGEN: ${failed} Segment(e) weichen ab oder konnten nicht gelesen werden."
    INTERNAL_EXITCODE=1
    return 1
  fi
  echo "Prüfung erfolgreich: Alle Segmente stimmen überein."
  return 0
}

function cleanup_on_signal {
  trap - INT TERM
  echo "Abbruch: Beende laufende Vergleichs-Prozesse ..." >&2
  local pids
  pids=$(jobs -p)
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086 # PIDs sind whitespace-getrennt gewollt
    kill $pids 2>/dev/null
    wait $pids 2>/dev/null
  fi
  if [ $REMOTE -eq 1 ] && is_ssh_socket_alive; then
    close_ssh_connection
  fi
  exit 130
}
trap cleanup_on_signal INT TERM

function part_bytes {
  # Bytes, die Segment $1 umfasst: normale Segmente SPLIT_SIZE, das letzte
  # zusätzlich den nicht gleichmäßig verteilbaren Rest; bei Eingaben kleiner
  # als NUM_JOBS Blöcke ggf. weniger oder 0.
  local part=$1
  local start=$((part * SPLIT_SIZE))
  local remaining=$((INPUT_SIZE - start))
  if [ "${remaining}" -le 0 ]; then
    echo 0
  elif [ "${part}" -eq $((NUM_JOBS - 1)) ] || [ "${remaining}" -lt "${SPLIT_SIZE}" ]; then
    echo "${remaining}"
  else
    echo "${SPLIT_SIZE}"
  fi
}

function local_seg_hash {
  # $1 = Datei/Device (lokal), $2 = Segment-Index. Liefert SHA256 des Segments.
  local f=$1 idx=$2
  local start=$((idx * SPLIT_SIZE))
  dd if="$f" bs="$BLOCKSIZEBYTES" iflag=count_bytes,skip_bytes count="$(part_bytes "$idx")" skip="$start" status=none | sha256sum | cut -d' ' -f1
}

function remote_seg_hash {
  # $1 = Datei/Device (auf Remote-Host), $2 = Segment-Index. Liefert SHA256 des Segments.
  local f=$1 idx=$2
  local start=$((idx * SPLIT_SIZE))
  execute_remote_command "dd if='$f' bs=$BLOCKSIZEBYTES iflag=count_bytes,skip_bytes count=$(part_bytes "$idx") skip=$start status=none | sha256sum" | cut -d' ' -f1
}

function remote_part_hash {
  # $1 = Segment-Index. Hasht die komplette .part-Datei auf dem Remote-Host
  # (entspricht dem Segment, da unkomprimiert exakt SPLIT_SIZE Bytes).
  local idx=$1
  execute_remote_command "sha256sum '${BASE_FILES}${idx}.part'" | cut -d' ' -f1
}

function check_restored_image {
  for ((i=0; i<$NUM_JOBS; i++)); do
    if [ $REMOTE -eq 1 ]; then
      # Backup-Teile liegen remote (.part), Ziel ist lokal
      (
        h_bak=$(remote_part_hash "$i")
        h_dst=$(local_seg_hash "$OUTPUT_FILE" "$i")
        if [ "$h_bak" = "$h_dst" ]; then
          echo "Segment $i: OK ($h_bak)"
        else
          echo "Segment $i: MISMATCH (backup=$h_bak, destination=$h_dst)"
          exit 1
        fi
      ) &
    else
      START=$((i * SPLIT_SIZE))
      echo "dd if=$OUTPUT_FILE bs=$BLOCKSIZEBYTES iflag=count_bytes,skip_bytes count=$(part_bytes "$i") skip=$START status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
      dd if="$OUTPUT_FILE" bs="$BLOCKSIZEBYTES" iflag=count_bytes,skip_bytes count="$(part_bytes "$i")" skip="$START" status=none | sha256sum -c "$BASE_FILES$i.sha256" | sed "s#-#$BASE_FILES$i#" &
    fi
    register_job $! "Segment $i (restore-check)"
  done
}

function check_backuped_image {
  for ((i=0; i<$NUM_JOBS; i++)); do
    if [ $REMOTE -eq 1 ]; then
      # Quelle ist lokal, Backup-Teile liegen remote (.part)
      (
        h_src=$(local_seg_hash "$INPUT_FILE" "$i")
        h_bak=$(remote_part_hash "$i")
        if [ "$h_src" = "$h_bak" ]; then
          echo "Segment $i: OK ($h_src)"
        else
          echo "Segment $i: MISMATCH (source=$h_src, backup=$h_bak)"
          exit 1
        fi
      ) &
    else
      START=$((i * SPLIT_SIZE))
      echo "dd if=$INPUT_FILE bs=$BLOCKSIZEBYTES iflag=count_bytes,skip_bytes count=$(part_bytes "$i") skip=$START status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
      dd if="$INPUT_FILE" bs="$BLOCKSIZEBYTES" iflag=count_bytes,skip_bytes count="$(part_bytes "$i")" skip="$START" status=none | sha256sum -c "$BASE_FILES$i.sha256" | sed "s#-#$BASE_FILES$i#" &
    fi
    register_job $! "Segment $i (backup-check)"
  done
}

function check_cloned_image {
  # Vergleicht Quelle und Ziel eines Clones segmentweise und parallel.
  # Es existieren keine .sha256-Dateien, daher werden die Hashes beider
  # Seiten direkt berechnet und verglichen.
  for ((i=0; i<NUM_JOBS; i++)); do
    (
      HASH_SRC=$(local_seg_hash "$SOURCE" "$i")
      if [ $REMOTE -eq 1 ]; then
        # Geklontes Ziel liegt auf dem Remote-Host
        HASH_DST=$(remote_seg_hash "$DESTINATION" "$i")
      else
        HASH_DST=$(local_seg_hash "$DESTINATION" "$i")
      fi
      if [ "$HASH_SRC" = "$HASH_DST" ]; then
        echo "Segment $i: OK ($HASH_SRC)"
      else
        echo "Segment $i: MISMATCH (src=$HASH_SRC, dst=$HASH_DST)"
        exit 1
      fi
    ) &
    register_job $! "Segment $i (clone-check)"
  done
}

# Verwendung von getopts zur Verarbeitung der Optionen
while getopts ":b:s:d:j:B:r::R:h" opt; do
  case $opt in
    b)
      # Auflösung des Pfads erfolgt nach der Optionsschleife (remote-abhängig)
      BASE_ARG="$OPTARG"
      ;;
#    n) echo "Set BASE_FILE_NAME=$OPTARG"; BASE_FILE_NAME="$OPTARG";; # Not needed anymore due to combined b ( = p + n )
    s) echo "Set SOURCE=$OPTARG"; SOURCE="$OPTARG" ;;
    d) echo "Set DESTINATION=$OPTARG"; DESTINATION="$OPTARG" ;;
    j) echo "Set NUM_JOBS=$OPTARG"; NUM_JOBS="$OPTARG" ;;
    B) echo "Set BLOCKSIZEBYTES=$OPTARG"; BLOCKSIZEBYTES="$OPTARG" ;;
    r)
      REMOTE=1
      # Der Remote-Check überträgt nur SHA256-Hashes über SSH; die Modi l/c
      # aus ddpar.sh sind hier ohne Bedeutung.
      ;;
    R)
      REMOTE=1
      if [ -n "${OPTARG}" ]; then
        REMOTE_HOST="${OPTARG}"
      fi
      ;;
    h|-help) show_help; exit 0;;
    \?) echo "Ungültige Option: -$OPTARG";;
  esac
done

# Basis-Pfad auflösen: bei Remote nicht via realpath (Pfad liegt auf dem Remote-Host)
if [ -n "$BASE_ARG" ]; then
  if [ $REMOTE -eq 1 ]; then
    BASE_PATH=$(dirname "$BASE_ARG")
    BASE_FILE_NAME=$(basename "$BASE_ARG")
  else
    BASE_PATH=$(dirname "$(realpath "$BASE_ARG")")
    BASE_FILE_NAME=$(basename "$(realpath "$BASE_ARG")")
  fi
  echo "Set BASE_PATH=${BASE_PATH}"
  echo "Set BASE_FILE_NAME=${BASE_FILE_NAME}"
fi

# Bei Remote-Check früh die SSH-Verbindung aufbauen
if [ $REMOTE -eq 1 ]; then
  connect_ssh
fi

# Überprüfung der erforderlichen Parameter
# Extend the check to be able to compare one of source <-> backup, backup <-> destination, source <-> destination,
# by making sure, that only 2 out of those 3 parameters are set.
# Currently only backup <-> destination works.

# Check if only one of the three variables is set
if { [ -n "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; } \
|| { [ -z "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; } \
|| { [ -z "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -n "$DESTINATION" ]; }; then
  echo "Only one of the three variables is set."
  exit 1
fi

# Check if none of the three variables is set
if [ -z "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "None of the three variables is set."
  exit 1
fi

# Check if all three variables are set
if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "All three variables are set. The loop will not be executed."
fi

# Create spinoff variables
if [ ! -z "${BASE_PATH}" ]; then
  BASE_FILES="${BASE_PATH}/${BASE_FILE_NAME}-"
  METADATA_FILE="${BASE_FILES}metadata.txt"

  # Get parameters from metadata file (lokal oder remote)
  if [ $REMOTE -eq 1 ]; then
    META_SRC=$(mktemp)
    execute_remote_command "cat '$METADATA_FILE'" > "$META_SRC" 2>/dev/null
    if [ ! -s "$META_SRC" ]; then
      echo "Die Metadatendatei $METADATA_FILE auf $REMOTE_HOST existiert nicht oder ist leer."
      rm -f "$META_SRC"
      close_ssh_connection
      exit 1
    fi
  else
    META_SRC="$METADATA_FILE"
  fi
  NUM_JOBS=$(grep "^NUM_JOBS=" "$META_SRC" | cut -d "=" -f 2)
  SPLIT_SIZE=$(grep "^SPLIT_SIZE=" "$META_SRC" | cut -d "=" -f 2)
  INPUT_SIZE=$(grep "^INPUT_SIZE=" "$META_SRC" | cut -d "=" -f 2)
  BASE_FILE_TYPE=$(grep "^FILE_TYPE=" "$META_SRC" | cut -d "=" -f 2)
  BLOCKSIZEBYTES=$(grep "^BLOCKSIZEBYTES=" "$META_SRC" | cut -d "=" -f 2)
  COMPRESSION=$(grep "^COMPRESSION=" "$META_SRC" | cut -d "=" -f 2)
  # Ältere Metadatendateien ohne INPUT_SIZE: glatte Teilung annehmen
  [ -z "$INPUT_SIZE" ] && INPUT_SIZE=$((SPLIT_SIZE * NUM_JOBS))
  [ $REMOTE -eq 1 ] && rm -f "$META_SRC"

  # Remote-Check unterstützt derzeit nur unkomprimierte Backups
  if [ $REMOTE -eq 1 ] && [ ! -z "$COMPRESSION" ]; then
    echo "Remote-Check unterstützt derzeit nur unkomprimierte Backups (netcat, uncompressed)."
    close_ssh_connection
    exit 1
  fi

  # Debug Info:
  echo ${BASE_PATH}
  echo ${BASE_FILE_NAME}
  echo ${BASE_FILES}\*
fi
if [ ! -z "$SOURCE" ]; then
  INPUT_FILE=$SOURCE
  INPUT_FILE_TYPE="$(file -b $SOURCE)"
fi
if [ ! -z "$DESTINATION" ]; then
  OUTPUT_FILE=$DESTINATION
  # Beim Remote-Clone-Check (kein BASE_PATH) liegt das Ziel remote -> file -b nicht lokal aufrufen
  if [ $REMOTE -eq 1 ] && [ -z "${BASE_PATH}" ]; then
    OUTPUT_FILE_TYPE=$(execute_remote_command "file -b '$DESTINATION'")
  else
    OUTPUT_FILE_TYPE="$(file -b $DESTINATION)"
  fi
fi


# Old Debug Info, can be removed
#echo "BASE_FILE_TYPE: ${BASE_FILE_TYPE}"
#echo "DESTINATION: $DESTINATION"
#echo "OUTPUT_FILE: ${OUTPUT_FILE}"
#echo "OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"

if [ ! -z "$SOURCE" ] && [ ! -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "Comparing Source $SOURCE with $BASE_PATH ..."
fi

# Check if only $SOURCE and $BASE_PATH are set
if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Base Path $BASE_PATH ..."

  if [[ "${BASE_FILE_TYPE}" == "block special"* ]] && [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    echo "Beginning to check ..."
    check_backuped_image
  fi
  if [[ "${BASE_FILE_TYPE}" != "block special"* ]] && [[ "${INPUT_FILE_TYPE}" != "block special"* ]]; then
    echo "Beginning to check ..."
    check_backuped_image
  fi
fi

# Check if only $BASE_PATH and $DESTINATION are set
if [ -z "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Base Path $BASE_PATH with Destination $DESTINATION ..."

  if [[ "${BASE_FILE_TYPE}" == "block special"* ]] && [[ "${OUTPUT_FILE_TYPE}" == "block special"* ]]; then
    echo "Beginning to check ..."
    check_restored_image
  fi
  if [[ "${BASE_FILE_TYPE}" != "block special"* ]] && [[ "${OUTPUT_FILE_TYPE}" != "block special"* ]]; then
    echo "Beginning to check ..."
    check_restored_image
  fi

fi

# Check if only $SOURCE and $DESTINATION are set (Clone-Check)
if [ -n "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Destination $DESTINATION ..."

  # Größe der Quelle bestimmen (kein Metadatenfile vorhanden)
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    INPUT_SIZE=$(blockdev --getsize64 "$SOURCE")
  else
    INPUT_SIZE=$(stat -c %s "$SOURCE")
  fi
  # Gleiche Aufteilung wie beim Clone-Vorgang (ddpar.sh size_calculation):
  # SPLIT_SIZE auf Blockgröße abgerundet, das letzte Segment prüft den Rest.
  SPLIT_SIZE=$(( (INPUT_SIZE / (NUM_JOBS * BLOCKSIZEBYTES)) * BLOCKSIZEBYTES ))
  [ "$SPLIT_SIZE" -eq 0 ] && SPLIT_SIZE=$BLOCKSIZEBYTES

  echo "Beginning to check ..."
  check_cloned_image
fi


wait_for_jobs

if [ $REMOTE -eq 1 ]; then
  close_ssh_connection
fi

exit ${INTERNAL_EXITCODE}
