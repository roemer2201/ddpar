#!/bin/bash

# Set default input and output file names

INPUT_FILE_BASENAME=""
OUTPUT_FILE=""
REMOTE=0
REMOTE_HOST=""
SSH_SOCKET_PATH="/tmp/ssh_socket_ddpar"
DEBUG=0
ASSUME_YES=0

# Hilfemeldung anzeigen
function show_help {
  SCRIPT_NAME=$(basename "$0")
  echo "$SCRIPT_NAME - Ein Bash-Skript zur Verarbeitung von Parametern"
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-i, --input PATH        Der Basisname des geteilten Abbildes (bei Remote: Pfad auf dem Remote-Host)"
  echo "-o, --output PATH       Vollständiger Pfad des (lokalen) Zielgeräts"
  echo "-r [n]                  Remote-Restore über SSH+Netcat (nur unkomprimiert)"
  echo "-R user@host            Angabe des Remote-Host, auf dem das Backup liegt"
  echo "-y                      Sicherheitsabfrage überspringen (assume yes)"
  echo "-h, --help              Diese Hilfe anzeigen"
  echo ""
  echo "Die Anzahl der Jobs und Blockgröße kann nicht geändert werden. Sie wird beim Erstellen des Abbildes festgelegt."
}

# Verwendung von getopts zur Verarbeitung der Optionen
while getopts ":i:o:r::R:yh" opt; do
  case $opt in
    i|-input) INPUT="$OPTARG";;
    o|-output) OUTPUT="$OPTARG";;
    y) ASSUME_YES=1;;
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
    h|-help) show_help; exit 1;;
    \?) echo "Ungültige Option: -$OPTARG";;
  esac
done


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

function execute_remote_background_command {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  local command=$1
  if [ -z "${command}" ]; then
    echo "Fehler: Kein Befehl zum Ausführen angegeben."
    return 1
  fi
  ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "nohup sh -c \"${command}\" > /tmp/ddpar.log 2>&1 &"
}

function close_ssh_connection {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  ssh -S "${SSH_SOCKET_PATH}" -O exit "${REMOTE_HOST}"
  if [ $? -ne 0 ]; then
    echo "Warnung: Fehler beim Schließen der SSH-Verbindung zu ${REMOTE_HOST}."
  fi
}

function remote_port_generation {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  REMOTE_PORT=$(( RANDOM % 55001 ))
  REMOTE_PORT=$(( REMOTE_PORT + 10000 ))
}

function check_remote_port_availability {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  execute_remote_command "ss -tln | grep -q \":${CURRENT_REMOTE_PORT}\""
  if [[ $? != 0 ]]; then
    return 0
  else
    [ "$DEBUG" -eq 1 ] && echo "Port ${CURRENT_REMOTE_PORT} bereits in Benutzung."
    return 1
  fi
}

function remote_restore_commands {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  # Startet auf dem Remote-Host einen netcat-Sender, der die übergebene Quelle
  # (z.B. "dd if=...part") an den verbindenden lokalen Client liefert.
  # Setzt anschließend OUTPUT_CMD_REMOTE_SOURCE für die lokale Empfängerseite.
  local remote_input_cmd=$1

  if [ -z "${REMOTE_PORT}" ]; then
    remote_port_generation
  fi
  CURRENT_REMOTE_PORT=$(( REMOTE_PORT + PART_NUM ))
  while true; do
    if check_remote_port_availability; then
      break
    else
      echo "Port ${CURRENT_REMOTE_PORT} on remote machine already in use, generate new port."
      remote_port_generation
      CURRENT_REMOTE_PORT=$(( REMOTE_PORT + PART_NUM ))
    fi
  done

  echo "REMOTE COMMAND: ${remote_input_cmd} | nc -N -l ${CURRENT_REMOTE_PORT}"
  execute_remote_background_command "${remote_input_cmd} | nc -N -l ${CURRENT_REMOTE_PORT}"

  MAX_ATTEMPTS=3
  SLEEP_INTERVAL=1
  ATTEMPT=1
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Checking if remote process is running on port ${CURRENT_REMOTE_PORT} (attempt $ATTEMPT)..."
    if execute_remote_command "ss -tuln | grep -q :${CURRENT_REMOTE_PORT}"; then
      echo "Process found on port ${CURRENT_REMOTE_PORT}. Exiting loop."
      break
    else
      echo "Process not found on port ${CURRENT_REMOTE_PORT}."
    fi
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -le $MAX_ATTEMPTS ]; then
      sleep $SLEEP_INTERVAL
    fi
  done
  if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "Process did not start on port ${CURRENT_REMOTE_PORT} after $MAX_ATTEMPTS attempts."
    return 1
  fi

  OUTPUT_CMD_REMOTE_SOURCE="nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}"
}

