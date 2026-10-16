#!/bin/bash
#
# Compare segmented backups or clones against their source or destination.
# Version: 1.0.1 (2026-10-17)
# Flow: parse and validate inputs; hash each segment; report every job's status.

# Fehler in dd-/sha256sum-Pipelines sollen den Exit-Code der Pipeline
# bestimmen — so führt ein fehlgeschlagener Vergleich (sha256sum -c) zu
# einem Fehler-Exit des jeweiligen Teil-Jobs.
set -o pipefail
# shellcheck source=ddpar-common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ddpar-common.sh" || exit 1

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
# Remote-Modus: "n" = Dekompression komprimierter Backup-Teile auf DIESER
# Maschine, "c" = Dekompression auf der Remote-Maschine
REMOTE_MODE="n"
REMOTE_HOST=""

DEBUG=0

function show_help {
  SCRIPT_NAME=$(basename -- "$0")
  echo "$SCRIPT_NAME - Verify consistency of source, backup or destination."
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-b PATH         Der Basisname (opt. mit Pfad) des geteilten Abbildes"
  echo "-s PATH         Source to compare against"
  echo "-d PATH         Destination to compare against"
  echo "-j NUM          Anzahl der Jobs für den Clone-Check (Default: 4, nur ohne -b)"
  echo "-B NUM          Blockgröße in Bytes für den Clone-Check (Default: 1048576, nur ohne -b)"
  echo "-r [nc]         Remote-Check über SSH. Die gesicherte/geklonte Seite (-b bzw. bei"
  echo "                Clone-Check -d) liegt auf dem Remote-Host. Komprimierte Backups"
  echo "                werden unterstützt:"
  echo "                  n (Default): die .gz-Teile werden über SSH geholt und lokal"
  echo "                    ausgepackt (local decompression, kein gzip auf der Gegenseite)"
  echo "                  c: die Gegenseite packt selbst aus und hasht, es geht nur der"
  echo "                    SHA256-Hash über SSH; dort wird gzip benötigt"
  echo "-R user@host    Angabe des Remote-Host"
  echo "DDPAR_NETWORK_TIMEOUT: netcat inactivity timeout in seconds (default: 300)."
  echo "-h, --help      Zeigt diese Hilfemeldung an"
}





# Quote a filename for the remote login shell before building a command.


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
  if [ "${#JOB_PIDS[@]}" -ne "${NUM_JOBS}" ]; then
    echo "Fehler: Es wurden keine Segmente geprüft." >&2
    failed=$((failed + 1))
  fi
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

trap ddpar_cancel INT TERM

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
  dd if="$f" bs="$BLOCKSIZEBYTES" "iflag=fullblock,count_bytes,skip_bytes" count="$(part_bytes "$idx")" skip="$start" status=none | sha256sum | cut -d' ' -f1
}

function remote_seg_hash {
  # $1 = Datei/Device (auf Remote-Host), $2 = Segment-Index. Liefert SHA256 des Segments.
  local f=$1 idx=$2
  local start=$((idx * SPLIT_SIZE))
  execute_remote_command "dd if=$(shell_quote "${f}") bs=$BLOCKSIZEBYTES iflag=fullblock,count_bytes,skip_bytes count=$(part_bytes "$idx") skip=$start status=none | sha256sum" | cut -d' ' -f1
}

function remote_part_hash {
  # $1 = Segment-Index. Liefert den SHA256 der Rohdaten des Segments, das auf
  # dem Remote-Host als Teil-Datei liegt.
  # - unkomprimiert: sha256sum läuft direkt auf dem Remote-Host, es gehen nur
  #   der Hash über die Leitung
  # - komprimiert: die .gz-Datei wird über SSH geholt und LOKAL ausgepackt
  #   (local decompression), der Remote-Host benötigt dafür kein gzip
  # - komprimiert mit -r c: zcat und sha256sum laufen auf dem Remote-Host
  #   (remote decompression), auch hier geht nur der Hash über die Leitung
  local idx=$1
  if [ -n "$COMPRESSION" ]; then
    if [ "$REMOTE_MODE" = "c" ]; then
      execute_remote_command "zcat $(shell_quote "${BASE_FILES}${idx}.gz") | sha256sum" | cut -d' ' -f1
    else
      execute_remote_command "cat -- $(shell_quote "${BASE_FILES}${idx}.gz")" | zcat | sha256sum | cut -d' ' -f1
    fi
  else
    execute_remote_command "sha256sum -- $(shell_quote "${BASE_FILES}${idx}.part")" | cut -d' ' -f1
  fi
}

