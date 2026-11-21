#!/bin/bash
#
# Compare segmented backups or clones against their source or destination.
# Version: 1.0.3 (2026-11-19)
# Flow: parse and validate inputs; hash each segment; report every job's status.

# Fehler in dd-/sha256sum-Pipelines sollen den Exit-Code der Pipeline
# bestimmen — so führt ein fehlgeschlagener Vergleich (sha256sum -c) zu
# einem Fehler-Exit des jeweiligen Teil-Jobs.
set -o pipefail
# Resolve symlinked entry points (e.g. /usr/local/bin/ddpar) to the install dir.
# shellcheck source=ddpar-common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/ddpar-common.sh" || exit 1

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
  echo "-h, --help      Zeigt diese Hilfemeldung an"
}




# Verwaltung der parallelen Vergleichs-Jobs:
# Jeder Teil-Vergleich wird mit PID und Beschreibung registriert, damit
# wait_for_jobs die Exit-Codes einzeln einsammeln kann. So endet das Skript
# mit Exit-Code != 0, sobald ein Segment nicht übereinstimmt.
JOB_PIDS=()
JOB_LABELS=()
# Exit codes of jobs already reaped by the MaxSessions throttle. A second wait
# on a reaped PID is not reliable across Bash versions (it may return 127).
JOB_RCS=()

function register_job {
  JOB_PIDS+=("$1")
  JOB_LABELS+=("$2")
}

function wait_for_jobs {
  local failed=0
  local i rc
  for i in "${!JOB_PIDS[@]}"; do
    if [ -n "${JOB_RCS[i]+set}" ]; then
      rc=${JOB_RCS[i]}
    else
      wait "${JOB_PIDS[$i]}"
      rc=$?
    fi
    if [ "${rc}" -ne 0 ]; then
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
  JOB_RCS=()
  if [ $failed -gt 0 ]; then
    echo "Prüfung FEHLGESCHLAGEN: ${failed} Segment(e) weichen ab oder konnten nicht gelesen werden."
    INTERNAL_EXITCODE=1
    return 1
  fi
  echo "Prüfung erfolgreich: Alle Segmente stimmen überein."
  return 0
}

trap ddpar_cancel INT TERM

