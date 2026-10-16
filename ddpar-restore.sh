#!/bin/bash
#
# Restore segmented backups into a file or block device.
# Version: 1.0.1 (2026-10-17)
# Flow: read and validate metadata and parts; prepare the target; restore all
# segments; collect local and remote worker results.

# Fehler in zcat-/dd-/nc-Pipelines sollen den Exit-Code der Pipeline bestimmen,
# sonst zählt nur der letzte Befehl (z.B. ein erfolgreiches dd of=...).
set -o pipefail
# shellcheck source=ddpar-common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ddpar-common.sh" || exit 1

# Set default input and output file names

INPUT_FILE_BASENAME=""
OUTPUT_FILE=""
INTERNAL_EXITCODE=0
REMOTE=0
# Remote-Modus: "n" = netcat, Dekompression auf DIESER Maschine,
# "c" = netcat, Dekompression auf der Remote-Maschine
REMOTE_MODE="n"
REMOTE_HOST=""

DEBUG=0
ASSUME_YES=0
SKIP_PREALLOC=0

# Hilfemeldung anzeigen
function show_help {
  SCRIPT_NAME=$(basename -- "$0")
  echo "$SCRIPT_NAME - Ein Bash-Skript zur Verarbeitung von Parametern"
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-i, --input PATH        Der Basisname des geteilten Abbildes (bei Remote: Pfad auf dem Remote-Host)"
  echo "-o, --output PATH       Vollständiger Pfad des (lokalen) Zielgeräts"
  echo "-r [nc]                 Remote-Restore über SSH+Netcat. Komprimierte Backups werden"
  echo "                        unterstützt. Remote-Optionen:"
  echo "                          n (Default): der Remote-Host sendet die .gz-Teile unverändert,"
  echo "                            zcat läuft lokal (local decompression, kein gzip auf der Gegenseite)"
  echo "                          c: der Remote-Host packt die .gz-Teile selbst aus (remote decompression),"
  echo "                            über netcat gehen die Rohdaten; dort wird gzip benötigt"
  echo "-R user@host            Angabe des Remote-Host, auf dem das Backup liegt"
  echo "-y                      Sicherheitsabfrage überspringen (assume yes)"
  echo "-P                      Vorab-Reservierung des Zielplatzes (fallocate) überspringen"
  echo "DDPAR_NETWORK_TIMEOUT: netcat inactivity timeout in seconds (default: 300)."
  echo "-h, --help              Diese Hilfe anzeigen"
  echo ""
  echo "Die Anzahl der Jobs und Blockgröße kann nicht geändert werden. Sie wird beim Erstellen des Abbildes festgelegt."
}

# Normalize aliases while preserving literal option values.
ddpar_normalize_args "$@"
set -- "${DDPAR_ARGS[@]}"
# Verwendung von getopts zur Verarbeitung der Optionen
while getopts ":i:o:r::R:yPh" opt; do
  case $opt in
    i) INPUT="$OPTARG";;
    o) OUTPUT="$OPTARG";;
    y) ASSUME_YES=1;;
    P) SKIP_PREALLOC=1;;
    r)
      REMOTE=1
      # "n" = Dekompression lokal, "c" = Dekompression auf der Remote-Maschine.
      # "l" (Datenkanal verschlüsselt) ist weiterhin nicht implementiert.
      case "${OPTARG}" in
        n|"") REMOTE_MODE="n";;
        c)    REMOTE_MODE="c";;
        l)
          echo "Error: encrypted mode l is not implemented; refusing plaintext transfer." >&2
          exit 2
          ;;
        -*)
          # "-r" ohne Modus: getopts hat bereits die nächste Option als Argument
          # gelesen. OPTIND zurücksetzen, damit sie regulär verarbeitet wird.
          REMOTE_MODE="n"
          OPTIND=$((OPTIND - 1))
          ;;
        *)
          echo "Ungültiger Remote-Modus '${OPTARG}'. Gültige Angaben: l|n|c"
          exit 1
          ;;
      esac
      ;;
    R)
      REMOTE=1
      if [ -n "${OPTARG}" ]; then
        REMOTE_HOST="${OPTARG}"
      fi
      ;;
    h) show_help; exit 0;;
    \?) echo "Unknown option: -${OPTARG}" >&2; exit 2;;
    :)
      # -r darf ohne Argument stehen (Default-Modus n), alle anderen Optionen nicht
      if [ "$OPTARG" = "r" ]; then
        REMOTE=1
        REMOTE_MODE="n"
      else
        echo "Option -$OPTARG erfordert ein Argument."
        exit 1
      fi
      ;;
  esac