function require_sha256_files {
  # Prüft vorab, ob das Backup mit Checksummen-Dateien (-s) erstellt wurde.
  # Ohne diese Prüfung liefe sha256sum -c gegen fehlende Dateien und
  # produzierte pro Segment nur eine verwirrende Fehlermeldung.
  local i
  for ((i=0; i<NUM_JOBS; i++)); do
    if [ ! -f "${BASE_FILES}${i}.sha256" ]; then
      echo "Fehler: ${BASE_FILES}${i}.sha256 fehlt. Das Backup wurde ohne Checksummen (-s) erstellt oder ist unvollständig."
      exit 1
    fi
  done
}

# Compare the actual backup bytes as well as any stored digest. Paths never
# enter sed expressions or checksum filenames, so punctuation remains data.
function check_backup_pair {
  local local_file="${1}" label="${2}" i
  [ "${REMOTE}" -ne 1 ] && require_sha256_files
  for ((i=0; i<NUM_JOBS; i++)); do
    # Keep long-lived hash sessions below the default sshd MaxSessions limit.
    if [ "${REMOTE}" -eq 1 ] && [ "${i}" -ge 4 ]; then wait "${JOB_PIDS[i-4]}" || true; fi
    (
      local h_bak h_local expected part_file
      if [ "${REMOTE}" -eq 1 ]; then
        h_bak=$(remote_part_hash "${i}") || exit 1
      else
        part_file="${BASE_FILES}${i}.part"
        [ -n "${COMPRESSION}" ] && part_file="${BASE_FILES}${i}.gz"
        ddpar_verify_part "${part_file}" "$(part_bytes "${i}")" || exit 1
        expected=$(ddpar_checksum "${BASE_FILES}${i}.sha256") || exit 1
        h_bak=$(ddpar_part_stream "${part_file}" | sha256sum | cut -d' ' -f1) || exit 1
        if [ "${h_bak}" != "${expected}" ]; then
          echo "Segment ${i}: FAILED (backup checksum mismatch)" >&2
          exit 1
        fi
      fi
      h_local=$(local_seg_hash "${local_file}" "${i}") || exit 1
      if [ "${h_bak}" != "${h_local}" ]; then
        echo "Segment ${i}: FAILED MISMATCH (backup=${h_bak}, ${label}=${h_local})" >&2
        exit 1
      fi
      echo "Segment ${i}: OK (${h_bak})"
    ) &
    register_job $! "Segment ${i} (${label}-check)"
  done
}

function check_restored_image {
  check_backup_pair "${OUTPUT_FILE}" destination
}

function check_backuped_image {
  check_backup_pair "${INPUT_FILE}" source
}

function check_cloned_image {
  # Vergleicht Quelle und Ziel eines Clones segmentweise und parallel.
  # Es existieren keine .sha256-Dateien, daher werden die Hashes beider
  # Seiten direkt berechnet und verglichen.
  # The segment hashes stop at the source size, so reject extra bytes in a
  # regular target file before comparing the segments.
  if [[ "${OUTPUT_FILE_TYPE}" != "block special"* ]]; then
    if [ "${REMOTE}" -eq 1 ]; then
      target_size=$(execute_remote_command "stat -Lc %s -- $(shell_quote "${DESTINATION}")") || return 1
    else
      target_size=$(stat -Lc %s -- "${DESTINATION}") || return 1
    fi
    if [ "${target_size}" -ne "${INPUT_SIZE}" ]; then
      echo "Fehler: Zieldatei hat ${target_size} Bytes, Quelle ${INPUT_SIZE} Bytes." >&2
      INTERNAL_EXITCODE=1
      return 1
    fi
  fi
  for ((i=0; i<NUM_JOBS; i++)); do
    # Keep long-lived hash sessions below the default sshd MaxSessions limit.
    if [ "${REMOTE}" -eq 1 ] && [ "${i}" -ge 4 ]; then wait "${JOB_PIDS[i-4]}" || true; fi
    (
      HASH_SRC=$(local_seg_hash "$SOURCE" "$i") || exit 1
      if [ $REMOTE -eq 1 ]; then
        # Geklontes Ziel liegt auf dem Remote-Host
        HASH_DST=$(remote_seg_hash "$DESTINATION" "$i") || exit 1
      else
        HASH_DST=$(local_seg_hash "$DESTINATION" "$i") || exit 1
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

# Normalize aliases while preserving literal option values.
ddpar_normalize_args "$@"
set -- "${DDPAR_ARGS[@]}"
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
      # Der Remote-Check überträgt keine Nutzdaten über netcat. Relevant ist der
      # Modus nur für komprimierte Backups: "n" holt die .gz-Teile über SSH und
      # packt sie lokal aus, "c" lässt die Gegenseite auspacken und hashen.
      case "${OPTARG}" in
        n|"") REMOTE_MODE="n";;
        c)    REMOTE_MODE="c";;
        l) echo "Error: unsupported remote mode l." >&2; exit 2;;
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