# Keep at most four long-lived hash sessions below the default sshd
# MaxSessions limit; remember the reaped exit code for wait_for_jobs.
function throttle_remote_jobs {
  local idx=$(( ${1} - 4 ))
  if [ "${REMOTE}" -eq 1 ] && [ "${idx}" -ge 0 ]; then
    wait "${JOB_PIDS[idx]}"
    JOB_RCS[idx]=$?
  fi
  return 0
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
    throttle_remote_jobs "${i}"
    (
      local h_bak h_local expected part_file
      part_file="${BASE_FILES}${i}.part"
      [ -n "${COMPRESSION}" ] && part_file="${BASE_FILES}${i}.gz"
      if [ "${REMOTE}" -eq 1 ]; then
        expected=$(ddpar_remote_expected_checksum "${BASE_FILES}${i}.sha256") || exit 1
        h_bak=$(ddpar_remote_part_hash "${part_file}") || exit 1
      else
        ddpar_verify_part "${part_file}" "$(part_bytes "${i}")" || exit 1
        expected=$(ddpar_checksum "${BASE_FILES}${i}.sha256") || exit 1
        h_bak=$(ddpar_part_stream "${part_file}" | sha256sum | cut -d' ' -f1) || exit 1
      fi
      if [[ -n "${expected}" && "${h_bak}" != "${expected}" ]]; then
        echo "Segment ${i}: FAILED (backup checksum mismatch)" >&2
        exit 1
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

function check_cloned_image {
  # Vergleicht Quelle und Ziel eines Clones segmentweise und parallel.
  # Es existieren keine .sha256-Dateien, daher werden die Hashes beider
  # Seiten direkt berechnet und verglichen.
  local i
  for ((i=0; i<NUM_JOBS; i++)); do
    throttle_remote_jobs "${i}"
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

# Validate on the host that owns the path. Larger block devices may contain
# an image prefix, while a regular-file partner must have the exact length.
ddpar_check_partner_size() {
  local path="${1}" expected="${2}" actual
  if [ -b "${path}" ]; then
    actual=$(blockdev --getsize64 "${path}") || return 1
    [ "${actual}" -ge "${expected}" ] && return 0
  elif [ -f "${path}" ]; then
    actual=$(stat -Lc %s -- "${path}") || return 1
    [ "${actual}" -eq "${expected}" ] && return 0
  else
    echo "Error: unsupported comparison input: ${path}" >&2
    return 1
  fi
  echo "Error: FAILED comparison size for ${path}: ${actual} bytes, expected ${expected}." >&2
  return 1
}

# Normalize aliases while preserving literal option values.
OPTSTRING=":b:s:d:j:B:r:R:h"
ddpar_normalize_args "${OPTSTRING}" "$@"
set -- "${DDPAR_ARGS[@]}"
# Verwendung von getopts zur Verarbeitung der Optionen
while getopts "${OPTSTRING}" opt; do
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
      echo "Error: option -${OPTARG} requires an argument." >&2
      exit 2
      ;;
  esac
done
shift "$((OPTIND - 1))"
if [ "$#" -ne 0 ]; then
  echo "Error: unexpected argument: ${1}" >&2
  exit 2
fi

# A backup base is a prefix. Resolving it with realpath may follow an
# unrelated symlink sharing that name and select an entirely different backup.
BASE_PATH=${BASE_ARG:-}

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
  BASE_FILES="${BASE_PATH}-"
  METADATA_FILE="${BASE_FILES}metadata.txt"

  # Get parameters from metadata file (lokal oder remote)
  if [ $REMOTE -eq 1 ]; then
    META_SRC=$(mktemp) || exit 1
    ddpar_fetch_metadata "${METADATA_FILE}" "${META_SRC}" || exit 1
  else
    META_SRC="$METADATA_FILE"
    if [ ! -f "$META_SRC" ] || [ ! -r "$META_SRC" ]; then
      echo "Fehler: Metadatendatei $META_SRC existiert nicht oder ist nicht lesbar."
      exit 1
    fi
  fi
  ddpar_read_metadata "${META_SRC}" || exit 1
  [ "${REMOTE}" -eq 1 ] && rm -f -- "${META_SRC}"

  # Komprimierte Remote-Backups werden im Modus "n" lokal ausgepackt (local
  # decompression), im Modus "c" auf der Gegenseite. gzip muss also auf der
  # jeweils auspackenden Seite vorhanden sein.
  if [ $REMOTE -eq 1 ] && [ -n "$COMPRESSION" ]; then
    if [ "$REMOTE_MODE" = "c" ]; then
      if ! execute_remote_command "command -v gzip > /dev/null 2>&1"; then
        echo "Fehler: Das Backup ist komprimiert und -r c verlangt gzip auf ${REMOTE_HOST}, dort ist es nicht verfügbar."
        close_ssh_connection
        exit 1
      fi
    elif ! command -v gzip > /dev/null 2>&1; then
      echo "Fehler: Das Backup ist komprimiert, aber gzip ist lokal nicht verfügbar."
      close_ssh_connection
      exit 1
    fi
  fi

  if [ -n "${SOURCE}" ]; then
    ddpar_check_partner_size "${SOURCE}" "${INPUT_SIZE}" || exit 1
    check_backup_pair "${SOURCE}" source
  else
    ddpar_check_partner_size "${DESTINATION}" "${INPUT_SIZE}" || exit 1
    check_backup_pair "${DESTINATION}" destination
  fi
else
  if [ -b "${SOURCE}" ]; then
    INPUT_SIZE=$(blockdev --getsize64 "${SOURCE}") || exit 1
  elif [ -f "${SOURCE}" ]; then
    INPUT_SIZE=$(stat -Lc %s -- "${SOURCE}") || exit 1
  else
    echo "Error: unsupported comparison input: ${SOURCE}" >&2
    exit 1
  fi
  ddpar_uint "${INPUT_SIZE}" || exit 1
  if [ "${REMOTE}" -eq 1 ]; then
    execute_remote_command "$(declare -f ddpar_check_partner_size); ddpar_check_partner_size $(shell_quote "${DESTINATION}") ${INPUT_SIZE}" || exit 1
  else
    ddpar_check_partner_size "${DESTINATION}" "${INPUT_SIZE}" || exit 1
  fi
  # Gleiche Aufteilung wie beim Clone-Vorgang (ddpar.sh size_calculation):
  # SPLIT_SIZE auf Blockgröße abgerundet, das letzte Segment prüft den Rest.
  if ! [[ "${NUM_JOBS}" =~ ^[1-9][0-9]*$ && "${BLOCKSIZEBYTES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Fehler: -j und -B müssen positive ganze Zahlen sein." >&2
    exit 2
  fi
  ddpar_geometry || exit 2
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