done
shift "$((OPTIND - 1))"
if [ "$#" -ne 0 ]; then
  echo "Error: unexpected argument: ${1}" >&2
  exit 2
fi






# Quote one path or command string for the remote login shell.

function execute_remote_background_command {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  local command=$1
  if [ -z "${command}" ]; then
    echo "Fehler: Kein Befehl zum Ausführen angegeben."
    return 1
  fi
  # Der Sender laeuft von SSH abgekoppelt (nohup), damit jeder Teil-Job nur
  # kurze SSH-Sitzungen braucht: dauerhaft offene Sitzungen wuerden bei vielen
  # Jobs das sshd-Limit MaxSessions (Standard 10) des ControlMasters reissen.
  # Ein Wrapper legt PID und Exit-Status (Bash pipefail, deckt auch nc ab) im
  # Statusverzeichnis ab; wait_for_jobs() fragt sie spaeter ab.
  ensure_remote_status_dir || return 1
  REMOTE_JOB_BASE="${REMOTE_STATUS_DIR}/job${#REMOTE_JOB_BASES[@]}-${CURRENT_REMOTE_PORT}"
  execute_remote_command "nohup setsid bash -c $(shell_quote "${REMOTE_JOB_WRAPPER}") ddpar-job $(shell_quote "${command}") $(shell_quote "${REMOTE_JOB_BASE}") < /dev/null > $(shell_quote "${REMOTE_JOB_BASE}.log") 2>&1 &"
}

# Wrapper fuer Remote-Pipelines: $1 = Pipeline, $2 = Basisname der Statusdateien.
# Der Exit-Status wird atomar (tmp + mv) geschrieben.
# shellcheck disable=SC2016 # wird erst auf dem Remote-Host ausgewertet
REMOTE_JOB_WRAPPER='echo "$$" > "$2.pid"; bash -o pipefail -c "$1"; rc=$?; echo "${rc}" > "$2.tmp" && mv -f "$2.tmp" "$2.rc"'
REMOTE_STATUS_DIR=""

# Legt einmal pro Lauf ein privates Statusverzeichnis auf dem Remote-Host an.
function ensure_remote_status_dir {
  [ -n "${REMOTE_STATUS_DIR}" ] && return 0
  REMOTE_STATUS_DIR=$(execute_remote_command "mktemp -d /tmp/ddpar-status.XXXXXX") || REMOTE_STATUS_DIR=""
  if [ -z "${REMOTE_STATUS_DIR}" ]; then
    echo "Fehler: Statusverzeichnis auf ${REMOTE_HOST} konnte nicht angelegt werden." >&2
    return 1
  fi
}

# Gibt "rc <n>", "running" oder "missing" fuer einen Remote-Job aus. Der zweite
# rc-Test faengt einen Job ab, der zwischen den ersten beiden Tests endet.

# Stop only process groups recorded in this run's private status directory.
# Earlier cleanup matched nc by its port to avoid killing unrelated shells;
# group ownership now lets us stop dd/gzip too without name-based matching.
function stop_remote_listeners {
  local base q
  for base in "${REMOTE_JOB_BASES[@]}"; do
    q=$(shell_quote "${base}")
    execute_remote_command "if [ ! -f ${q}.rc ] && [ -f ${q}.pid ]; then kill -TERM -- -\$(cat ${q}.pid) 2>/dev/null; printf '143\\n' > ${q}.rc; fi" || true
  done
}

function remove_remote_status_dir {
  [ -z "${REMOTE_STATUS_DIR}" ] && return 0
  execute_remote_command "rm -rf -- $(shell_quote "${REMOTE_STATUS_DIR}")" > /dev/null 2>&1
  REMOTE_STATUS_DIR=""
}


function remote_port_generation {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  REMOTE_PORT=$(( RANDOM % 55001 ))
  REMOTE_PORT=$(( REMOTE_PORT + 10000 ))
}