# Basis-Pfad auflösen: bei Remote nicht via realpath (Pfad liegt auf dem Remote-Host)
if [ -n "$BASE_ARG" ]; then
  if [ $REMOTE -eq 1 ]; then
    BASE_PATH=$(dirname -- "$BASE_ARG")
    BASE_FILE_NAME=$(basename -- "$BASE_ARG")
  else
    BASE_PATH=$(dirname -- "$(realpath -- "${BASE_ARG}")")
    BASE_FILE_NAME=$(basename -- "$(realpath -- "${BASE_ARG}")")
  fi
  echo "Set BASE_PATH=${BASE_PATH}"
  echo "Set BASE_FILE_NAME=${BASE_FILE_NAME}"
fi

# Bei Remote-Check früh die SSH-Verbindung aufbauen
if [ $REMOTE -eq 1 ]; then
  connect_ssh || exit 1
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
  echo "Fehler: Genau zwei von -s, -b und -d sind erforderlich." >&2
  exit 2
fi

# Create spinoff variables
if [ -n "${BASE_PATH}" ]; then
  BASE_FILES="${BASE_PATH}/${BASE_FILE_NAME}-"
  METADATA_FILE="${BASE_FILES}metadata.txt"

  # Get parameters from metadata file (lokal oder remote)
  if [ $REMOTE -eq 1 ]; then
    META_SRC=$(mktemp)
    execute_remote_command "cat -- $(shell_quote "${METADATA_FILE}")" > "$META_SRC" 2>/dev/null
    if [ ! -s "$META_SRC" ]; then
      echo "Die Metadatendatei $METADATA_FILE auf $REMOTE_HOST existiert nicht oder ist leer."
      rm -f "$META_SRC"
      close_ssh_connection
      exit 1
    fi
  else
    META_SRC="$METADATA_FILE"
    if [ ! -r "$META_SRC" ]; then
      echo "Fehler: Metadatendatei $META_SRC existiert nicht oder ist nicht lesbar."
      exit 1
    fi
  fi
  ddpar_read_metadata "${META_SRC}" || exit 1
  [ "${REMOTE}" -eq 1 ] && rm -f -- "${META_SRC}"

  # Komprimierte Remote-Backups werden im Modus "n" lokal ausgepackt (local
  # decompression), im Modus "c" auf der Gegenseite. zcat muss also auf der
  # jeweils auspackenden Seite vorhanden sein.
  if [ $REMOTE -eq 1 ] && [ -n "$COMPRESSION" ]; then
    if [ "$REMOTE_MODE" = "c" ]; then
      if ! execute_remote_command "command -v zcat > /dev/null 2>&1"; then
        echo "Fehler: Das Backup ist komprimiert und -r c verlangt zcat (gzip) auf ${REMOTE_HOST}, dort ist es nicht verfügbar."
        close_ssh_connection
        exit 1
      fi
    elif ! command -v zcat > /dev/null 2>&1; then
      echo "Fehler: Das Backup ist komprimiert, aber zcat (gzip) ist lokal nicht verfügbar."
      close_ssh_connection
      exit 1
    fi
  fi

  # Debug Info:
  printf '%s\n' "${BASE_PATH}"
  printf '%s\n' "${BASE_FILE_NAME}"
  printf '%s\n' "${BASE_FILES}*"
fi
if [ -n "$SOURCE" ]; then
  # Leserechte vorab prüfen, damit die Prüfung nicht erst mitten im
  # parallelen Lauf an fehlenden Rechten scheitert.
  if [ ! -r "$SOURCE" ]; then
    echo "Fehler: Quelle $SOURCE existiert nicht oder ist nicht lesbar."
    exit 1
  fi
  INPUT_FILE=$SOURCE
  INPUT_FILE_TYPE="$(file -Lb -- "${SOURCE}")"