function restore_split_image {
#  for ((i=0; i<$NUM_JOBS; i++)); do
#    START=$((i * SPLIT_SIZE))
#    touch $OUTPUT_FILE
#    echo "zcat ${INPUT_FILES}${i}.gz | dd of=$OUTPUT_FILE bs=$BLOCKSIZEBYTES seek=$((START / BLOCKSIZEBYTES)) &"
#    zcat ${INPUT_FILES}${i}.gz | dd of=$OUTPUT_FILE bs=$BLOCKSIZEBYTES seek=$((START / BLOCKSIZEBYTES)) &
#  done

  echo "Starte die Prozesse ..."
  if [[ ${OUTPUT_FILE_TYPE} != "block special"* ]]; then
    echo "fallocate -l ${INPUT_SIZE} $OUTPUT_FILE"
    fallocate -l ${INPUT_SIZE} $OUTPUT_FILE
  fi
  for ((PART_NUM=0; PART_NUM<${NUM_JOBS}; PART_NUM++)); do
    START=$((PART_NUM * SPLIT_SIZE))
    OUTPUT_CMD="dd of=${OUTPUT_FILE} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) seek=$((START / ${BLOCKSIZEBYTES})) iflag=fullblock conv=notrunc"
    if [ $REMOTE -eq 1 ]; then
      # Remote netcat restore, unkomprimiert: Remote sendet, lokal wird empfangen und geschrieben
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is remote (uncompressed)"
      fi
      REMOTE_INPUT_CMD="dd if=${INPUT_FILES}${PART_NUM}.part bs=${BLOCKSIZEBYTES} iflag=fullblock"
      if ! remote_restore_commands "${REMOTE_INPUT_CMD}"; then
        echo "Remote-Restore-Sender für Teil ${PART_NUM} konnte nicht gestartet werden."
        break
      fi
      FULL_CMD="${OUTPUT_CMD_REMOTE_SOURCE} | ${OUTPUT_CMD} &"
    else
      # Build individual subcommands and concatinate, if enabled
      if [ ! -z "$COMPRESSION" ]; then
        if [ $PART_NUM -eq 0 ]; then
          echo "Source is compressed"
        fi
        INPUT_CMD="zcat ${INPUT_FILES}${PART_NUM}.gz"
      else
        if [ $PART_NUM -eq 0 ]; then
          echo "Source is uncompressed"
        fi
        INPUT_CMD="dd if=${INPUT_FILES}${PART_NUM}.part bs=${BLOCKSIZEBYTES} iflag=fullblock"
      fi
      FULL_CMD="${INPUT_CMD} | ${OUTPUT_CMD} &"
    fi
    echo "$FULL_CMD"
    eval "${FULL_CMD}"
  done
}


# Create spinoff variables
INPUT_PATH=$(dirname $INPUT)
INPUT_FILE_BASENAME=$(basename $INPUT)
INPUT_FILES="${INPUT_PATH}/${INPUT_FILE_BASENAME}-"
#OUTPUT_PATH=/dev
#OUTPUT_FILE_BASENAME=sdi
#OUTPUT_FILE="${OUTPUT_PATH}/${OUTPUT_FILE_BASENAME}"
OUTPUT_FILE_TYPE="$(file -b $OUTPUT)"
METADATA_FILE="${INPUT_FILES}metadata.txt"