function check_remote_port_availability {
  local listeners
  listeners=$(execute_remote_command "ss -H -tln") || return 2
  if grep -qE ":${CURRENT_REMOTE_PORT}[^0-9]" <<< "${listeners}"; then return 1; fi
  return 0
}

function remote_restore_commands {
  [ "$DEBUG" -eq 1 ] && echo "[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen" >&2
  # Startet auf dem Remote-Host einen netcat-Sender, der die übergebene Quelle
  # (z.B. "dd if=...part") an den verbindenden lokalen Client liefert. Der
  # Port für die lokale Empfängerseite steht anschließend in CURRENT_REMOTE_PORT.
  local remote_input_cmd=$1

  if [ -z "${REMOTE_PORT}" ]; then
    remote_port_generation
  fi
  CURRENT_REMOTE_PORT=$((10000 + (REMOTE_PORT - 10000 + PART_NUM) % 32768))
  while true; do
    if check_remote_port_availability; then
      break
    else
      [ "$?" -eq 2 ] && return 1
      echo "Port ${CURRENT_REMOTE_PORT} on remote machine already in use, generate new port."
      remote_port_generation
      CURRENT_REMOTE_PORT=$((10000 + (REMOTE_PORT - 10000 + PART_NUM) % 32768))
    fi
  done

  echo "REMOTE COMMAND: ${remote_input_cmd} | nc -N -l ${CURRENT_REMOTE_PORT}"
  if ! execute_remote_background_command "${remote_input_cmd} | nc -N -l ${CURRENT_REMOTE_PORT}"; then
    return 1
  fi
  REMOTE_LISTENER_PORTS+=("${CURRENT_REMOTE_PORT}")
  register_remote_job "${REMOTE_JOB_BASE}" "Remote-Sender Port ${CURRENT_REMOTE_PORT}"

  MAX_ATTEMPTS=3
  SLEEP_INTERVAL=1
  ATTEMPT=1
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Checking if remote process is running on port ${CURRENT_REMOTE_PORT} (attempt $ATTEMPT)..."
    if execute_remote_command "ss -tuln | grep -qE :${CURRENT_REMOTE_PORT}[^0-9]"; then
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
}

# Verwaltung der parallelen Hintergrund-Jobs:
# Jeder gestartete Teil-Job wird mit PID und Beschreibung registriert, damit
# wait_for_jobs die Exit-Codes einzeln einsammeln kann. Ein nacktes "wait"
# würde Fehler einzelner Restore-Pipelines verschlucken.
JOB_PIDS=()
JOB_LABELS=()
REMOTE_LISTENER_PORTS=()
# Remote-Pipelines: Basisname ihrer Statusdateien im REMOTE_STATUS_DIR
REMOTE_JOB_BASES=()
REMOTE_JOB_LABELS=()

function register_job {
  JOB_PIDS+=("$1")
  JOB_LABELS+=("$2")
}

function register_remote_job {
  REMOTE_JOB_BASES+=("${1}")
  REMOTE_JOB_LABELS+=("${2}")
}

