#!/bin/bash
#
# Clone or back up files and block devices in parallel segments.
# Version: 1.0.1 (2026-10-17)
# Flow: validate options and endpoints; calculate segments; run local or remote
# workers; collect every worker's result before reporting success.

# Fehler in dd-/nc-Pipelines sollen den Exit-Code der Pipeline bestimmen,
# sonst zählt nur der letzte Befehl (z.B. ein erfolgreiches dd of=...).
set -o pipefail
# shellcheck source=ddpar-common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ddpar-common.sh" || exit 1

# Standardwerte für die Parameter
INPUT_FILE=""
OUTPUT_PATH=""
MODE="clone"
NUM_JOBS="4"
BLOCKSIZEBYTES="1048576"
COMPRESSION=${COMPRESSION:-0}
CHECKSUM=${CHECKSUM:-0}
REMOTE=0
# Remote-Modus: "n" = netcat, [De]Kompression (falls -c) auf DIESER Maschine,
# "c" = netcat, [De]Kompression auf der Remote-Maschine
REMOTE_MODE="n"
#SSH_SOCKET_PATH="/tmp/ssh_mux_%n_%p_%r"

INTERNAL_EXITCODE=0
DEBUG=0


# Hilfemeldung anzeigen
function show_help {
  SCRIPT_NAME=$(basename -- "$0")
  echo "$SCRIPT_NAME - Ein Bash-Skript zum parallelen Klonen oder Sichern von Blockgeräten oder großen Dateien"
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-i FILE|DEVICE          Die Eingabedatei"
  echo "-o FILE|DEVICE|PATH     Der Ausgabepfad"
  echo "-m clone|backup         Ziel des Vorgangs (Default: clone)"
  echo "-j NUM                  Die Anzahl der Jobs (Default: 4)"
  echo "-b NUM                  Die Blockgröße in Bytes (Default: 1048576 Bytes (1 MiB))"
  echo "-n NAME                 Eigener Basisname der Backup-Dateien (Default: Basename der Eingabe, nur -m backup)"
  echo "-c                      Komprimierung anfordern, Kompressionslevel zur Zeit nicht einstellbar (Default: -6)"
  echo "                        Mit -r n wird lokal komprimiert, es geht nur der komprimierte Strom über das Netz"
  echo "                        Mit -r c läuft gzip auf der Remote-Maschine (siehe Remote-Optionen)"
  echo "-s                      Checksumme der einzelnen Teile erstellen"
  echo "-f                      Force - ignore Probleme und erzwinge den Vorgang"
  echo "-r [lnc]                Remote-Verbindung, nur SSH möglich. Remote-Optionen: siehe unten"
  echo "-R user@host            Angabe des Remote-Host"
  echo "-h, --help              Diese Hilfe anzeigen"
  echo "DDPAR_NETWORK_TIMEOUT: netcat inactivity timeout in seconds (default: 300)."
  echo "-d                      Debug Modus"
  echo ""
  echo "Remote-Optionen:"
  echo "n: Standardeinstellung, No encryption, Verbindungsaufbau verschlüsselt (SSH),"
  echo "   Datenübertragung unverschlüsselt über netcat (nur in vertrauenswürdigen Netzen verwenden!)"
  echo "   Zusammen mit -c wird lokal komprimiert (die Remote-Seite benötigt kein gzip)"
  echo "l: GEPLANT, noch nicht implementiert: Übertragung vollständig verschlüsselt"
  echo "c: Wie n, aber [De]Kompression auf der Remote-Maschine (dort wird gzip benötigt):"
  echo "   -m backup -c: die Rohdaten gehen über netcat, die Gegenseite komprimiert sie in die .gz-Teile"
  echo "   -m clone  -c: lokal wird komprimiert, die Gegenseite dekomprimiert vor dem Schreiben"
  echo "                 (damit ist -c im Clone-Modus nur mit -r c möglich)"
}