# Get parameters from metadata file (lokal oder remote)
if [ $REMOTE -eq 1 ]; then
  connect_ssh
  METADATA_SRC=$(mktemp)
  execute_remote_command "cat \"$METADATA_FILE\"" > "$METADATA_SRC" 2>/dev/null
  if [ ! -s "$METADATA_SRC" ]; then
    echo "Die Metadatendatei $METADATA_FILE auf $REMOTE_HOST existiert nicht oder ist leer."
    rm -f "$METADATA_SRC"
    close_ssh_connection
    exit 1
  fi
else
  METADATA_SRC="$METADATA_FILE"
  if [ ! -e "$METADATA_SRC" ]; then
    echo "Die Datei existiert $METADATA_FILE nicht."
    exit 1
  fi
fi
NUM_JOBS=$(grep "^NUM_JOBS=" "$METADATA_SRC" | cut -d "=" -f 2)
FILE_NAME=$(grep "^FILE_NAME=" "$METADATA_SRC" | cut -d "=" -f 2)
SPLIT_SIZE=$(grep "^SPLIT_SIZE=" "$METADATA_SRC" | cut -d "=" -f 2)
INPUT_SIZE=$(grep "^INPUT_SIZE=" "$METADATA_SRC" | cut -d "=" -f 2)
INPUT_FILE_TYPE=$(grep "^FILE_TYPE=" "$METADATA_SRC" | cut -d "=" -f 2)
BLOCKSIZEBYTES=$(grep "^BLOCKSIZEBYTES=" "$METADATA_SRC" | cut -d "=" -f 2)
COMPRESSION=$(grep "^COMPRESSION=" "$METADATA_SRC" | cut -d "=" -f 2)
COMPRESSION_LEVEL=$(grep "^COMPRESSION_LEVEL=" "$METADATA_SRC" | cut -d "=" -f 2)

# Remote-Restore unterstützt derzeit nur unkomprimierte Backups (netcat, uncompressed)
if [ $REMOTE -eq 1 ] && [ ! -z "$COMPRESSION" ]; then
  echo "Remote-Restore unterstützt derzeit nur unkomprimierte Backups (netcat, uncompressed)."
  rm -f "$METADATA_SRC"
  close_ssh_connection
  exit 1
fi

# Überprüfung der erforderlichen Parameter
if [ -z "$INPUT_PATH" ] || [ -z "$INPUT_FILE_BASENAME" ] || [ -z "$OUTPUT" ]; then
  echo "Fehlende Parameter. Bitte geben Sie alle erforderlichen Parameter an."
  exit 1
fi

