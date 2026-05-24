#!/bin/bash



# Set the input and output file names
#OUTPUT_PATH=/dev
#OUTPUT_FILE_BASENAME=sdi
#OUTPUT_FILE="${OUTPUT_PATH}/${OUTPUT_FILE_BASENAME}"
#OUTPUT_FILE_TYPE="$(file -b $OUTPUT_FILE)"
BASE_PATH=""
BASE_FILE_NAME=""
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
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
  else
    echo "Verbindungsaufbau mit Sockel ${control_path} zu ${target}"
    ssh -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
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
  output=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 ${REMOTE_HOST} true 2>&1)
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

function local_seg_hash {
  # $1 = Datei/Device (lokal), $2 = Segment-Index. Liefert SHA256 des Segments.
  local f=$1 idx=$2
  local count=$((SPLIT_SIZE / BLOCKSIZEBYTES))
  local skip=$((idx * count))
  dd if="$f" bs="$BLOCKSIZEBYTES" count="$count" skip="$skip" status=none | sha256sum | cut -d' ' -f1
}

function remote_seg_hash {
  # $1 = Datei/Device (auf Remote-Host), $2 = Segment-Index. Liefert SHA256 des Segments.
  local f=$1 idx=$2
  local count=$((SPLIT_SIZE / BLOCKSIZEBYTES))
  local skip=$((idx * count))
  execute_remote_command "dd if='$f' bs=$BLOCKSIZEBYTES count=$count skip=$skip status=none | sha256sum" | cut -d' ' -f1
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
        fi
      ) &
    else
      START=$((i * SPLIT_SIZE))
      echo "dd if=$OUTPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
      dd if=$OUTPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &
    fi
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
        fi
      ) &
    else
      START=$((i * SPLIT_SIZE))
      echo "dd if=$INPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
      dd if=$INPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &
    fi
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
      fi
    ) &
  done
  wait
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
      if [[ ${OPTARG} =~ ^[lnc]+$ ]]; then
        REMOTE_MODE="${OPTARG}"
      else
        REMOTE_MODE="n"
      fi
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
  BASE_FILE_TYPE=$(grep "^FILE_TYPE=" "$META_SRC" | cut -d "=" -f 2)
  BLOCKSIZEBYTES=$(grep "^BLOCKSIZEBYTES=" "$META_SRC" | cut -d "=" -f 2)
  COMPRESSION=$(grep "^COMPRESSION=" "$META_SRC" | cut -d "=" -f 2)
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
  SPLIT_SIZE=$((INPUT_SIZE / NUM_JOBS))

  # Teilbarkeit prüfen, damit kein Bereich übersprungen oder doppelt gelesen wird
  if [ $((INPUT_SIZE % NUM_JOBS)) -ne 0 ] || [ $((SPLIT_SIZE % BLOCKSIZEBYTES)) -ne 0 ]; then
    echo "Fehler: Quellgröße ($INPUT_SIZE) ist nicht glatt durch NUM_JOBS ($NUM_JOBS) und BLOCKSIZEBYTES ($BLOCKSIZEBYTES) teilbar."
    echo "Bitte -j und/oder -B passend zum ursprünglichen Clone-Aufruf wählen."
    exit 1
  fi

  echo "Beginning to check ..."
  check_cloned_image
fi


wait

if [ $REMOTE -eq 1 ]; then
  close_ssh_connection
fi