function wait_for_jobs {
  local failed=0
  local i rc
  for i in "${!JOB_PIDS[@]}"; do
    wait "${JOB_PIDS[$i]}"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "Fehler: ${JOB_LABELS[$i]} ist mit Exit-Code ${rc} fehlgeschlagen."
      failed=$((failed + 1))
    fi
  done
  if [ "${#JOB_PIDS[@]}" -ne "${NUM_JOBS}" ]; then
    echo "Fehler: Es wurde kein Restore-Job gestartet." >&2
    failed=$((failed + 1))
  fi
  # Nach einem Fehler (lokaler Job oder nicht gestarteter Teil) wartet ein
  # Remote-Sender eventuell ewig auf seinen Empfaenger -> nc dort beenden.
  if [ "${failed}" -gt 0 ] || [ "${INTERNAL_EXITCODE}" -ne 0 ]; then
    stop_remote_listeners "${REMOTE_LISTENER_PORTS[@]}"
  fi
  local state polls
  for i in "${!REMOTE_JOB_BASES[@]}"; do
    # Kein festes Zeitlimit; ist der Status nicht abrufbar, gilt der Job als
    # fehlgeschlagen.
    polls=0
    while true; do
      state=$(remote_job_state "${REMOTE_JOB_BASES[$i]}") || state="unreachable"
      [ "${state}" != "running" ] && break
      polls=$((polls + 1))
      [ $((polls % 120)) -eq 0 ] && echo "${REMOTE_JOB_LABELS[$i]} laeuft noch ..."
      sleep 0.5
    done
    case "${state}" in
      "rc 0") ;;
      "rc "*)
        echo "Fehler: ${REMOTE_JOB_LABELS[$i]} ist mit Exit-Code ${state#rc } fehlgeschlagen." >&2
        execute_remote_command "tail -n 5 -- $(shell_quote "${REMOTE_JOB_BASES[$i]}.log")" >&2 2>/dev/null
        failed=$((failed + 1))
        ;;
      *)
        echo "Fehler: Exit-Status von ${REMOTE_JOB_LABELS[$i]} ist nicht ermittelbar (${state})." >&2
        failed=$((failed + 1))
        ;;
    esac
  done
  remove_remote_status_dir
  REMOTE_JOB_BASES=()
  REMOTE_JOB_LABELS=()
  JOB_PIDS=()
  JOB_LABELS=()
  if [ $failed -gt 0 ]; then
    echo "Fehler: ${failed} parallele(r) Job(s) fehlgeschlagen. Die Wiederherstellung ist unvollständig!"
    INTERNAL_EXITCODE=1
    return 1
  fi
  echo "Alle parallelen Jobs erfolgreich beendet."
  return 0
}

trap ddpar_cancel INT TERM

