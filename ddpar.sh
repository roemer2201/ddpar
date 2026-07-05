#!/bin/bash

# Fehler in dd-/nc-Pipelines sollen den Exit-Code der Pipeline bestimmen,
# sonst zählt nur der letzte Befehl (z.B. ein erfolgreiches dd of=...).
set -o pipefail

# Standardwerte für die Parameter
INPUT_FILE=""
OUTPUT_PATH=""
MODE="clone"
NUM_JOBS="4"
BLOCKSIZEBYTES="1048576"
COMPRESSION=${COMPRESSION:-0}
CHECKSUM=${CHECKSUM:-0}
REMOTE=0
REMOTE_MODE="n"
#SSH_SOCKET_PATH="/tmp/ssh_mux_%n_%p_%r"
SSH_SOCKET_PATH="/tmp/ssh_socket_ddpar"
INTERNAL_EXITCODE=0
DEBUG=0


# Hilfemeldung anzeigen
function show_help {
  SCRIPT_NAME=$(basename "$0")
  echo "$SCRIPT_NAME - Ein Bash-Skript zum parallelen Klonen oder Sichern von Blockgeräten oder großen Dateien"
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-i FILE|DEVICE          Die Eingabedatei"
  echo "-o FILE|DEVICE|PATH     Der Ausgabepfad"
  echo "-m clone|backup         Ziel des Vorgangs (Default: clone)"
  echo "-j NUM                  Die Anzahl der Jobs (Default: 4)"
  echo "-b NUM                  Die Blockgröße in Bytes (Default: 1048576 Bytes (1 MiB))"
  echo "-n NAME                 Eigener Basisname der Backup-Dateien (Default: Basename der Eingabe)."
  echo "                        Im Clone-Modus mit -s: Basis-Pfad für Checksummen- und Metadatendatei"
  echo "-c                      Komprimierung anfordern, Kompressionslevel zur Zeit nicht einstellbar (Default: -6)."
  echo "                        Im Clone-Modus nur bei Remote wirksam (komprimierter Transfer)"
  echo "-s                      Checksumme der einzelnen Teile erstellen (Clone: .sha256- und Metadatendatei"
  echo "                        am Basis-Pfad aus -n, prüfbar mit ddpar-check.sh -b BASE -d ZIEL)"
  echo "-f                      Force - ignore Probleme und erzwinge den Vorgang"
  echo "-r [lnc]                Remote-Verbindung, nur SSH möglich. Remote-Optionen: siehe unten"
  echo "-R user@host            Angabe des Remote-Host"
  echo "-h                      Diese Hilfe anzeigen"
  echo "-d                      Debug Modus"
  echo ""
  echo "Remote-Optionen:"
  echo "n: Standardeinstellung, No encryption, Verbindungsaufbau verschlüsselt (SSH),"
  echo "   Datenübertragung unverschlüsselt über netcat (nur in vertrauenswürdigen Netzen verwenden!)"
  echo "l: GEPLANT, noch nicht implementiert: Übertragung vollständig verschlüsselt"
  echo "c: Kompression/Dekompression auf der Remote-Maschine (impliziert -c; Datenkanal"
  echo "   wie bei n unverschlüsselt über netcat)"
}