fi
if [ -n "$DESTINATION" ]; then
  OUTPUT_FILE=$DESTINATION
  # Beim Remote-Clone-Check (kein BASE_PATH) liegt das Ziel remote -> file -b nicht lokal aufrufen
  if [ $REMOTE -eq 1 ] && [ -z "${BASE_PATH}" ]; then
    OUTPUT_FILE_TYPE=$(execute_remote_command "file -Lb -- $(shell_quote "${DESTINATION}")")
  else
    if [ ! -r "$DESTINATION" ]; then
      echo "Fehler: Ziel $DESTINATION existiert nicht oder ist nicht lesbar."
      exit 1
    fi
    OUTPUT_FILE_TYPE="$(file -Lb -- "${DESTINATION}")"
  fi
fi


# Metadata describes the entire input. Refuse shorter or longer regular
# partners even if all compared prefixes would have matched.
for partner in "${SOURCE:-}" "${DESTINATION:-}"; do
  [ -z "${partner}" ] && continue
  if [ "${REMOTE}" -eq 1 ] && [ -z "${BASE_PATH}" ] && [ "${partner}" = "${DESTINATION:-}" ]; then continue; fi
  if [ ! -f "${partner}" ] && [ ! -b "${partner}" ]; then
    echo "Error: unsupported comparison input: ${partner}" >&2
    exit 1
  fi
  if [ -n "${BASE_PATH}" ]; then
    if [ -b "${partner}" ]; then
      partner_size=$(blockdev --getsize64 "${partner}") || exit 1
      [ "${partner_size}" -ge "${INPUT_SIZE}" ] || exit 1
    else
      partner_size=$(stat -Lc %s -- "${partner}") || exit 1
      if [ "${partner_size}" -ne "${INPUT_SIZE}" ]; then
        echo 'Error: FAILED comparison size differs from backup metadata.' >&2
        exit 1
      fi
    fi
  fi
done

# Old Debug Info, can be removed
#echo "BASE_FILE_TYPE: ${BASE_FILE_TYPE}"
#echo "DESTINATION: $DESTINATION"
#echo "OUTPUT_FILE: ${OUTPUT_FILE}"
#echo "OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"

if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "Comparing Source $SOURCE with $BASE_PATH ..."
fi

# Check if only $SOURCE and $BASE_PATH are set
if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Base Path $BASE_PATH ..."

  echo "Beginning to check ..."
  check_backuped_image
fi

# Check if only $BASE_PATH and $DESTINATION are set
if [ -z "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Base Path $BASE_PATH with Destination $DESTINATION ..."

  echo "Beginning to check ..."
  check_restored_image

fi

# Check if only $SOURCE and $DESTINATION are set (Clone-Check)
if [ -n "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Destination $DESTINATION ..."

  # Größe der Quelle bestimmen (kein Metadatenfile vorhanden)
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    INPUT_SIZE=$(blockdev --getsize64 "$SOURCE")
  else
    INPUT_SIZE=$(stat -Lc %s "$SOURCE")
  fi
  # Gleiche Aufteilung wie beim Clone-Vorgang (ddpar.sh size_calculation):
  # SPLIT_SIZE auf Blockgröße abgerundet, das letzte Segment prüft den Rest.
  if ! [[ "${NUM_JOBS}" =~ ^[1-9][0-9]*$ && "${BLOCKSIZEBYTES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Fehler: -j und -B müssen positive ganze Zahlen sein." >&2
    exit 2
  fi
  ddpar_geometry || exit 2
  ddpar_uint "${INPUT_SIZE}" || exit 1
  SPLIT_SIZE=$(( (INPUT_SIZE / NUM_JOBS / BLOCKSIZEBYTES) * BLOCKSIZEBYTES ))
  [ "$SPLIT_SIZE" -eq 0 ] && SPLIT_SIZE=$BLOCKSIZEBYTES

  if [ "${NUM_JOBS}" -gt "$((9223372036854775807 / SPLIT_SIZE))" ]; then
    echo 'Error: segment offsets exceed the supported range.' >&2
    exit 2
  fi
  echo "Beginning to check ..."
  check_cloned_image || INTERNAL_EXITCODE=1
fi


wait_for_jobs

if [ $REMOTE -eq 1 ]; then
  close_ssh_connection
fi

exit ${INTERNAL_EXITCODE}