function part_bytes {
  # Bytes, die Teil $1 enthält: normale Teile SPLIT_SIZE, der letzte Teil
  # zusätzlich den nicht gleichmäßig verteilbaren Rest; bei Backups kleiner
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

function restore_split_image {
  echo "Starte die Prozesse ..."
  if [ ! -b "${OUTPUT_FILE}" ]; then
    # conv=notrunc protects parallel workers, so truncate exactly once up front.
    truncate -s "${INPUT_SIZE}" -- "${OUTPUT_FILE}" || { INTERNAL_EXITCODE=1; return 1; }
    if [ "$SKIP_PREALLOC" -eq 1 ]; then
      echo "Vorab-Reservierung des Zielplatzes übersprungen (-P)."
    elif [ "${INPUT_SIZE}" -eq 0 ]; then
      : # fallocate rejects zero length; the empty file is already complete.
    elif ! command -v fallocate > /dev/null; then
      echo "Warnung: fallocate ist nicht verfügbar, Vorab-Reservierung wird übersprungen."
    else
      echo "fallocate -l ${INPUT_SIZE} $OUTPUT_FILE"
      if ! fallocate -l "${INPUT_SIZE}" "${OUTPUT_FILE}"; then
        echo "Fehler: Speicherplatz für ${OUTPUT_FILE} konnte nicht reserviert werden (fallocate). Mit -P kann die Reservierung übersprungen werden."
        INTERNAL_EXITCODE=1
        return 1
      fi
    fi
  fi

  local PART_NUM START COUNT_BYTES
  local dd_out
  for ((PART_NUM=0; PART_NUM<NUM_JOBS; PART_NUM++)); do
    START=$((PART_NUM * SPLIT_SIZE))
    COUNT_BYTES=$(part_bytes "${PART_NUM}")
    # Byte-genaue dd-Aufrufe (count_bytes/seek_bytes), damit auch nicht glatt
    # teilbare Backups funktionieren. Direkte Pipelines statt eval-Strings:
    # Pfade mit Leerzeichen o.ä. sind so ungefährlich.
    dd_out=(dd of="${OUTPUT_FILE}" bs="${BLOCKSIZEBYTES}" "iflag=fullblock,count_bytes" count="${COUNT_BYTES}" oflag=seek_bytes seek="${START}" conv=notrunc)
    if [ $REMOTE -eq 1 ] && [ -n "$COMPRESSION" ] && [ "$REMOTE_MODE" = "c" ]; then
      # Remote netcat restore mit Dekompression auf der Gegenseite (-r c): der
      # Remote-Host packt die .gz-Teile selbst aus und sendet die Rohdaten, hier
      # werden sie nur noch geschrieben. Das entlastet die lokale CPU, spart aber
      # keine Bandbreite (dafür siehe -r n).
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is remote (compressed, remote decompression)"
      fi
      if ! remote_restore_commands "gzip -dc -- $(shell_quote "${INPUT_FILES}${PART_NUM}.gz")"; then
        echo "Remote-Restore-Sender für Teil ${PART_NUM} konnte nicht gestartet werden."
        INTERNAL_EXITCODE=1
        break
      fi
      echo "nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT} </dev/null | ${dd_out[*]}"
      nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" </dev/null | ddpar_write_segment "${OUTPUT_FILE}" "${COUNT_BYTES}" "${START}" &
    elif [ $REMOTE -eq 1 ] && [ -n "$COMPRESSION" ]; then
      # Remote netcat restore mit lokaler Dekompression: der Remote-Host sendet
      # die .gz-Datei unverändert, zcat läuft auf DIESER Maschine. Über das Netz
      # geht nur der komprimierte Strom, die Remote-Seite benötigt kein gzip.
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is remote (compressed, local decompression)"
      fi
      if ! remote_restore_commands "dd if=$(shell_quote "${INPUT_FILES}${PART_NUM}.gz") bs=${BLOCKSIZEBYTES} iflag=fullblock"; then
        echo "Remote-Restore-Sender für Teil ${PART_NUM} konnte nicht gestartet werden."
        INTERNAL_EXITCODE=1
        break
      fi
      echo "nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT} </dev/null | zcat | ${dd_out[*]}"
      nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" </dev/null | zcat | ddpar_write_segment "${OUTPUT_FILE}" "${COUNT_BYTES}" "${START}" &
    elif [ $REMOTE -eq 1 ]; then
      # Remote netcat restore, unkomprimiert: Remote sendet, lokal wird empfangen und geschrieben
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is remote (uncompressed)"
      fi
      if ! remote_restore_commands "dd if=$(shell_quote "${INPUT_FILES}${PART_NUM}.part") bs=${BLOCKSIZEBYTES} iflag=fullblock"; then
        echo "Remote-Restore-Sender für Teil ${PART_NUM} konnte nicht gestartet werden."
        INTERNAL_EXITCODE=1
        break
      fi
      echo "nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT} </dev/null | ${dd_out[*]}"
      nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" </dev/null | ddpar_write_segment "${OUTPUT_FILE}" "${COUNT_BYTES}" "${START}" &
    elif [ -n "$COMPRESSION" ]; then
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is compressed"
      fi
      echo "zcat ${INPUT_FILES}${PART_NUM}.gz | ${dd_out[*]}"
      gzip -dc -- "${INPUT_FILES}${PART_NUM}.gz" | ddpar_write_segment "${OUTPUT_FILE}" "${COUNT_BYTES}" "${START}" &
    else
      if [ $PART_NUM -eq 0 ]; then
        echo "Source is uncompressed"
      fi
      echo "dd if=${INPUT_FILES}${PART_NUM}.part bs=${BLOCKSIZEBYTES} iflag=fullblock | ${dd_out[*]}"
      dd if="${INPUT_FILES}${PART_NUM}.part" bs="${BLOCKSIZEBYTES}" iflag=fullblock | ddpar_write_segment "${OUTPUT_FILE}" "${COUNT_BYTES}" "${START}" &
    fi
    register_job $! "Teil ${PART_NUM} (restore)"
  done
}


if [ -z "${INPUT:-}" ] || [ -z "${OUTPUT:-}" ]; then
  echo 'Error: input (-i) and output (-o) are required.' >&2
  exit 2
fi

# Create spinoff variables
INPUT_PATH=$(dirname -- "${INPUT}")
INPUT_FILE_BASENAME=$(basename -- "${INPUT}")
INPUT_FILES="${INPUT_PATH}/${INPUT_FILE_BASENAME}-"
#OUTPUT_PATH=/dev
#OUTPUT_FILE_BASENAME=sdi
#OUTPUT_FILE="${OUTPUT_PATH}/${OUTPUT_FILE_BASENAME}"
OUTPUT_FILE_TYPE="$(file -Lb -- "${OUTPUT}")"
METADATA_FILE="${INPUT_FILES}metadata.txt"

# Get parameters from metadata file (lokal oder remote)
if [ $REMOTE -eq 1 ]; then
  for cmd in ssh nc; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      echo "Fehler: Befehl $cmd ist lokal nicht verfügbar, wird aber für den Remote-Restore benötigt."
      exit 1
    fi
  done
  connect_ssh || exit 1
  METADATA_SRC=$(mktemp)
  execute_remote_command "cat -- $(shell_quote "${METADATA_FILE}")" > "${METADATA_SRC}" 2>/dev/null
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
ddpar_read_metadata "${METADATA_SRC}" || exit 1

if [ $REMOTE -eq 1 ] && [ "$REMOTE_MODE" = "c" ] && [ -z "$COMPRESSION" ]; then
  echo "[WARN] Remote-Modus 'c' bei unkomprimiertem Backup: es wird nichts dekomprimiert, die Übertragung entspricht Modus 'n'."
fi

# Komprimierte Backups werden im Remote-Modus "n" (und lokal) auf DIESER
# Maschine ausgepackt (local decompression); im Remote-Modus "c" übernimmt das
# der Remote-Host (remote decompression). zcat muss also auf der jeweils
# auspackenden Seite vorhanden sein.
if [ -n "$COMPRESSION" ]; then
  if [ $REMOTE -eq 1 ] && [ "$REMOTE_MODE" = "c" ]; then
    if ! execute_remote_command "command -v zcat > /dev/null 2>&1"; then
      echo "Fehler: Das Backup ist komprimiert und -r c verlangt zcat (gzip) auf ${REMOTE_HOST}, dort ist es nicht verfügbar."
      rm -f "$METADATA_SRC"
      close_ssh_connection
      exit 1
    fi
  elif ! command -v zcat > /dev/null 2>&1; then
    echo "Fehler: Das Backup ist komprimiert, aber zcat (gzip) ist lokal nicht verfügbar."
    if [ $REMOTE -eq 1 ]; then
      rm -f "$METADATA_SRC"
      close_ssh_connection
    fi
    exit 1
  fi
fi

# Leserechte auf die Teil-Dateien vorab prüfen, damit der Restore nicht erst
# mitten im parallelen Lauf an fehlenden Rechten scheitert (lokal; remote
# liest der Remote-Host die Teile).
# Check every part before touching the destination. In particular, dd treats
# early EOF as a successful read, so an uncompressed short part needs an
# explicit length check against its expected segment size.
for ((part=0; part<NUM_JOBS; part++)); do
  if [ -n "${COMPRESSION}" ]; then
    part_file="${INPUT_FILES}${part}.gz"
  else
    part_file="${INPUT_FILES}${part}.part"
  fi
  if [ "${REMOTE}" -eq 1 ]; then
    if [ -n "${COMPRESSION}" ]; then
      if [ "${REMOTE_MODE}" = c ]; then
        part_size=$(execute_remote_command "gzip -dc -- $(shell_quote "${part_file}") | wc -c") || exit 1
      else
        part_size=$(execute_remote_command "cat -- $(shell_quote "${part_file}")" | gzip -dc | wc -c) || exit 1
      fi
    else
      part_size=$(execute_remote_command "test -f $(shell_quote "${part_file}") && stat -Lc %s -- $(shell_quote "${part_file}")") || exit 1
    fi
    if [ "${part_size}" -ne "$(part_bytes "${part}")" ]; then
      echo "Error: remote part ${part_file} has an unexpected length." >&2
      exit 1
    fi
  else
    ddpar_verify_part "${part_file}" "$(part_bytes "${part}")" || exit 1
    if [ -e "${INPUT_FILES}${part}.sha256" ]; then
      expected=$(ddpar_checksum "${INPUT_FILES}${part}.sha256") || exit 1
      actual=$(ddpar_part_stream "${part_file}" | sha256sum | cut -d' ' -f1) || exit 1
      if [ "${expected}" != "${actual}" ]; then
        echo "Error: backup checksum mismatch: ${part_file}" >&2
        exit 1
      fi
    fi
  fi
done

# Überprüfung der erforderlichen Parameter
if [ -z "$INPUT_PATH" ] || [ -z "$INPUT_FILE_BASENAME" ] || [ -z "$OUTPUT" ]; then
  echo "Fehlende Parameter. Bitte geben Sie alle erforderlichen Parameter an."
  exit 1
fi

if [ -e "${OUTPUT}" ]; then
  # Determine the type of the output
  OUTPUT_FILE_TYPE=$(file -Lb -- "${OUTPUT}")
  # Use the appropriate command to determine destination types and sizes
  case "$OUTPUT_FILE_TYPE" in
    # Wenn OUTPUT_FILE ein Blockdevice ist, prüfen, ob OUTPUT_FILE groß genug ist.
    "block special"*)
      OUTPUT_SIZE=$(blockdev --getsize64 "${OUTPUT}")
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
      # Basename aus den Metadaten (FILE_NAME); Fallback: Basisname von -i
      OUTPUT_FILE="$OUTPUT/${FILE_NAME:-$INPUT_FILE_BASENAME}"
      ;;
    # Wenn OUTPUT eine Datei ist (die bereits exitiert), prüfen, ob genügend freier Speicherplatz vorhanden ist.
    *)
      OUTPUT_DIR=$(dirname -- "$OUTPUT")
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
  OUTPUT_DIR=$(dirname -- "$OUTPUT")
  OUTPUT_FILE="$OUTPUT"
  AVAILABLE_SPACE=$(df -B 1 "$OUTPUT_DIR" | awk 'NR==2{print $4}')
    if [ ! "$AVAILABLE_SPACE" -ge "$INPUT_SIZE" ]; then
      echo "Fehler: Nicht genügend Speicherplatz vorhanden für $INPUT_FILE_BASENAME in $OUTPUT_DIR ."
      exit 1
    fi
  if [ -w "$OUTPUT_DIR" ]; then
    : # Create the target only after confirmation and validation.
  else
    echo "Fehler: Kein Schreibzugriff auf das Verzeichnis $OUTPUT_DIR vorhanden."
    exit 1
  fi