function option_analysis {
  # Verwendung von getopts zur Verarbeitung der Optionen
  echo "Analysiere gegebene Optionen \"$*\""
  while getopts ":i:o:m:j:b:n:r::R:csfhd" opt; do
    case $opt in
      i) INPUT="${OPTARG}";;
      o) OUTPUT="${OPTARG}";;
      m) MODE="${OPTARG}";;
      j) NUM_JOBS="${OPTARG}";;
      b) BLOCKSIZEBYTES="${OPTARG}";;
      n) BASE_NAME="${OPTARG}";;
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
		PS4="${SETXCOLOR}$(printf "%*s" "$SHLVL" | tr " " "+") ${NOCOLOR}"
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
        # Implementiert: "n" (netcat, Datenkanal unverschlüsselt) und "c"
        # ([De]Kompression auf der Remote-Maschine). "l" (verschlüsselt) ist
        # geplant — hier ehrlich warnen statt still zurückzufallen.
        case "${OPTARG:-n}" in
          n) REMOTE_MODE="n";;
          c) REMOTE_MODE="c";;
          l)
            echo -e "${WARNCOLOR}[WARN] Remote-Modus 'l' ist noch nicht implementiert. Es wird 'n' verwendet: Datenübertragung unverschlüsselt über netcat.${NOCOLOR}"
            REMOTE_MODE="n"
            ;;
          *)
            echo -e "${ERRORCOLOR}Ungültiger Remote-Modus '${OPTARG}'. Gültige Angaben: n|l|c${NOCOLOR}"
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
    esac
  done
  
  # Überprüfung der erforderlichen Parameter
  if [ -z "${INPUT}" ] || [ -z "${OUTPUT}" ] ; then
    echo -e "${ERRORCOLOR}Fehlende Parameter. Bitte geben Sie alle erforderlichen Parameter --input und --output an.${NOCOLOR}"
    exit 1
  fi

  # -n: im Backup-Modus ein reiner Name (relativ zum Ausgabeverzeichnis),
  # im Clone-Modus darf es ein Pfad für die Checksummen-Dateien sein.
  if [ -n "${BASE_NAME}" ] && [ "${MODE}" == "backup" ] && [[ "${BASE_NAME}" == */* ]]; then
    echo -e "${ERRORCOLOR}Ungültiger Basisname '${BASE_NAME}': darf im Backup-Modus keinen Schrägstrich enthalten.${NOCOLOR}"
    exit 1
  fi

  # -r c bedeutet [De]Kompression auf der Remote-Maschine und impliziert -c
  if [ "${REMOTE_MODE}" == "c" ] && [ "${COMPRESSION}" -ne 1 ]; then
    COMPRESSION=1
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
    echo -e "${INFOCOLOR}-r c impliziert Kompression (Level ${COMPRESSION_LEVEL}).${NOCOLOR}"
  fi

  # Beim lokalen Clone gibt es keinen Speicherort für komprimierte Daten
  # (Ziel ist Datei/Blockgerät in Originalgröße) — Kompression wirkt im
  # Clone-Modus nur als komprimierter Remote-Transfer.
  if [ "${MODE}" == "clone" ] && [ "${COMPRESSION}" -eq 1 ] && [ ${REMOTE} -ne 1 ]; then
    echo -e "${WARNCOLOR}[WARN] Kompression (-c) hat beim lokalen Clone keine Wirkung und wird ignoriert.${NOCOLOR}"
    COMPRESSION=0
  fi
  }

function set_colors {
	# check if stdout is a terminal...
	if test -t 1; then
        # see if it supports colors...
        ncolors=$(tput colors)

        if test -n "$ncolors" && test $ncolors -ge 8; then
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

function establish_ssh_connection {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    local target=$1
    local control_path=$2
    local password=$3

    # Wenn ein Passwort bereitgestellt wird, verwenden Sie es, um sich per SSH zu verbinden.
    if [ -n "$password" ]; then
        if ! which sshpass > /dev/null; then
          echo -e "${ERRORCOLOR}Der Befehl \"sshpass\" existiert nicht. Bitte installieren Sie das entsprechende Paket ueber ihren Paketmanager${NOCOLOR}"
          exit 1
        fi
        SSHPASS="$password" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
    else
        echo -e "${INFOCOLOR}Verbindungsaufbau mit Sockel ${control_path} zu ${target}${NOCOLOR}"
        ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
    fi

    return $?
}

function connect_ssh {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    if [ -z "${REMOTE_HOST}" ]; then
        echo -e "${ERRORCOLOR}Fehler: Kein Remote-Host angegeben.${NOCOLOR}"
        exit 1
    fi

    # Wenn ein Socket bereits existiert und funktioniert, dann frühzeitig aussteigen
    if is_ssh_socket_alive; then
        echo -e "${INFOCOLOR}SSH-Verbindung zu ${REMOTE_HOST} besteht bereits.${NOCOLOR}"
        return 0
    fi

    # Prüfen, ob der Host per SSH erreichbar ist
    output=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 ${REMOTE_HOST} true 2>&1)
    
    # Überprüfung des Exit Codes und der Ausgabe
    if [[ $? -eq 0 ]]; then
        echo -e "${SUCCESSCOLOR}Passwortloser Verbindungsaufbau war erfolgreich.${NOCOLOR}"
        establish_ssh_connection "${REMOTE_HOST}" "${SSH_SOCKET_PATH}"
    elif echo "$output" | grep -q "Permission denied"; then
        echo -e "${ERRORCOLOR}Host ist erreichbar, aber passwortlose Authentifizierung fehlgeschlagen.${NOCOLOR}"
        # Passwort vom Nutzer abfragen
        echo -en "${REQUESTCOLOR}Bitte geben Sie das SSH-Passwort für ${REMOTE_HOST} ein: ${NOCOLOR}"
        read -s USER_PASSWORD
        echo

        establish_ssh_connection "${REMOTE_HOST}" "${SSH_SOCKET_PATH}" "$USER_PASSWORD"
        if [ $? -ne 0 ]; then
            echo -e "${ERRORCOLOR}Verbindung zu ${REMOTE_HOST} konnte nicht hergestellt werden.${NOCOLOR}"
            exit 1
        fi
    else
        echo -e "${ERRORCOLOR}Unbekannter Fehler oder Host nicht erreichbar. Ausgabe:${NOCOLOR}"
        echo "$output"
    fi

    echo -e "${SUCCESSCOLOR}SSH-Verbindung zu ${REMOTE_HOST} wurde erfolgreich aufgebaut.${NOCOLOR}"
}

function is_ssh_socket_alive {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    # Überprüft, ob ein funktionierender Socket bereits existiert
    ssh -o ControlPath="${SSH_SOCKET_PATH}" -O check "${REMOTE_HOST}" 2>/dev/null
    return $?
}

function execute_command {
	# This function should preceed every command that could be executed remotely
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	local command=$1
	
	if [ -z "${command}" ]; then
		echo -e "${ERRORCOLOR}Fehler: Kein Befehl zum Ausführen angegeben.${NOCOLOR}"
		return 1
	fi
	if [ $REMOTE -eq 1 ]; then
		# Führe den Befehl auf dem Remote-System aus (via SSH)
		ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "${command}"
	else
		# Führe den Befehl lokal aus. eval (statt ${command}) entfernt die
		# in den Befehlsstrings enthaltenen Quotes korrekt, analog zur
		# Remote-Seite, wo die SSH-Shell den String neu parst. Ohne eval
		# erhielte z.B. "file -b \"${OUTPUT}\"" die Quotes literal, wodurch
		# die Typ-Erkennung eines lokalen Blockgeräts fehlschlägt.
		eval "${command}"
	fi
}

function execute_remote_command {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    local command=$1

    if [ -z "${command}" ]; then
        echo -e "${ERRORCOLOR}Fehler: Kein Befehl zum Ausführen angegeben.${NOCOLOR}"
        return 1
    fi

    ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "${command}"
    
    return $?
}

function execute_remote_background_command {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    local command=$1

    if [ -z "${command}" ]; then
        echo -e "${ERRORCOLOR}Fehler: Kein Befehl zum Ausführen angegeben.${NOCOLOR}"
        return 1
    fi

    # Background the remote process using "nohup ... &"?
    [ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}ssh -S \"${SSH_SOCKET_PATH}\" \"${REMOTE_HOST}\" \"nohup sh -c \${command}\"> /tmp/ddpar.log 2>&1 &${NOCOLOR}"
    ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "nohup sh -c \"${command}\" > /tmp/ddpar.log 2>&1 &"
}

function close_ssh_connection {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    ssh -S "${SSH_SOCKET_PATH}" -O exit "${REMOTE_HOST}"
    if [ $? -ne 0 ]; then
        echo -e "${WARNCOLOR}Warnung: Fehler beim Schließen der SSH-Verbindung zu ${REMOTE_HOST}.${NOCOLOR}"
    fi
}

function check_remote_commands_availability {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion check_remote_commands_availability aufgerufen${NOCOLOR}" >&2
    local commands=("dd" "nc" "df" "tee" "blockdev" "stat" "ss")  # Liste der zu überprüfenden Befehle
    
    if [ "$COMPRESSION" -eq 1 ]; then
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
    local commands=("dd" "df" "tee" "blockdev" "stat")  # Liste der zu überprüfenden Befehle

    if [ "$REMOTE" -eq 1 ]; then
        commands+=("nc" "ssh")
    fi

    if [ "$COMPRESSION" -eq 1 ]; then
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
	parent=$(dirname "${OUTPUT}")
	if ! execute_command "{ [ -e \"${OUTPUT}\" ] && [ -w \"${OUTPUT}\" ]; } || { [ ! -e \"${OUTPUT}\" ] && [ -w \"${parent}\" ]; }"; then
		echo -e "${ERRORCOLOR}Fehler: Keine Schreibrechte auf ${OUTPUT} (bzw. ${parent}).${NOCOLOR}"
		exit 1
	fi
}

function input_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
  # Determine the type of the input file
  echo -e "${INFOCOLOR}Analysiere INPUT${NOCOLOR}"
  INPUT_FILE_TYPE=$(file -b "${INPUT}")
  echo "\$INPUT_FILE_TYPE = $INPUT_FILE_TYPE"

  # Use the appropriate command to calculate the size of the input file
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    #echo "INPUT_SIZE=$(blockdev --getsize64 $INPUT)"
    INPUT_SIZE=$(blockdev --getsize64 "${INPUT}")
    echo "\$INPUT_SIZE=${INPUT_SIZE}"
  else
    INPUT_SIZE=$(stat -c %s "${INPUT}")
    echo "\$INPUT_SIZE=${INPUT_SIZE}"
  fi
}

function output_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Determine the type of the output file
	echo -e "${INFOCOLOR}Analysiere OUTPUT${NOCOLOR}"
	OUTPUT_FILE_TYPE=$(execute_command "file -b \"${OUTPUT}\"")

	# Use the appropriate command to calculate the size of the output file
	echo "\$OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"
	if [[ "${OUTPUT_FILE_TYPE}" == "block special"* ]]; then
		OUTPUT_SIZE=$(execute_command "blockdev --getsize64 \"${OUTPUT}\"")
		echo "\$OUTPUT_SIZE = $OUTPUT_SIZE"
	else
		OUTPUT_SIZE=$(execute_command "stat -c %s \"${OUTPUT}\"")
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
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    execute_remote_command "ss -tln | grep -qE \":${CURRENT_REMOTE_PORT}[^0-9]\""
    # Port is free, if exit code is not zero
    if [[ $? != 0 ]]; then
        return 0
    else
		[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}Port ${CURRENT_REMOTE_PORT} bereits in Benutzung.${NOCOLOR}"
        return 1
    fi
}

function size_calculation {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
  # Berechnet die Teilgröße pro Job. SPLIT_SIZE wird auf ein Vielfaches der
  # Blockgröße abgerundet; der Rest, der sich nicht gleichmäßig verteilen
  # lässt, wird vom letzten Teil mit übertragen (siehe part_bytes). Dadurch
  # sind beliebige Eingabegrößen möglich.
  echo -e "${INFOCOLOR}Calculate the size of each input split file${NOCOLOR}"
  SPLIT_SIZE=$(( (INPUT_SIZE / (NUM_JOBS * BLOCKSIZEBYTES)) * BLOCKSIZEBYTES ))
  if [ "${SPLIT_SIZE}" -eq 0 ]; then
    # Eingabe kleiner als NUM_JOBS Blöcke: die ersten Teile übertragen je
    # einen Block, überzählige Teile bleiben leer.
    SPLIT_SIZE=${BLOCKSIZEBYTES}
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
    INPUT_FILE_NAME=$(basename "${INPUT}")

    # check output file type and existence
    if [[ "${OUTPUT_FILE_TYPE}" == *"directory" ]]; then
        echo "OUTPUT_PATH=${OUTPUT}/${INPUT_FILE_NAME}"
        OUTPUT_PATH="${OUTPUT}/${INPUT_FILE_NAME}"
    elif [[ "${OUTPUT_FILE_TYPE}" == *"No such file or directory"* ]]; then
        if [ ! -z "$FORCE" ]; then
            if execute_command "mkdir -p \"${OUTPUT}\""; then
                OUTPUT_PATH="${OUTPUT}"
                echo "Directory ${OUTPUT} created successfully."
            else
                echo "Error creating directory ${OUTPUT}."
                return 1
            fi
        else
            echo -e "${REQUESTCOLOR}${OUTPUT} does not exist, should this directory be created? (y/N)${NOCOLOR}"
            read answer
            if [ "$answer" == "y" ]; then
                if execute_command "mkdir -p \"${OUTPUT}\""; then
                    OUTPUT_PATH="${OUTPUT}"
                    echo -e "${SUCCESSCOLOR}Directory ${OUTPUT} created successfully.${NOCOLOR}"
                else
                    echo -e "${ERRORCOLOR}Error creating directory ${OUTPUT}.${NOCOLOR}"
                    return 1
                fi
            else
                echo "Request to create directory ${OUTPUT} denied."
                return 1
            fi
        fi
    else
        if [ ! -z "$FORCE" ]; then
            OUTPUT_PATH="${OUTPUT}"
            echo -e "${OUTPUT} already exists and will be overwritten due to use of '-f'."
        else
            echo -e "${ERRORCOLOR}${OUTPUT} already exists. Will not overwrite it. Use '-f' to force.${NOCOLOR}"
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

function setup_clone_checksums {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Bereitet Checksummen für den Clone-Modus vor: CLONE_BASE ist der
	# Basis-Pfad (aus -n, sonst Basename der Eingabe im aktuellen
	# Verzeichnis). Neben den .sha256-Dateien entsteht eine Metadatendatei,
	# damit der Clone später mit "ddpar-check.sh -b CLONE_BASE -d ZIEL"
	# geprüft werden kann. Beides liegt immer lokal, auch bei Remote-Clones.
	CLONE_BASE="${BASE_NAME:-$(basename "${INPUT}")}"
	local base_dir
	base_dir=$(dirname "${CLONE_BASE}")
	if [ ! -d "${base_dir}" ] || [ ! -w "${base_dir}" ]; then
		echo -e "${ERRORCOLOR}Fehler: Verzeichnis ${base_dir} für die Checksummen-Dateien existiert nicht oder ist nicht beschreibbar.${NOCOLOR}"
		return 1
	fi
	{
		echo "NUM_JOBS=${NUM_JOBS}"
		echo "FILE_NAME=$(basename "${CLONE_BASE}")"
		echo "BLOCKSIZEBYTES=${BLOCKSIZEBYTES}"
		echo "INPUT_SIZE=${INPUT_SIZE}"
		echo "INPUT_FILE_NAME=$(basename "${INPUT}")"
		echo "FILE_TYPE=${INPUT_FILE_TYPE}"
		echo "SPLIT_SIZE=${SPLIT_SIZE}"
	} > "${CLONE_BASE}-metadata.txt"
	echo -e "${INFOCOLOR}Checksummen werden nach ${CLONE_BASE}-N.sha256 geschrieben (Metadaten: ${CLONE_BASE}-metadata.txt).${NOCOLOR}"
}

function run_clone_parts {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Startet die parallelen dd-Teil-Prozesse eines Clone-Vorgangs.
	# $1 = Ausgabeziel (Datei oder Blockgerät); bei REMOTE=1 wird pro Teil
	# ein nc-Listener auf dem Remote-Host eingerichtet. Mit -s entstehen
	# lokale .sha256-/Metadaten-Dateien (setup_clone_checksums); mit -c wird
	# der Remote-Transfer komprimiert (gzip lokal, Dekompression remote —
	# bei REMOTE_MODE=c ist das gleichwertig, da das Ziel Rohdaten braucht).
	local output_target=$1
	local PART_NUM START COUNT_BYTES
	local dd_in dd_out remote_out

	if [ $CHECKSUM -eq 1 ]; then
		if ! setup_clone_checksums; then
			INTERNAL_EXITCODE=1
			return 1
		fi
	fi

	for ((PART_NUM=0; PART_NUM<NUM_JOBS; PART_NUM++)); do
		START=$((PART_NUM * SPLIT_SIZE))
		COUNT_BYTES=$(part_bytes "${PART_NUM}")
		# Byte-genaue dd-Aufrufe (count_bytes/skip_bytes/seek_bytes), damit
		# auch nicht glatt teilbare Eingabegrößen funktionieren. Arrays statt
		# eval-Strings: Pfade mit Leerzeichen o.ä. sind so ungefährlich.
		dd_in=(dd if="${INPUT}" bs="${BLOCKSIZEBYTES}" iflag=count_bytes,skip_bytes count="${COUNT_BYTES}" skip="${START}")
		dd_out=(dd of="${output_target}" bs="${BLOCKSIZEBYTES}" oflag=seek_bytes seek="${START}" conv=notrunc)

		if [ $REMOTE -eq 1 ]; then
			# Die Empfängerseite läuft auf dem Remote-Host und wird als String
			# über SSH gestartet; der Pfad ist dort in Anführungszeichen gesetzt.
			remote_out="dd of=\"${output_target}\" bs=${BLOCKSIZEBYTES} oflag=seek_bytes seek=${START} conv=notrunc"
			if [ $COMPRESSION -eq 1 ]; then
				# Komprimierter Transfer: lokal packen, remote entpacken
				remote_out="gzip -dc | ${remote_out}"
			fi
			if ! setup_remote_listener "${remote_out}"; then
				echo -e "${ERRORCOLOR}Remote-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				return 1
			fi
			if [ $CHECKSUM -eq 1 ] && [ $COMPRESSION -eq 1 ]; then
				echo -e "${INFOCOLOR}${dd_in[*]} | tee >(sha256sum > ${CLONE_BASE}-${PART_NUM}.sha256) | gzip -${COMPRESSION_LEVEL} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
				"${dd_in[@]}" | tee >(sha256sum > "${CLONE_BASE}-${PART_NUM}.sha256") | gzip -"${COMPRESSION_LEVEL}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
			elif [ $COMPRESSION -eq 1 ]; then
				echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
				"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
			elif [ $CHECKSUM -eq 1 ]; then
				echo -e "${INFOCOLOR}${dd_in[*]} | tee >(sha256sum > ${CLONE_BASE}-${PART_NUM}.sha256) | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
				"${dd_in[@]}" | tee >(sha256sum > "${CLONE_BASE}-${PART_NUM}.sha256") | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
			else
				echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
				"${dd_in[@]}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
			fi
		elif [ $CHECKSUM -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | tee >(sha256sum > ${CLONE_BASE}-${PART_NUM}.sha256) | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | tee >(sha256sum > "${CLONE_BASE}-${PART_NUM}.sha256") | "${dd_out[@]}" &
		else
			echo -e "${INFOCOLOR}${dd_in[*]} | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | "${dd_out[@]}" &
		fi
		register_job $! "Teil ${PART_NUM} (clone)"
	done
}

function append_metadata {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Schreibt eine Zeile in das Metadatenfile, lokal oder remote
	local line=$1
	if [ $REMOTE -eq 1 ]; then
		execute_remote_command "echo \"${line}\" >> \"${METADATA_FILE}\""
	else
		echo "${line}" >> "${METADATA_FILE}"
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
	CURRENT_REMOTE_PORT=$(( REMOTE_PORT + PART_NUM ))
	# Schleife zum Generieren eines freien Ports
	while true; do
		if check_remote_port_availability; then
			break
		else
			echo -e "${INFOCOLOR}Port ${CURRENT_REMOTE_PORT} on remote machine already in use, generate new port.${NOCOLOR}"
			remote_port_generation
			CURRENT_REMOTE_PORT=$(( REMOTE_PORT + PART_NUM ))
		fi
	done

	echo -e "${INFOCOLOR}REMOTE COMMAND: nc -N -l ${CURRENT_REMOTE_PORT} | ${remote_output_cmd}${NOCOLOR}"
	execute_remote_background_command "nc -N -l ${CURRENT_REMOTE_PORT} | ${remote_output_cmd}"
	REMOTE_LISTENER_PORTS+=("${CURRENT_REMOTE_PORT}")

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
		if [ ! -z "$FORCE" ] && (( INPUT_SIZE > FREE_SPACE )); then
			echo -e "${WARNCOLOR}Warnung: Eingabegröße (${INPUT_SIZE}) überschreitet den verfügbaren Speicherplatz (${FREE_SPACE}). Mit aktiver Komprimierung koennte es dennoch passen.${NOCOLOR}"
		fi
	fi

	echo -e "${SUCCESSCOLOR}Führe die Backup-Aktion durch.${NOCOLOR}"

	# generate further spinoff variables
	INPUT_FILE_NAME=$(basename "${INPUT}")
	# Eigener Basisname via -n, sonst Basename der Eingabe
	OUTPUT_FILE_NAME=${BASE_NAME:-${INPUT_FILE_NAME}}
	OUTPUT_FILE="${OUTPUT}/${OUTPUT_FILE_NAME}-"
	METADATA_FILE="${OUTPUT_FILE}metadata.txt"

	# Write metadata file (lokal oder remote)
	if [ $REMOTE -eq 1 ]; then
		if execute_remote_command "[ -f \"${METADATA_FILE}\" ]"; then
			echo "Metadatafile already exists, copying it to ${METADATA_FILE}.old"
			execute_remote_command "cp -p \"${METADATA_FILE}\" \"${METADATA_FILE}.old\" && cat /dev/null > \"${METADATA_FILE}\""
		fi
	else
		if [ -f ${METADATA_FILE} ]; then
			echo "Metadatafile already exists, copying it to ${METADATA_FILE}.old"
			cp -p ${METADATA_FILE} ${METADATA_FILE}.old
			cat /dev/null > ${METADATA_FILE}
		fi
	fi

	append_metadata "NUM_JOBS=${NUM_JOBS}"
	# FILE_NAME = Basisname der Backup-Dateien (bei -n abweichend von INPUT_FILE_NAME)
	append_metadata "FILE_NAME=${OUTPUT_FILE_NAME}"
	append_metadata "BLOCKSIZEBYTES=${BLOCKSIZEBYTES}"
	append_metadata "INPUT_SIZE=${INPUT_SIZE}"
	append_metadata "INPUT_FILE_NAME=${INPUT_FILE_NAME}"
	append_metadata "FILE_TYPE=${INPUT_FILE_TYPE}"
	append_metadata "SPLIT_SIZE=${SPLIT_SIZE}"

	if [ $COMPRESSION -eq 1 ]; then
		append_metadata "COMPRESSION=${COMPRESSION}"
		append_metadata "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}"
	fi

	if [ $CHECKSUM -eq 1 ] && [ $REMOTE -eq 1 ]; then
		echo -e "${WARNCOLOR}[WARN] -s wird beim Remote-Backup ignoriert: .sha256-Dateien entstehen nicht auf dem Remote-Host. ddpar-check.sh -r prüft Remote-Backups ohne sie (Hashes via SSH).${NOCOLOR}"
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
		dd_in=(dd if="${INPUT}" bs="${BLOCKSIZEBYTES}" iflag=count_bytes,skip_bytes count="${COUNT_BYTES}" skip="${START}")
		dd_out=(dd of="${PART_BASE}.part" bs="${BLOCKSIZEBYTES}")

		if [ $REMOTE -eq 1 ] && [ $COMPRESSION -eq 1 ] && [ "${REMOTE_MODE}" == "c" ]; then
			# Remote-Kompression: Rohdaten über netcat, gzip läuft auf dem
			# Remote-Host (Empfängerseite als String via SSH).
			if ! setup_remote_listener "gzip -${COMPRESSION_LEVEL} > \"${PART_BASE}.gz\""; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
		elif [ $REMOTE -eq 1 ] && [ $COMPRESSION -eq 1 ]; then
			# Lokale Kompression: gzip lokal, die komprimierten Bytes werden
			# unverändert übertragen und remote als .gz abgelegt.
			if ! setup_remote_listener "dd of=\"${PART_BASE}.gz\" bs=${BLOCKSIZEBYTES}"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
		elif [ $REMOTE -eq 1 ]; then
			# Remote netcat backup, unkomprimiert. Die Empfängerseite läuft
			# auf dem Remote-Host (String via SSH).
			if ! setup_remote_listener "dd of=\"${PART_BASE}.part\" bs=${BLOCKSIZEBYTES}"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc "${REMOTE_HOST#*@}" "${CURRENT_REMOTE_PORT}" &
		elif [ $CHECKSUM -eq 1 ] && [ $COMPRESSION -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | tee >(sha256sum > ${PART_BASE}.sha256) | gzip -${COMPRESSION_LEVEL} > ${PART_BASE}.gz${NOCOLOR}"
			"${dd_in[@]}" | tee >(sha256sum > "${PART_BASE}.sha256") | gzip -"${COMPRESSION_LEVEL}" > "${PART_BASE}.gz" &
		elif [ $COMPRESSION -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | gzip -${COMPRESSION_LEVEL} > ${PART_BASE}.gz${NOCOLOR}"
			"${dd_in[@]}" | gzip -"${COMPRESSION_LEVEL}" > "${PART_BASE}.gz" &
		elif [ $CHECKSUM -eq 1 ]; then
			echo -e "${INFOCOLOR}${dd_in[*]} | tee >(sha256sum > ${PART_BASE}.sha256) | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | tee >(sha256sum > "${PART_BASE}.sha256") | "${dd_out[@]}" &
		else
			echo -e "${INFOCOLOR}${dd_in[*]} | ${dd_out[*]}${NOCOLOR}"
			"${dd_in[@]}" | "${dd_out[@]}" &
		fi
		register_job $! "Teil ${PART_NUM} (backup)"
	done
}

# Verwaltung der parallelen Hintergrund-Jobs:
# Jeder gestartete Teil-Job wird mit PID und Beschreibung registriert, damit
# wait_for_jobs die Exit-Codes einzeln einsammeln kann. Ein nacktes "wait"
# würde Fehler einzelner dd-/nc-Pipelines verschlucken.
JOB_PIDS=()
JOB_LABELS=()
# Ports, auf denen remote nc-Listener gestartet wurden (für Cleanup bei Abbruch)
REMOTE_LISTENER_PORTS=()

function register_job {
	JOB_PIDS+=("$1")
	JOB_LABELS+=("$2")
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

function cleanup_on_signal {
	trap - INT TERM
	echo -e "${WARNCOLOR}Abbruch: Beende laufende Teil-Prozesse ...${NOCOLOR}" >&2
	local pids port
	pids=$(jobs -p)
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086 # PIDs sind whitespace-getrennt gewollt
		kill $pids 2>/dev/null
		wait $pids 2>/dev/null
	fi
	if [ $REMOTE -eq 1 ] && is_ssh_socket_alive; then
		for port in "${REMOTE_LISTENER_PORTS[@]}"; do
			execute_remote_command "pkill -f 'nc -N -l ${port}'" 2>/dev/null
		done
		close_ssh_connection
	fi
	exit 130
}


################
# Script Start #
################
trap cleanup_on_signal INT TERM
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
    is_ssh_socket_alive
    if [ $? -ne 0 ]; then
        connect_ssh
    fi
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
                clone_block
                ;;
            "directory")
                echo -e "${ERRORCOLOR}Input-type is directory, which cannot be cloned using this script. Exiting ...${NOCOLOR}"
                INTERNAL_EXITCODE=1
                ;;
            *)
                echo "Try cloning this file..."
                clone_file
                ;;
        esac
        # Wait for all jobs to finish and collect their exit codes
        wait_for_jobs
        ;;
    "backup")
        backup_mode
        # Wait for all jobs to finish and collect their exit codes
        wait_for_jobs
        ;;
    *)
        echo "Ungültiger Modus: $MODE. Gültige Angaben: clone|backup"
        INTERNAL_EXITCODE=1
        ;;
esac

if [ $REMOTE -eq 1 ]; then
	close_ssh_connection
	if [ $? -eq 0 ]; then
		echo -e "${SUCCESSCOLOR}SSH-Verbindung zu ${REMOTE_HOST} erfolgreich gertrennt.${NOCOLOR}"
	fi
fi

exit ${INTERNAL_EXITCODE}