if [ -e $OUTPUT ]; then
  # Determine the type of the output
  OUTPUT_FILE_TYPE=$(file -b $OUTPUT)
  # Use the appropriate command to determine destination types and sizes
  case "$OUTPUT_FILE_TYPE" in
    # Wenn OUTPUT_FILE ein Blockdevice ist, prüfen, ob OUTPUT_FILE groß genug ist.
    "block special"*)
      OUTPUT_SIZE=$(blockdev --getsize64 $OUTPUT)
      if [ "$INPUT_SIZE" -gt "$OUTPUT_SIZE" ]; then
        echo "Fehler: Die Eingabegröße ($INPUT_SIZE) ist größer als die Ausgabegröße ($OUTPUT_SIZE)."
        exit 1
      fi
      OUTPUT_FILE="$OUTPUT"
      ;;
    # Wenn OUTPUT ein Verzeichnis ist, prüfen, ob genügend freier Speicherplatz vorhanden ist.
    directory)
      AVAILABLE_SPACE=$(df -B 1 "$OUTPUT" | awk 'NR==2{print $4}')
      if [ ! "$AVAILABLE_SPACE" -ge "$INPUT_SIZE" ]; then
        echo "Fehler: Nicht genügend Speicherplatz vorhanden für $INPUT_FILE_BASENAME in $OUTPUT ."
        exit 1
      fi
      OUTPUT_FILE="$OUTPUT/$INPUT_FILE_BASENAME"
      ;;
    # Wenn OUTPUT eine Datei ist (die bereits exitiert), prüfen, ob genügend freier Speicherplatz vorhanden ist.
    *)
      OUTPUT_DIR=$(dirname "$OUTPUT")
      OUTPUT_FILE="$OUTPUT"
      AVAILABLE_SPACE=$(df -B 1 "$OUTPUT_DIR" | awk 'NR==2{print $4}')
      if [ ! "$AVAILABLE_SPACE" -ge "$INPUT_SIZE" ]; then
        echo "Fehler: Nicht genügend Speicherplatz vorhanden für $INPUT_FILE_BASENAME in $OUTPUT_DIR ."
        exit 1
      fi
      ;;
  esac
else
  # Wenn OUTPUT eine Datei ist (die nicht exitiert), prüfen, ob genügend freier Speicherplatz vorhanden ist.
  OUTPUT_DIR=$(dirname "$OUTPUT")
  OUTPUT_FILE="$OUTPUT"
  AVAILABLE_SPACE=$(df -B 1 "$OUTPUT_DIR" | awk 'NR==2{print $4}')
    if [ ! "$AVAILABLE_SPACE" -ge "$INPUT_SIZE" ]; then
      echo "Fehler: Nicht genügend Speicherplatz vorhanden für $INPUT_FILE_BASENAME in $OUTPUT_DIR ."
      exit 1
    fi
  if [ -w "$OUTPUT_DIR" ]; then
    touch $OUTPUT
  else
    echo "Kein Schreibzugriff auf das Verzeichnis $OUTPUT_DIR vorhanden."
  fi

fi

echo "Nachfolgend werden die geteilten Dateien unter $INPUT_PATH/$INPUT_FILE_BASENAME nach $OUTPUT_FILE geschrieben."
if [ "$ASSUME_YES" -eq 1 ]; then
  echo "Sicherheitsabfrage übersprungen (-y). Beginning to restore ..."
  restore_split_image
else
  while true; do
    read -p "Möchten Sie fortfahren [y/N]? " choice
    case "$choice" in
      y|Y)
        echo "Beginning to restore ..."
        restore_split_image
        break
        ;;
      n|N|"")
        echo "Abbruch."
        # Fügen Sie hier den Code hinzu, der bei "Nein" ausgeführt werden soll
        if [ $REMOTE -eq 1 ]; then
          rm -f "$METADATA_SRC"
          close_ssh_connection
        fi
        exit 0
        ;;
      *)
        echo "Ungültige Eingabe. Bitte wählen Sie 'y' oder 'N'."
        ;;
    esac
  done
fi

#if [[ "$INPUT_FILE_TYPE" == "block special"* ]] && [[ "$OUTPUT_FILE_TYPE" == "block special"* ]]; then
#  echo "Beginning to restore ..."
#  restore_split_image
#else
#  echo "Input File Type ($INPUT_FILE_TYPE) stimmt nicht mit Output File Type ($OUTPUT_FILE_TYPE) überein."
#fi
#if [[ "$INPUT_FILE_TYPE" != "block special"* ]] && [[ "$OUTPUT_FILE_TYPE" != "block special"* ]]; then
#  echo "Beginning to restore ..."
#  restore_split_image
#else
#  echo "Input File Type ($INPUT_FILE_TYPE) stimmt nicht mit Output File Type ($OUTPUT_FILE_TYPE) überein."
#fi
wait

if [ $REMOTE -eq 1 ]; then
  rm -f "$METADATA_SRC"
  close_ssh_connection
fi