function option_analysis {
  # Normalize aliases while preserving literal option values.
  ddpar_normalize_args "$@"
  set -- "${DDPAR_ARGS[@]}"
  # Verwendung von getopts zur Verarbeitung der Optionen
  echo "Analysiere gegebene Optionen \"$*\""
  while getopts ":i:o:m:j:b:n:r::R:csfhd" opt; do
    case $opt in
      i) INPUT="${OPTARG}";;
      o) OUTPUT="${OPTARG}";;
      m) MODE="${OPTARG}";;
      j) NUM_JOBS="${OPTARG}";;
      b) BLOCKSIZEBYTES="${OPTARG}";;
      n)
        if [[ "${OPTARG}" == */* ]]; then
          echo -e "${ERRORCOLOR}Ungültiger Basisname '${OPTARG}': darf keinen Schrägstrich enthalten.${NOCOLOR}"
          exit 1
        fi
        BASE_NAME="${OPTARG}"
        ;;
      c)
	    COMPRESSION=1
		echo "COMPRESSION enabled."
        if [ -n "${OPTARG}" ]; then
          COMPRESSION_LEVEL="${OPTARG}"
		  echo "COMPRESSION_LEVEL is set to ${OPTARG}"
        else
		  echo "COMPRESSION_LEVEL defaults to -6"
          COMPRESSION_LEVEL="6"
        fi
        ;;
	  d)
	    DEBUG=1
		set -x
		#PS4="${SETXCOLOR}>> ${LINENO}: ${NOCOLOR}"
		#PS4="${SETXCOLOR} ${NOCOLOR}"
		PS4="${SETXCOLOR}$(printf "%*s" "${SHLVL}" "" | tr " " "+") ${NOCOLOR}"
		echo -e "${WARNCOLOR}[WARN] DEBUG mode enabled, passwords get printed as clear text!${NOCOLOR}"
		;;
	  s)
        CHECKSUM=1
        ;;
      f)
        FORCE=1
        ;;
      r)
        REMOTE=1
        # "n" = netcat, [De]Kompression lokal; "c" = netcat, [De]Kompression
        # auf der Remote-Maschine. "l" (Datenkanal verschlüsselt) ist geplant —
        # Reject the unsupported encrypted mode before any transfer.
        case "${OPTARG}" in
          n|"") REMOTE_MODE="n";;
          c)    REMOTE_MODE="c";;
          l)
            echo "Error: encrypted mode l is not implemented; refusing plaintext transfer." >&2
            exit 2
            ;;
          -*)
            # "-r" ohne Modus: getopts hat bereits die nächste Option als
            # Argument gelesen. OPTIND zurücksetzen, damit sie regulär
            # verarbeitet wird, und den Default-Modus verwenden.
            REMOTE_MODE="n"
            OPTIND=$((OPTIND - 1))
            ;;
          *)
            echo -e "${ERRORCOLOR}Ungültiger Remote-Modus '${OPTARG}'. Gültige Angaben: l|n|c${NOCOLOR}"
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
      \?) echo "Ungültige Option: -${OPTARG}"; show_help; exit 1;;
      :)
        # -r darf ohne Argument stehen (Default-Modus n), alle anderen Optionen nicht
        if [ "${OPTARG}" = "r" ]; then
          REMOTE=1
          REMOTE_MODE="n"
        else
          echo -e "${ERRORCOLOR}Option -${OPTARG} erfordert ein Argument.${NOCOLOR}"
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
  ddpar_geometry || { echo 'Fehler: -j und -b müssen positive ganze Zahlen sein.' >&2; exit 2; }
  case "${MODE}" in
    clone|backup) ;;
    *) echo "Error: invalid mode: ${MODE}" >&2; exit 2 ;;
  esac
  case "${COMPRESSION}" in
    0|1) ;;
    *) echo 'Error: COMPRESSION must be 0 or 1.' >&2; exit 2 ;;
  esac
  case "${CHECKSUM}" in
    0|1) ;;
    *) echo 'Error: CHECKSUM must be 0 or 1.' >&2; exit 2 ;;
  esac
  COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
  if ! [[ "${COMPRESSION_LEVEL}" =~ ^[1-9]$ ]]; then
    echo 'Error: COMPRESSION_LEVEL must be between 1 and 9.' >&2
    exit 2
  fi
  # Überprüfung der erforderlichen Parameter
  if [ -z "${INPUT}" ] || [ -z "${OUTPUT}" ] ; then
    echo -e "${ERRORCOLOR}Fehlende Parameter. Bitte geben Sie alle erforderlichen Parameter --input und --output an.${NOCOLOR}"
    exit 1
  fi

  # Modus "c" ohne -c hat nichts zu komprimieren und verhält sich wie "n"
  if [ "${REMOTE}" -eq 1 ] && [ "${REMOTE_MODE}" = "c" ] && [ "${COMPRESSION}" -ne 1 ]; then
    echo -e "${WARNCOLOR}[WARN] Remote-Modus 'c' ohne -c: es wird nichts komprimiert, die Übertragung entspricht Modus 'n'.${NOCOLOR}"
  fi
  }

function remote_compression_active {
	# Wahr, wenn [De]Kompression auf der Remote-Maschine läuft (-r c zusammen mit -c).
	# Backup: die Rohdaten gehen über netcat, die Gegenseite komprimiert.
	# Clone:  lokal wird komprimiert, die Gegenseite dekomprimiert vor dem Schreiben.
	[ "${REMOTE}" -eq 1 ] && [ "${REMOTE_MODE}" = "c" ] && [ "${COMPRESSION}" -eq 1 ]
}

function set_colors {
	# check if stdout is a terminal...
	if test -t 1; then
        # see if it supports colors...
        ncolors=$(tput colors)

        if test -n "$ncolors" && test "${ncolors}" -ge 8; then
			# I* heißt "intense"
			# B* heißt "bold"
			# BI* heißt "bold intense"
			# Farbdefinitionen
			WHITE='\033[0;37m'
			IBLACK='\033[0;90m'
			IGREEN='\033[0;92m'
			IPURPLE='\033[0;95m'
			IRED='\033[0;91m'
			IYELLOW='\033[0;93m'
			BIGREEN='\033[1;92m'
			BIRED='\033[1;91m'
			BIYELLOW='\033[1;93m'
			NOCOLOR='\033[0m'
			# Eventfarben
			DEBUGCOLOR=${IRED}
			ERRORCOLOR=${BIRED}
			WARNCOLOR=${IPURPLE}
			INFOCOLOR=${IBLACK}
			SUCCESSCOLOR=${IGREEN}
			REQUESTCOLOR=${IYELLOW}
			SETXCOLOR=${IBLACK}
		fi
	fi
}




# Quote one argument for the remote login shell, without interpreting its data.

# Run a command locally as an argv array or remotely with quoted arguments.
function execute_command {
	local command="" arg
	if [ "${REMOTE}" -eq 1 ]; then
		for arg in "$@"; do
			command+="$(shell_quote "${arg}") "
		done
		execute_remote_command "${command}"
	else
		"$@"
	fi
}


function execute_remote_background_command {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    local command=$1

    if [ -z "${command}" ]; then
        echo -e "${ERRORCOLOR}Fehler: Kein Befehl zum Ausführen angegeben.${NOCOLOR}"
        return 1
    fi

    # Die Pipeline laeuft von SSH abgekoppelt (nohup), damit jeder Teil-Job nur
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
		echo -e "${ERRORCOLOR}Fehler: Statusverzeichnis auf ${REMOTE_HOST} konnte nicht angelegt werden.${NOCOLOR}" >&2
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


function check_remote_commands_availability {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion check_remote_commands_availability aufgerufen${NOCOLOR}" >&2
    local commands=("bash" "dd" "nc" "df" "tee" "blockdev" "stat" "ss" "setsid" "mktemp" "cat" "mv" "rm" "sed" "wc" "file" "truncate")

    # Im Modus "n" wird gzip bewusst NICHT verlangt: dort wird lokal komprimiert
    # (local compression), die Remote-Seite schreibt den fertigen gzip-Strom
    # nur noch per dd in die .gz-Datei. Im Modus "c" läuft gzip dagegen auf der
    # Gegenseite (Backup: komprimieren, Clone: dekomprimieren).
    if remote_compression_active; then
        commands+=("gzip")
    fi

    if [ "$CHECKSUM" -eq 1 ]; then
        commands+=("sha256sum")
    fi

    for cmd in "${commands[@]}"; do
        if ! execute_remote_command "command -v \"$cmd\"" &> /dev/null; then
            echo -e "${ERRORCOLOR}Befehl $cmd ist nicht verfügbar.${NOCOLOR}"
            return 1  # Exit-Code 1, wenn mindestens ein Befehl nicht verfügbar ist
        fi
    done
    
    return 0  # Exit-Code 0, wenn alle Befehle verfügbar sind
}

function check_commands_availability {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    local commands=("dd" "df" "tee" "blockdev" "stat" "file" "mktemp" "wc" "cat" "truncate" "rm" "sed" "awk")  # Liste der zu überprüfenden Befehle

    if [ "$REMOTE" -eq 1 ]; then
        commands+=("nc" "ssh")
    fi

    # Beim Remote-Backup im Modus "c" komprimiert die Gegenseite, lokal wird
    # dafür kein gzip gebraucht. Im Clone-Modus "c" komprimiert dagegen DIESE
    # Maschine (die Gegenseite dekomprimiert), gzip ist also weiterhin nötig.
    if [ "$COMPRESSION" -eq 1 ] && ! { remote_compression_active && [ "$MODE" = "backup" ]; }; then
        commands+=("gzip")
    fi

    if [ "$CHECKSUM" -eq 1 ]; then
        commands+=("sha256sum")
    fi
    
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${ERRORCOLOR}Befehl $cmd ist nicht verfügbar.${NOCOLOR}"
            return 1  # Exit-Code 1, wenn mindestens ein Befehl nicht verfügbar ist
        fi
    done
    
    return 0  # Exit-Code 0, wenn alle Befehle verfügbar sind
}

function check_input_access {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Leserechte vorab prüfen, damit der Vorgang nicht erst mitten im
	# parallelen Lauf an fehlenden Rechten scheitert.
	if [ ! -e "${INPUT}" ]; then
		echo -e "${ERRORCOLOR}Fehler: Eingabe ${INPUT} existiert nicht.${NOCOLOR}"
		exit 1
	fi
	if [ ! -r "${INPUT}" ]; then
		echo -e "${ERRORCOLOR}Fehler: Keine Leserechte auf ${INPUT}.${NOCOLOR}"
		exit 1
	fi
}

function check_output_access {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Schreibrechte vorab prüfen: Existiert das Ziel, muss es beschreibbar
	# sein, andernfalls das Elternverzeichnis. Bei REMOTE=1 läuft die Prüfung
	# über execute_command auf dem Remote-Host.
	local parent
	parent=$(dirname -- "${OUTPUT}")
	if execute_command test -e "${OUTPUT}"; then
		if execute_command test -w "${OUTPUT}"; then return 0; fi
	elif execute_command test -w "${parent}"; then
		return 0
	fi
	echo -e "${ERRORCOLOR}Fehler: Keine Schreibrechte auf ${OUTPUT} (bzw. ${parent}).${NOCOLOR}" >&2
	exit 1
}

function input_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
  # Determine the type of the input file
  echo -e "${INFOCOLOR}Analysiere INPUT${NOCOLOR}"
  if [ ! -f "${INPUT}" ] && [ ! -b "${INPUT}" ]; then
    echo "Error: input must be a regular file or block device: ${INPUT}" >&2
    exit 1
  fi
  INPUT_FILE_TYPE=$(file -Lb -- "${INPUT}") || exit 1
  echo "\$INPUT_FILE_TYPE = $INPUT_FILE_TYPE"

  # Use the appropriate command to calculate the size of the input file
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    #echo "INPUT_SIZE=$(blockdev --getsize64 $INPUT)"
    INPUT_SIZE=$(blockdev --getsize64 "${INPUT}") || exit 1
    echo "\$INPUT_SIZE=${INPUT_SIZE}"
  else
    INPUT_SIZE=$(stat -Lc %s -- "${INPUT}") || exit 1
    echo "\$INPUT_SIZE=${INPUT_SIZE}"
  fi
}

function output_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Determine the type of the output file
	echo -e "${INFOCOLOR}Analysiere OUTPUT${NOCOLOR}"
	if ! execute_command test -e "${OUTPUT}"; then
		OUTPUT_FILE_TYPE=missing
		OUTPUT_SIZE=0
		return 0
	fi
	OUTPUT_FILE_TYPE=$(execute_command file -Lb -- "${OUTPUT}")

	# Use the appropriate command to calculate the size of the output file
	echo "\$OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"
	if [[ "${OUTPUT_FILE_TYPE}" == "block special"* ]]; then
		OUTPUT_SIZE=$(execute_command blockdev --getsize64 "${OUTPUT}")
		echo "\$OUTPUT_SIZE = $OUTPUT_SIZE"
	else
		OUTPUT_SIZE=$(execute_command stat -Lc %s -- "${OUTPUT}")
		echo "\$OUTPUT_SIZE = $OUTPUT_SIZE"
	fi
	echo -e "${INFOCOLOR}${FUNCNAME[0]} abgeschlossen${NOCOLOR}"
}

function remote_port_generation {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    # RANDOM yields 0-32767, so the effective port range is 10000-42767
    REMOTE_PORT=$(( RANDOM + 10000 ))
}

function check_remote_port_availability {
  local listeners
  listeners=$(execute_remote_command "ss -H -tln") || return 2
  if grep -qE ":${CURRENT_REMOTE_PORT}[^0-9]" <<< "${listeners}"; then return 1; fi
  return 0
}

function size_calculation {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
  # Berechnet die Teilgröße pro Job. SPLIT_SIZE wird auf ein Vielfaches der
  # Blockgröße abgerundet; der Rest, der sich nicht gleichmäßig verteilen
  # lässt, wird vom letzten Teil mit übertragen (siehe part_bytes). Dadurch
  # sind beliebige Eingabegrößen möglich.
  echo -e "${INFOCOLOR}Calculate the size of each input split file${NOCOLOR}"
  ddpar_uint "${INPUT_SIZE}" || exit 1
  SPLIT_SIZE=$(( (INPUT_SIZE / NUM_JOBS / BLOCKSIZEBYTES) * BLOCKSIZEBYTES ))
  if [ "${SPLIT_SIZE}" -eq 0 ]; then
    # Eingabe kleiner als NUM_JOBS Blöcke: die ersten Teile übertragen je
    # einen Block, überzählige Teile bleiben leer.
    SPLIT_SIZE=${BLOCKSIZEBYTES}
  fi
  if [ "${NUM_JOBS}" -gt "$((9223372036854775807 / SPLIT_SIZE))" ]; then
    echo 'Error: segment offsets exceed the supported range.' >&2
    exit 2
  fi
  echo -e "${INFOCOLOR}Splitsize: ${SPLIT_SIZE}${NOCOLOR}"
  if [ $((SPLIT_SIZE * NUM_JOBS)) -ne "${INPUT_SIZE}" ]; then
    echo -e "${INFOCOLOR}Eingabegröße (${INPUT_SIZE}) ist nicht glatt durch Jobs x Blockgröße teilbar, der letzte Teil überträgt $(part_bytes $((NUM_JOBS - 1))) Bytes.${NOCOLOR}"
  fi
}

function part_bytes {
	# Bytes, die Teil $1 überträgt: normale Teile SPLIT_SIZE, der letzte Teil
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

function clone_file {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    # generate further spinoff variables
    INPUT_FILE_NAME=$(basename -- "${INPUT}")

    # Resolve the actual filename before enforcing overwrite protection.
    if execute_command test -d "${OUTPUT}"; then
        OUTPUT_PATH="${OUTPUT}/${INPUT_FILE_NAME}"
    else
        OUTPUT_PATH="${OUTPUT}"
    fi
    if execute_command test -e "${OUTPUT_PATH}" && [ -z "${FORCE}" ]; then
        echo "Error: ${OUTPUT_PATH} already exists; use -f to overwrite it." >&2
        return 1
    fi
    if execute_command test -e "${OUTPUT_PATH}" &&
       ! execute_command test -f "${OUTPUT_PATH}" && ! execute_command test -b "${OUTPUT_PATH}"; then
        echo "Error: unsupported clone destination: ${OUTPUT_PATH}" >&2
        return 1
    fi
    if execute_command test -b "${OUTPUT_PATH}"; then
        local target_size
        target_size=$(execute_command blockdev --getsize64 "${OUTPUT_PATH}") || return 1
        if [ "${target_size}" -lt "${INPUT_SIZE}" ]; then
            echo 'Error: target device is too small.' >&2
            return 1
        fi
    fi

    echo -e "${SUCCESSCOLOR}Starting file cloning processes ...${NOCOLOR}"
    run_clone_parts "${OUTPUT_PATH}"
}

function clone_block {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    echo "Prüfe Klon-Parameter."
    # Wird wahrscheinlich nicht mehr gebraucht:
    #if [[ "${INPUT_FILE_TYPE}" != "block special"* ]]; then
    #    echo "Fehler: Ungültige Eingabe-Typ. Erforderlich: block special. Nur Block-Geräte können geklont werden."
    #    # Hier kannst du den Code für den Fehlerfall des Eingabe-Typs einfügen
    #    exit 1
    #fi        
    if [[ "${OUTPUT_FILE_TYPE}" != "block special"* ]]; then
        echo -e "${ERRORCOLOR}Fehler: Ungültiger Ausgabe-Typ. Erforderlich: block special. Beim Klonen eines Block-Gerätes muss das Ziel ebenfalls ein Block-Gerät sein.${NOCOLOR}"
        # Hier kannst du den Code für den Fehlerfall des Ausgabe-Typs einfügen
        exit 1
    fi
    if (( INPUT_SIZE > OUTPUT_SIZE )); then
        echo -e "${ERRORCOLOR}Fehler: Eingabegröße (${INPUT_SIZE}) ist größer als Ausgabegröße (${OUTPUT_SIZE}). Bitte stelle ein anderes Zielgerät bereit.${NOCOLOR}"
        # Hier kannst du den Code für den Fehlerfall des Größenverhältnisses einfügen
        exit 1
    fi
    echo -e "${SUCCESSCOLOR}Klonvorgang kann durchgeführt werden.${NOCOLOR}"
    echo -e "${SUCCESSCOLOR}Starte die Prozesse ...${NOCOLOR}"
    run_clone_parts "${OUTPUT}"
}

function run_clone_parts {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Startet die parallelen dd-Teil-Prozesse eines Clone-Vorgangs.
	# $1 = Ausgabeziel (Datei oder Blockgerät); bei REMOTE=1 wird pro Teil
	# ein nc-Listener auf dem Remote-Host eingerichtet.
	# ToDo: Checksum/Kompression für Clone analog zum Backup-Modus umsetzen.
	local output_target=$1
	local PART_NUM START COUNT_BYTES
	local dd_in dd_out

	if [ "$COMPRESSION" -eq 1 ] && ! remote_compression_active; then
		echo -e "${WARNCOLOR}[WARN] Kompression (-c) ist im Clone-Modus nur mit Remote-Modus 'c' (-r c) möglich und wird ignoriert. Ein Clone muss auf der Gegenseite wieder dekomprimiert werden; lokal steht sie im Backup-Modus (-m backup) zur Verfügung.${NOCOLOR}"
	fi
	# conv=notrunc is needed for parallel writes, but an existing regular file
	# must lose any old suffix before the workers write their segments.
	if [ "${REMOTE}" -ne 1 ] && [ "${INPUT}" -ef "${output_target}" ]; then
		echo "Fehler: Quelle und Ziel sind dieselbe Datei." >&2
		return 1
	fi
	if execute_command test -f "${output_target}"; then
		if ! execute_command truncate -s "${INPUT_SIZE}" -- "${output_target}"; then
			echo "Fehler: Zieldatei ${output_target} konnte nicht angepasst werden." >&2
			return 1
		fi
	fi

	local remote_writer
	remote_writer="$(declare -f ddpar_write_segment); BLOCKSIZEBYTES=${BLOCKSIZEBYTES}; "
	for ((PART_NUM=0; PART_NUM<NUM_JOBS; PART_NUM++)); do
		START=$((PART_NUM * SPLIT_SIZE))
		COUNT_BYTES=$(part_bytes "${PART_NUM}")
		# Byte-genaue dd-Aufrufe (count_bytes/skip_bytes/seek_bytes), damit
		# auch nicht glatt teilbare Eingabegrößen funktionieren. Arrays statt
		# eval-Strings: Pfade mit Leerzeichen o.ä. sind so ungefährlich.
		dd_in=(dd if="${INPUT}" bs="${BLOCKSIZEBYTES}" "iflag=fullblock,count_bytes,skip_bytes" count="${COUNT_BYTES}" skip="${START}")
		dd_out=(dd of="${output_target}" bs="${BLOCKSIZEBYTES}" oflag=seek_bytes seek="${START}" conv=notrunc)

		if remote_compression_active; then
			# Remote-Modus "c": komprimiert wird auf DIESER Maschine, über das
			# Netz geht nur der komprimierte Strom, die Gegenseite dekomprimiert
			# ihn vor dem Schreiben (remote decompression). Nur so lässt sich ein
			# Clone komprimiert übertragen — das Ziel muss die Rohdaten enthalten.
			if ! setup_remote_listener "${remote_writer} gzip -dc | ddpar_write_segment $(shell_quote "${output_target}") ${COUNT_BYTES} ${START}"; then
				echo -e "${ERRORCOLOR}Remote-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				return 1
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} | nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" | nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" &
		elif [ $REMOTE -eq 1 ]; then
			# Die Empfängerseite läuft auf dem Remote-Host und wird als String
			# über SSH gestartet; der Pfad ist dort in Anführungszeichen gesetzt.
			if ! setup_remote_listener "${remote_writer} ddpar_write_segment $(shell_quote "${output_target}") ${COUNT_BYTES} ${START}"; then
				echo -e "${ERRORCOLOR}Remote-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				return 1
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" &
		else
			echo -e "${INFOCOLOR}${dd_in[*]} | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | ddpar_write_segment "${output_target}" "${COUNT_BYTES}" "${START}" &
		fi
		register_job $! "Teil ${PART_NUM} (clone)"
	done
}

function append_metadata {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Schreibt eine Zeile in das Metadatenfile, lokal oder remote
	local line=$1
	if [ $REMOTE -eq 1 ]; then
		execute_remote_command "printf '%s\\n' $(shell_quote "${line}") >> $(shell_quote "${METADATA_FILE}")"
	else
		printf '%s\n' "${line}" >> "${METADATA_FILE}"
	fi
}

function setup_remote_listener {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Richtet auf der Remote-Maschine einen netcat-Empfänger ein, der die
	# übertragenen Daten in den übergebenen Befehl (z.B. "dd of=...") schreibt.
	# Wird von Clone- und Backup-Modus gemeinsam genutzt. Der Port für die
	# lokale Senderseite steht anschließend in CURRENT_REMOTE_PORT.
	local remote_output_cmd=$1

	# Generate and check remote ports
	if [ -z "${REMOTE_PORT}" ]; then
		remote_port_generation
	fi
	CURRENT_REMOTE_PORT=$((10000 + (REMOTE_PORT - 10000 + PART_NUM) % 32768))
	# Schleife zum Generieren eines freien Ports
	while true; do
		if check_remote_port_availability; then
			break
		else
			[ "$?" -eq 2 ] && return 1
			echo -e "${INFOCOLOR}Port ${CURRENT_REMOTE_PORT} on remote machine already in use, generate new port.${NOCOLOR}"
			remote_port_generation
			CURRENT_REMOTE_PORT=$((10000 + (REMOTE_PORT - 10000 + PART_NUM) % 32768))
		fi
	done

	echo -e "${INFOCOLOR}REMOTE COMMAND: receive segment ${PART_NUM} on port ${CURRENT_REMOTE_PORT}${NOCOLOR}"
	if ! execute_remote_background_command "nc -N -l ${CURRENT_REMOTE_PORT} | { ${remote_output_cmd}; }"; then
		INTERNAL_EXITCODE=2
		return 1
	fi
	REMOTE_LISTENER_PORTS+=("${CURRENT_REMOTE_PORT}")
	register_remote_job "${REMOTE_JOB_BASE}" "Remote-Empfänger Port ${CURRENT_REMOTE_PORT}"

	# Check if execute_remote_background_command is running
	MAX_ATTEMPTS=3 # Anzahl der maximalen Versuche
	SLEEP_INTERVAL=1 # Wartezeit zwischen den Versuchen in Sekunden
	ATTEMPT=1	# Zähler für die aktuellen Versuche

	# Schleife, die den Status des Ports überprüft
	while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
		echo -e "${INFOCOLOR}Checking if remote process is running on port ${CURRENT_REMOTE_PORT} (attempt $ATTEMPT)...${NOCOLOR}"
		if execute_remote_command "ss -tln | grep -qE :${CURRENT_REMOTE_PORT}[^0-9]"; then
			echo -e "${INFOCOLOR}Process found on port ${CURRENT_REMOTE_PORT}. Exiting loop.${NOCOLOR}"
			break
		else
			echo -e "${INFOCOLOR}Process not found on port ${CURRENT_REMOTE_PORT}.${NOCOLOR}"
		fi
		ATTEMPT=$((ATTEMPT + 1))
		if [ $ATTEMPT -le $MAX_ATTEMPTS ]; then
			sleep $SLEEP_INTERVAL
		fi
	done

	# Wenn nach allen Versuchen der Prozess nicht gefunden wurde, mit Fehler beenden
	if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
		echo -e "${INFOCOLOR}Process did not start on port ${CURRENT_REMOTE_PORT} after $MAX_ATTEMPTS attempts."
		INTERNAL_EXITCODE=2
		return 1
	fi
}

function backup_mode {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Sichert die Eingabe in NUM_JOBS Teil-Dateien (.part bzw. .gz) inklusive
	# Metadatendatei. Bei REMOTE=1 landen die Teile per netcat auf dem Remote-Host.
	if [[ "${OUTPUT_FILE_TYPE}" != *"directory"* ]]; then
		echo -e "${ERRORCOLOR}Fehler: Ungültiger Ausgabe-Typ ${OUTPUT_FILE_TYPE}. Erforderlich: directory.${NOCOLOR}"
		exit 1
	fi
	# Freier Speicher im Zielpfad analysieren (lokal; remote netcat backup ohne diese Pruefung)
	if [ $REMOTE -ne 1 ]; then
		FREE_SPACE=$(df -P -B 1 "${OUTPUT}" | awk 'NR==2 {print $4}')
		if [ -z "$FORCE" ] && (( INPUT_SIZE > FREE_SPACE )); then
			echo -e "${ERRORCOLOR}Fehler: Eingabegröße (${INPUT_SIZE}) überschreitet den verfügbaren Speicherplatz (${FREE_SPACE}).${NOCOLOR}"
			exit 1
		fi
		if [ -n "$FORCE" ] && (( INPUT_SIZE > FREE_SPACE )); then
			echo -e "${WARNCOLOR}Warnung: Eingabegröße (${INPUT_SIZE}) überschreitet den verfügbaren Speicherplatz (${FREE_SPACE}). Mit aktiver Komprimierung koennte es dennoch passen.${NOCOLOR}"
		fi
	fi

	echo -e "${SUCCESSCOLOR}Führe die Backup-Aktion durch.${NOCOLOR}"

	# generate further spinoff variables
	INPUT_FILE_NAME=$(basename -- "${INPUT}")
	# Eigener Basisname via -n, sonst Basename der Eingabe
	OUTPUT_FILE_NAME=${BASE_NAME:-${INPUT_FILE_NAME}}
	OUTPUT_FILE="${OUTPUT}/${OUTPUT_FILE_NAME}-"
	METADATA_FILE="${OUTPUT_FILE}metadata.txt"

	if ! ddpar_basename -- "${OUTPUT_FILE_NAME}" || ! ddpar_basename -- "${INPUT_FILE_NAME}"; then
		echo 'Error: backup basename must fit one metadata line.' >&2
		return 1
	fi
	# Reject generated symlinks and source aliases before any output is opened.
	local artifact part suffix
	local artifacts=("${METADATA_FILE}" "${METADATA_FILE}.old")
	for ((part=0; part<NUM_JOBS; part++)); do
		for suffix in part gz sha256; do artifacts+=("${OUTPUT_FILE}${part}.${suffix}"); done
	done
	for artifact in "${artifacts[@]}"; do
		if execute_command test -L "${artifact}" ||
		   { [ "${REMOTE}" -ne 1 ] && [ "${INPUT}" -ef "${artifact}" ]; }; then
			echo "Error: unsafe backup output: ${artifact}" >&2
			return 1
		fi
	done

	# Write metadata file (lokal oder remote)
	if [ $REMOTE -eq 1 ]; then
		if execute_remote_command "test -f $(shell_quote "${METADATA_FILE}")"; then
			echo "Metadatafile already exists, copying it to ${METADATA_FILE}.old"
			if ! execute_remote_command "cp -p -- $(shell_quote "${METADATA_FILE}") $(shell_quote "${METADATA_FILE}.old") && : > $(shell_quote "${METADATA_FILE}")"; then
				INTERNAL_EXITCODE=1
				return 1
			fi
		fi
	else
		if [ -f "${METADATA_FILE}" ]; then
			echo "Metadatafile already exists, copying it to ${METADATA_FILE}.old"
			if ! cp -p -- "${METADATA_FILE}" "${METADATA_FILE}.old" || ! : > "${METADATA_FILE}"; then
				INTERNAL_EXITCODE=1
				return 1
			fi
		fi
	fi

	append_metadata "BACKUP_STATE=incomplete" || return 1
	append_metadata "NUM_JOBS=${NUM_JOBS}" || return 1
	# FILE_NAME = Basisname der Backup-Dateien (bei -n abweichend von INPUT_FILE_NAME)
	append_metadata "FILE_NAME=${OUTPUT_FILE_NAME}" || return 1
	append_metadata "BLOCKSIZEBYTES=${BLOCKSIZEBYTES}" || return 1
	append_metadata "INPUT_SIZE=${INPUT_SIZE}" || return 1
	append_metadata "INPUT_FILE_NAME=${INPUT_FILE_NAME}" || return 1
	append_metadata "FILE_TYPE=${INPUT_FILE_TYPE}" || return 1
	append_metadata "SPLIT_SIZE=${SPLIT_SIZE}" || return 1

	# Auch im Remote-Modus wird komprimiert (je nach -r lokal oder auf der
	# Gegenseite, siehe unten). Die erzeugten .gz-Teile sind identisch, daher
	# gehören die Kompressions-Metadaten in allen Fällen in die Metadatendatei.
	if [ "$COMPRESSION" -eq 1 ]; then
		append_metadata "COMPRESSION=${COMPRESSION}" || return 1
		append_metadata "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}" || return 1
	fi

	if [ "$REMOTE" -eq 1 ] && [ "$CHECKSUM" -eq 1 ]; then
		echo -e "${WARNCOLOR}[WARN] Im Remote-Modus werden keine .sha256-Dateien erzeugt. Die Prüfung erfolgt mit 'ddpar-check.sh -r' über Hashes, die zur Laufzeit gebildet werden.${NOCOLOR}"
	fi

	local PART_NUM START COUNT_BYTES PART_BASE
	local dd_in dd_out
	echo -e "${INFOCOLOR}Starte die Prozesse ...${NOCOLOR}"
	for ((PART_NUM=0; PART_NUM<NUM_JOBS; PART_NUM++)); do

		START=$((PART_NUM * SPLIT_SIZE))
		COUNT_BYTES=$(part_bytes "${PART_NUM}")
		PART_BASE="${OUTPUT_FILE}${PART_NUM}"
		# Byte-genaue dd-Aufrufe (count_bytes/skip_bytes), damit auch nicht
		# glatt teilbare Eingabegrößen funktionieren. Direkte Pipelines statt
		# eval-Strings: Pfade mit Leerzeichen o.ä. sind so ungefährlich.
		dd_in=(dd if="${INPUT}" bs="${BLOCKSIZEBYTES}" "iflag=fullblock,count_bytes,skip_bytes" count="${COUNT_BYTES}" skip="${START}")
		dd_out=(dd of="${PART_BASE}.part" bs="${BLOCKSIZEBYTES}")

		if remote_compression_active; then
			# Remote netcat backup mit Kompression auf der Gegenseite (-r c):
			# über das Netz gehen die Rohdaten, gzip läuft auf dem REMOTE-Host
			# und schreibt dort direkt die .gz-Datei. Das entlastet die lokale
			# CPU, spart aber keine Bandbreite (dafür siehe -r n).
			if ! setup_remote_listener "gzip -${COMPRESSION_LEVEL} > $(shell_quote "${PART_BASE}.gz")"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" &
		elif [ "$REMOTE" -eq 1 ] && [ "$COMPRESSION" -eq 1 ]; then
			# Remote netcat backup mit lokaler Kompression: gzip läuft auf
			# DIESER Maschine, über das Netz geht nur der komprimierte Strom.
			# Die Remote-Seite schreibt ihn unverändert in die .gz-Datei und
			# benötigt dafür kein gzip.
			if ! setup_remote_listener "dd of=$(shell_quote "${PART_BASE}.gz") bs=${BLOCKSIZEBYTES}"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} | nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" | nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" &
		elif [ $REMOTE -eq 1 ]; then
			# Remote netcat backup, unkomprimiert, ohne Checksumme. Die
			# Empfängerseite läuft auf dem Remote-Host (String via SSH).
			if ! setup_remote_listener "dd of=$(shell_quote "${PART_BASE}.part") bs=${BLOCKSIZEBYTES}"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_ADDRESS} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc -w "${NETWORK_TIMEOUT}" "${REMOTE_ADDRESS}" "${CURRENT_REMOTE_PORT}" &
		elif [ "${CHECKSUM}" -eq 1 ] && [ "${COMPRESSION}" -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} > ${PART_BASE}.gz; verify raw checksum${NOCOLOR}"
			( "${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" > "${PART_BASE}.gz" &&
			  gzip -dc -- "${PART_BASE}.gz" | sha256sum > "${PART_BASE}.sha256" ) &
		elif [ "${COMPRESSION}" -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} > ${PART_BASE}.gz${NOCOLOR}"
			"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" > "${PART_BASE}.gz" &
		elif [ "${CHECKSUM}" -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | ${dd_out[*]}; verify raw checksum${NOCOLOR}"
			( "${dd_in[@]}" | "${dd_out[@]}" && sha256sum < "${PART_BASE}.part" > "${PART_BASE}.sha256" ) &
		else
			echo -e "${INFOCOLOR}${dd_in[*]} | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | "${dd_out[@]}" &
		fi
		register_job $! "Teil ${PART_NUM} (backup)"
	done
}

# Verify all outputs before publishing the backup as complete. A failed run
# retains incomplete metadata, preventing restore of a mixture of old/new parts.
function finalize_backup {
    local part path actual expected
    for ((part=0; part<NUM_JOBS; part++)); do
        expected=$(part_bytes "${part}")
        if [ "${COMPRESSION}" -eq 1 ]; then
            path="${OUTPUT_FILE}${part}.gz"
            if [ "${REMOTE}" -eq 1 ]; then
                if remote_compression_active; then
                    actual=$(execute_remote_command "gzip -dc -- $(shell_quote "${path}") | wc -c") || return 1
                else
                    actual=$(execute_remote_command "cat -- $(shell_quote "${path}")" | gzip -dc | wc -c) || return 1
                fi
            else
                actual=$(gzip -dc -- "${path}" | wc -c) || return 1
            fi
        else
            path="${OUTPUT_FILE}${part}.part"
            actual=$(execute_command stat -Lc %s -- "${path}") || return 1
        fi
        if [ "${actual}" -ne "${expected}" ]; then
            echo "Error: incomplete backup part: ${path}" >&2
            return 1
        fi
        if [ "${CHECKSUM}" -ne 1 ] || [ "${REMOTE}" -eq 1 ]; then
            execute_command rm -f -- "${OUTPUT_FILE}${part}.sha256" || return 1
        fi
    done
    execute_command sed -i 's/^BACKUP_STATE=incomplete$/BACKUP_STATE=complete/' "${METADATA_FILE}"
}

# Verwaltung der parallelen Hintergrund-Jobs:
# Jeder gestartete Teil-Job wird mit PID und Beschreibung registriert, damit
# wait_for_jobs die Exit-Codes einzeln einsammeln kann. Ein nacktes "wait"
# würde Fehler einzelner dd-/nc-Pipelines verschlucken.
JOB_PIDS=()
JOB_LABELS=()
# Remote-Pipelines: Basisname ihrer Statusdateien im REMOTE_STATUS_DIR
REMOTE_JOB_BASES=()
REMOTE_JOB_LABELS=()
# Ports, auf denen remote nc-Listener gestartet wurden (für Cleanup bei Abbruch)
REMOTE_LISTENER_PORTS=()

function register_job {
	JOB_PIDS+=("$1")
	JOB_LABELS+=("$2")
}

function register_remote_job {
	REMOTE_JOB_BASES+=("${1}")
	REMOTE_JOB_LABELS+=("${2}")
}

function wait_for_jobs {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	local failed=0
	local i rc
	for i in "${!JOB_PIDS[@]}"; do
		wait "${JOB_PIDS[$i]}"
		rc=$?
		if [ $rc -ne 0 ]; then
			echo -e "${ERRORCOLOR}Fehler: ${JOB_LABELS[$i]} ist mit Exit-Code ${rc} fehlgeschlagen.${NOCOLOR}"
			failed=$((failed + 1))
		fi
	done
	if [ "${#JOB_PIDS[@]}" -ne "${NUM_JOBS}" ]; then
		echo "Fehler: Es wurde kein Clone- oder Backup-Job gestartet." >&2
		failed=$((failed + 1))
	fi
	# Nach einem Fehler (lokaler Job oder nicht gestarteter Teil) wartet ein
	# Remote-Listener eventuell ewig auf seinen Sender -> nc dort beenden.
	if [ "${failed}" -gt 0 ] || [ "${INTERNAL_EXITCODE}" -ne 0 ]; then
		stop_remote_listeners "${REMOTE_LISTENER_PORTS[@]}"
	fi
	[ "${#REMOTE_JOB_BASES[@]}" -gt 0 ] && echo -e "${INFOCOLOR}Warte auf den Abschluss der Remote-Pipelines ...${NOCOLOR}"
	local state polls
	for i in "${!REMOTE_JOB_BASES[@]}"; do
		# Die Gegenseite kann nach dem Ende des lokalen Senders noch schreiben
		# (gzip im Modus c, Flush beim Schliessen eines Blockgeraets). Kein festes
		# Zeitlimit, damit ein langsamer, aber gesunder Schreibvorgang nicht als
		# Fehler zaehlt; ist der Status nicht abrufbar, gilt der Job als fehlgeschlagen.
		polls=0
		while true; do
			state=$(remote_job_state "${REMOTE_JOB_BASES[$i]}") || state="unreachable"
			[ "${state}" != "running" ] && break
			polls=$((polls + 1))
			[ $((polls % 120)) -eq 0 ] && echo -e "${INFOCOLOR}${REMOTE_JOB_LABELS[$i]} schreibt noch ...${NOCOLOR}"
			sleep 0.5
		done
		case "${state}" in
			"rc 0") ;;
			"rc "*)
				echo -e "${ERRORCOLOR}Fehler: ${REMOTE_JOB_LABELS[$i]} ist mit Exit-Code ${state#rc } fehlgeschlagen.${NOCOLOR}" >&2
				execute_remote_command "tail -n 5 -- $(shell_quote "${REMOTE_JOB_BASES[$i]}.log")" >&2 2>/dev/null
				failed=$((failed + 1))
				;;
			*)
				echo -e "${ERRORCOLOR}Fehler: Exit-Status von ${REMOTE_JOB_LABELS[$i]} ist nicht ermittelbar (${state}).${NOCOLOR}" >&2
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
		echo -e "${ERRORCOLOR}Fehler: ${failed} parallele(r) Job(s) fehlgeschlagen. Das Ergebnis ist unvollständig!${NOCOLOR}"
		INTERNAL_EXITCODE=1
		return 1
	fi
	echo -e "${SUCCESSCOLOR}Alle parallelen Jobs erfolgreich beendet.${NOCOLOR}"
	return 0
}



################
# Script Start #
################
trap ddpar_cancel INT TERM
set_colors
option_analysis "$@"
check_input_access
input_analysis
size_calculation
if ! check_commands_availability; then
    echo -e "${ERRORCOLOR}Fehler: Benötigte Befehle fehlen auf dem lokalen System.${NOCOLOR}"
    exit 1
fi
if [ $REMOTE -eq 1 ]; then
    connect_ssh || exit 1
    if ! check_remote_commands_availability; then
        echo -e "${ERRORCOLOR}Fehler: Benötigte Befehle fehlen auf ${REMOTE_HOST}.${NOCOLOR}"
        close_ssh_connection
        exit 1
    fi
fi
check_output_access
output_analysis


echo -e "${SUCCESSCOLOR}Initialisierung erfolgreich${NOCOLOR}"

# Modus analysieren

case $MODE in
    "clone")
        case ${INPUT_FILE_TYPE} in
            "block special"*)
                echo "Do block special cloning"
                clone_block || INTERNAL_EXITCODE=1
                ;;
            "directory")
                echo -e "${ERRORCOLOR}Input-type is directory, which cannot be cloned using this script. Exiting ...${NOCOLOR}"
                INTERNAL_EXITCODE=1
                ;;
            *)
                echo "Try cloning this file..."
                clone_file || INTERNAL_EXITCODE=1
                ;;
        esac
        # Wait for all jobs to finish and collect their exit codes
        wait_for_jobs
        ;;
    "backup")
        backup_mode || INTERNAL_EXITCODE=1
        # Wait for all jobs to finish and collect their exit codes
        wait_for_jobs
        if [ "${INTERNAL_EXITCODE}" -eq 0 ]; then finalize_backup || INTERNAL_EXITCODE=1; fi
        ;;
    *)
        echo "Ungültiger Modus: $MODE. Gültige Angaben: clone|backup"
        INTERNAL_EXITCODE=1
        ;;
esac

if [ $REMOTE -eq 1 ]; then
	if close_ssh_connection; then
		echo -e "${SUCCESSCOLOR}SSH-Verbindung zu ${REMOTE_HOST} erfolgreich gertrennt.${NOCOLOR}"
	fi
fi

exit ${INTERNAL_EXITCODE}