fi

# Resolve the final destination, including symlinks, before preallocation.
if [ -e "${OUTPUT_FILE}" ]; then
  if [ ! -f "${OUTPUT_FILE}" ] && [ ! -b "${OUTPUT_FILE}" ]; then
    echo "Error: unsupported restore target: ${OUTPUT_FILE}" >&2
    exit 1
  fi
  OUTPUT_FILE_TYPE=$(file -Lb -- "${OUTPUT_FILE}") || exit 1
  if [ -b "${OUTPUT_FILE}" ]; then
    OUTPUT_SIZE=$(blockdev --getsize64 "${OUTPUT_FILE}") || exit 1
    [ "${OUTPUT_SIZE}" -ge "${INPUT_SIZE}" ] || exit 1
  fi
fi
if [ "${REMOTE}" -ne 1 ]; then
  for part_file in "${METADATA_FILE}" "${INPUT_FILES}"*.part "${INPUT_FILES}"*.gz "${INPUT_FILES}"*.sha256; do
    if [ "${OUTPUT_FILE}" -ef "${part_file}" ]; then
      echo "Error: restore target aliases the backup: ${part_file}" >&2
      exit 1
    fi
  done
fi

# Schreibrechte vorab prüfen, damit der Restore nicht erst mitten im
# parallelen Lauf an fehlenden Rechten scheitert.
if [ -e "$OUTPUT_FILE" ]; then
  if [ ! -w "$OUTPUT_FILE" ]; then
    echo "Fehler: Keine Schreibrechte auf $OUTPUT_FILE."
    exit 1
  fi
elif [ ! -w "$(dirname -- "$OUTPUT_FILE")" ]; then
  echo "Fehler: Keine Schreibrechte auf das Verzeichnis $(dirname -- "$OUTPUT_FILE")."
  exit 1
fi

echo "Nachfolgend werden die geteilten Dateien unter $INPUT_PATH/$INPUT_FILE_BASENAME nach $OUTPUT_FILE geschrieben."
if [ "$ASSUME_YES" -eq 1 ]; then
  echo "Sicherheitsabfrage übersprungen (-y). Beginning to restore ..."
  restore_split_image
else
  while true; do
    read -r -p "Möchten Sie fortfahren [y/N]? " choice || choice=n
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
wait_for_jobs

if [ $REMOTE -eq 1 ]; then
  rm -f "$METADATA_SRC"
  close_ssh_connection
fi

exit ${INTERNAL_EXITCODE}
