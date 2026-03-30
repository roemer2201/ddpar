#!/bin/bash

# Standardwerte für die Parameter
INPUT_FILE=""
OUTPUT_PATH=""
MODE="clone"
NUM_JOBS="4"
BLOCKSIZEBYTES="1048576"
COMPRESSION=${COMPRESSION:-0}
CHECKSUM=${CHECKSUM:-0}
REMOTE=0
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
  echo "-c                      Komprimierung anfordern, Kompressionslevel zur Zeit nicht einstellbar (Default: -6)"
  echo "-s                      Checksumme der einzelnen Teile erstellen"
  echo "-f                      Force - ignore Probleme und erzwinge den Vorgang"
  echo "-r [lnc]                Remote-Verbindung, nur SSH möglich. Remote-Optionen: siehe unten"
  echo "-R user@host            Angabe des Remote-Host"
  echo "-h                      Diese Hilfe anzeigen"
  echo "-d                      Debug Modus"
  echo ""
  echo "Remote-Optionen:"
  echo "n: Standardeinstellung, No encryption, Verbindungsaufbau verschlüsselt, Datenübertragung unverschlüsselt"
  echo "l: Übertragung vollständig verschlüsselt, keine Kompression"
  echo "c: Aktiviert Remote-Kompression, Kompressionsvorgang erfolgt auf der Remote-Maschine"
  echo "   Ist \"-c, --compression\" aktiviert und wird \"-r ...\" ohne \"c\" verwendet, erfolgt die Kompression lokal"
}

function option_analysis {
  # Verwendung von getopts zur Verarbeitung der Optionen
  echo "Analysiere gegebene Optionen \"$*\""
  while getopts ":i:o:m:j:b:r::R:csfhd" opt; do
    case $opt in
      i) INPUT="${OPTARG}";;
      o) OUTPUT="${OPTARG}";;
      m) MODE="${OPTARG}";;
      j) NUM_JOBS="${OPTARG}";;
      b) BLOCKSIZEBYTES="${OPTARG}";;
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
        if [[ ${OPTARG} =~ ^[lnc]+$ ]]; then
          REMOTE_MODE="${OPTARG}"
        else
          REMOTE_MODE="l"
        fi
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
        sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
    else
        echo -e "${INFOCOLOR}Verbindungsaufbau mit Sockel ${control_path} zu ${target}${NOCOLOR}"
        ssh -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=yes -S "${control_path}" "${target}" true
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
    output=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 ${REMOTE_HOST} true 2>&1)
    
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
		# Führe den Befehl lokal aus
		${command}
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
    local commands=("dd" "nc" "df" "tee" "blockdev" "stat")  # Liste der zu überprüfenden Befehle
    
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

function input_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
  # Determine the type of the input file
  echo -e "${INFOCOLOR}Analysiere INPUT${NOCOLOR}"
  INPUT_FILE_TYPE=$(file -b ${INPUT})
  echo "\$INPUT_FILE_TYPE = $INPUT_FILE_TYPE"
  
  # Use the appropriate command to calculate the size of the input file
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    #echo "INPUT_SIZE=$(blockdev --getsize64 $INPUT)"
    INPUT_SIZE=$(blockdev --getsize64 ${INPUT})
    echo "\$INPUT_SIZE=${INPUT_SIZE=}"
  else
    INPUT_SIZE=$(stat -c %s ${INPUT})
    echo "\$INPUT_SIZE=${INPUT_SIZE=}"
  fi
}

function output_analysis {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Determine the type of the output file
	echo -e "${INFOCOLOR}Analysiere OUTPUT${NOCOLOR}"
	OUTPUT_FILE_TYPE=$(execute_command "file -b ${OUTPUT}")
	
	# Use the appropriate command to calculate the size of the output file
	echo "\$OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"
	if [[ "${OUTPUT_FILE_TYPE}" == "block special"* ]]; then
		OUTPUT_SIZE=$(execute_command "blockdev --getsize64 ${OUTPUT}")
		echo "\$OUTPUT_SIZE = $OUTPUT_SIZE"
	else
		OUTPUT_SIZE=$(execute_command "stat -c %s ${OUTPUT}")
		echo "\$OUTPUT_SIZE = $OUTPUT_SIZE"
	fi
	echo -e "${INFOCOLOR}${FUNCNAME[0]} abgeschlossen${NOCOLOR}"
}

function remote_port_generation {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    # Generiere eine Zufallszahl zwischen 0 und 45000
    REMOTE_PORT=$(( RANDOM % 55001 ))
    # Füge 10000 hinzu, um den Bereich auf 10000 bis 55000 zu erweitern und addiere zusätzlich
    REMOTE_PORT=$(( REMOTE_PORT + 10000 ))
}

function check_remote_port_availability {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
    execute_remote_command "ss -tln | grep -q \":${CURRENT_REMOTE_PORT}\""
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
  # Calculate the size of each input split file
  echo -e "${INFOCOLOR}Calculate the size of each input split file${NOCOLOR}"
  SPLIT_SIZE=$((INPUT_SIZE / NUM_JOBS))
  echo -e "${INFOCOLOR}Splitsize: ${SPLIT_SIZE}${NOCOLOR}"
  
  # Check if all sizes have whole numbers
  echo -e "${INFOCOLOR}Check if all sizes have whole numbers${NOCOLOR}"
  if [ $((INPUT_SIZE % NUM_JOBS)) -ne 0 ] || [ $((SPLIT_SIZE % BLOCKSIZEBYTES)) -ne 0 ]; then
    echo -e "${WARNCOLOR}WARN: The input file size (${INPUT_SIZE}) is not evenly divisible by the number of jobs (${NUM_JOBS}), or the resulting split size is not evenly divisible by defined blocksize in by bytes ($BLOCKSIZEBYTES).${NOCOLOR}"
    # Calculate the next higher usable job number
    echo -e "${INFOCOLOR}Calculate the next higher usable job number${NOCOLOR}"
      for ((i=${NUM_JOBS}; i<$((${NUM_JOBS}**2)); i++)); do
        if [ $((INPUT_SIZE % i)) -eq 0 ] && [ $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES)) -eq 0 ]; then
          #echo "i=${i} - ${INPUT_SIZE}/${NUM_JOBS} = $((INPUT_SIZE % i)) - SPLIT_SIZE: $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES))"
          echo -e "${SUCCESSCOLOR}INFO: The next higher usable Threadnumber is $i (at same Blocksize of ${BLOCKSIZEBYTES}${}"
          break
        fi
      done
    # Calculate the next lower usable job number
    echo -e "${INFOCOLOR}Calculate the next lower usable job number${NOCOLOR}"
      for ((i=$NUM_JOBS; i>0; i--)); do
        if [ $((INPUT_SIZE % i)) -eq 0 ] && [ $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES)) -eq 0 ]; then
          #echo "i=${i} - ${INPUT_SIZE}/${NUM_JOBS} = $((INPUT_SIZE % i)) - SPLIT_SIZE: $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES))"
          echo -e "${SUCCESSCOLOR}INFO: The next lower usable Threadnumber is $i (at same Blocksize of ${BLOCKSIZEBYTES}${NOCOLOR}"
          break
        fi
      done
    # Calculate the next higher usable blocksize number
    echo -e "${INFOCOLOR}Calculate the next higher usable blocksize number${NOCOLOR}"
    for ((i=$BLOCKSIZEBYTES; i<$(($BLOCKSIZEBYTES*4)); i++)); do
      if [ $((INPUT_SIZE % i)) -eq 0 ] && [ $(( $((INPUT_SIZE / i)) % NUM_JOBS)) -eq 0 ]; then
        #echo "i=${i} - ${INPUT_SIZE}/${NUM_JOBS} = $((INPUT_SIZE % i)) - SPLIT_SIZE: $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES))"
        echo -e "${SUCCESSCOLOR}INFO: The next higher usable blocksize number is $i (at same number of jobs (${NUM_JOBS}))${NOCOLOR}"
        break
      fi
    done
    # Calculate the next lower usable blocksize number
    echo -e "${INFOCOLOR}Calculate the next lower usable blocksize number${NOCOLOR}"
    for ((i=${BLOCKSIZEBYTES}; i>0; i--)); do
      if [ $((INPUT_SIZE % i)) -eq 0 ] && [ $(( $((INPUT_SIZE / i)) % NUM_JOBS)) -eq 0 ]; then
        #echo "i=${i} - ${INPUT_SIZE}/${NUM_JOBS} = $((INPUT_SIZE % i)) - SPLIT_SIZE: $(( $((INPUT_SIZE / i)) % BLOCKSIZEBYTES))"
        echo -e "${SUCCESSCOLOR}INFO: The next lower usable blocksize number is ${i} (at same number of jobs (${NUM_JOBS}))${NOCOLOR}"
        break
      fi
    done
    exit 1
  else
    echo -e "${SUCCESSCOLOR}All sizes seem even.${NOCOLOR}"
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
            if execute_command 'mkdir -p "${OUTPUT}"'; then
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
                if execute_command 'mkdir -p "${OUTPUT}"'; then
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
    for ((PART_NUM=0; PART_NUM<${NUM_JOBS}; PART_NUM++)); do
    
        # Build individual subcommands and concatinate, if enabled
        START=$((PART_NUM * SPLIT_SIZE))
        INPUT_CMD="dd if=${INPUT} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) skip=$((START / ${BLOCKSIZEBYTES}))"
        FULL_CMD="${INPUT_CMD}"
    
        OUTPUT_CMD="dd of=${OUTPUT_PATH} bs=${BLOCKSIZEBYTES} seek=$((START / ${BLOCKSIZEBYTES}))"
    
        # ToDo: create Metadata directory and write Checksum-Files
        #if [ $CHECKSUM -eq 1 ]; then
        #  CHECKSUM_CMD="tee >(sha256sum > ${OUTPUT_FILE}${PART_NUM}.sha256)"
        #  FULL_CMD="${FULL_CMD} | $CHECKSUM_CMD"
        #fi
        # ToDo: Compression only makes sense when transfering to remote location, implement later (this is just a copy from backup mode)
        #if [ $COMPRESSION -eq 1 ]; then
        #    if [ $PART_NUM -eq 0 ]; then
        #        #echo "Compression is enabled with \$COMPRESSION_LEVEL ${COMPRESSION_LEVEL}"
        #        # Append compression and its level to metadata file
        #        echo "COMPRESSION=${COMPRESSION}" >> ${METADATA_FILE}
        #        echo "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}" >> ${METADATA_FILE}
        #    fi
        #    COMPRESSION_CMD="gzip -${COMPRESSION_LEVEL} > ${OUTPUT_FILE}${PART_NUM}.gz"
        #    FULL_CMD="${FULL_CMD} | $COMPRESSION_CMD &"
        #else
        #    OUTPUT_CMD="dd of=${OUTPUT_FILE}${PART_NUM}.part bs=${BLOCKSIZEBYTES}"
        #    FULL_CMD="${FULL_CMD} | $OUTPUT_CMD &"
        #fi
        
        if [ $REMOTE -eq 1 ]; then
            # Generate and check remote ports
            if [ -z ${REMOTE_PORT} ]; then
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

            echo -e "${INFOCOLOR}REMOTE COMMAND: nc -N -l ${CURRENT_REMOTE_PORT} | ${OUTPUT_CMD}${NOCOLOR}"
            execute_remote_background_command "nc -N -l ${CURRENT_REMOTE_PORT} | ${OUTPUT_CMD}"
			
			# Check if execute_remote_background_command is running
			MAX_ATTEMPTS=3 # Anzahl der maximalen Versuche
			SLEEP_INTERVAL=1 # Wartezeit zwischen den Versuchen in Sekunden
			ATTEMPT=1	# Zähler für die aktuellen Versuche
			
			# Schleife, die den Status des Ports überprüft
			while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
				echo -e "${INFOCOLOR}Checking if remote process is running on port ${CURRENT_REMOTE_PORT} (attempt $ATTEMPT)...${NOCOLOR}"
				
				# Remote-Befehl zum Prüfen, ob der Prozess auf dem Port läuft
				if execute_remote_command "ss -tuln | grep -q :${CURRENT_REMOTE_PORT}"; then
					echo -e "${INFOCOLOR}Process found on port ${CURRENT_REMOTE_PORT}. Exiting loop.${NOCOLOR}"
					break
				else
					echo -e "${INFOCOLOR}Process not found on port ${CURRENT_REMOTE_PORT}.${NOCOLOR}"
				fi
			
				# Erhöhe den Versuchszähler
				ATTEMPT=$((ATTEMPT + 1))
			
				# Warte eine Sekunde vor dem nächsten Versuch, falls es noch Versuche gibt
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

            INPUT_CMD_REMOTE_EXTENSION="nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}"
            FULL_CMD="${FULL_CMD} | ${INPUT_CMD_REMOTE_EXTENSION} &"
        else
            FULL_CMD="${FULL_CMD} | ${OUTPUT_CMD} &"
        fi

        echo -e "${INFOCOLOR}${FULL_CMD}${NOCOLOR}"
        eval "${FULL_CMD}"
    
    done
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
    for ((PART_NUM=0; PART_NUM<${NUM_JOBS}; PART_NUM++)); do
		# Build individual subcommands and concatinate, if enabled
		START=$((PART_NUM * SPLIT_SIZE))
		INPUT_CMD="dd if=${INPUT} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) skip=$((START / ${BLOCKSIZEBYTES}))"
		FULL_CMD="${INPUT_CMD}"
		
		# ToDo: create Metadata directory and write Checksum-Files
		#if [ $CHECKSUM -eq 1 ]; then
		#  CHECKSUM_CMD="tee >(sha256sum > ${OUTPUT_FILE}${PART_NUM}.sha256)"
		#  FULL_CMD="${FULL_CMD} | $CHECKSUM_CMD"
		#fi
		# ToDo: Compression only makes sense when transfering to remote location, implement later (this is just a copy from backup mode)
		#if [ $COMPRESSION -eq 1 ]; then
		#    if [ $PART_NUM -eq 0 ]; then
		#        #echo "Compression is enabled with \$COMPRESSION_LEVEL ${COMPRESSION_LEVEL}"
		#        # Append compression and its level to metadata file
		#        echo "COMPRESSION=${COMPRESSION}" >> ${METADATA_FILE}
		#        echo "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}" >> ${METADATA_FILE}
		#    fi
		#    COMPRESSION_CMD="gzip -${COMPRESSION_LEVEL} > ${OUTPUT_FILE}${PART_NUM}.gz"
		#    FULL_CMD="${FULL_CMD} | $COMPRESSION_CMD &"
		#else
		#    OUTPUT_CMD="dd of=${OUTPUT_FILE}${PART_NUM}.part bs=${BLOCKSIZEBYTES}"
		#    FULL_CMD="${FULL_CMD} | $OUTPUT_CMD &"
		#fi
		
		OUTPUT_CMD="dd of=${OUTPUT} bs=${BLOCKSIZEBYTES} seek=$((START / ${BLOCKSIZEBYTES}))"
		
		if [ $REMOTE -eq 1 ]; then
            # Generate and check remote ports
            if [ -z ${REMOTE_PORT} ]; then
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

            echo -e "${INFOCOLOR}REMOTE COMMAND: nc -N -l ${CURRENT_REMOTE_PORT} | ${OUTPUT_CMD}${NOCOLOR}"
            execute_remote_background_command "nc -N -l ${CURRENT_REMOTE_PORT} | ${OUTPUT_CMD}"
			
			# Check if execute_remote_background_command is running
			MAX_ATTEMPTS=3 # Anzahl der maximalen Versuche
			SLEEP_INTERVAL=1 # Wartezeit zwischen den Versuchen in Sekunden
			ATTEMPT=1	# Zähler für die aktuellen Versuche
			
			# Schleife, die den Status des Ports überprüft
			while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
				echo -e "${INFOCOLOR}Checking if remote process is running on port ${CURRENT_REMOTE_PORT} (attempt $ATTEMPT)...${NOCOLOR}"
				
				# Remote-Befehl zum Prüfen, ob der Prozess auf dem Port läuft
				if execute_remote_command "ss -tuln | grep -q :${CURRENT_REMOTE_PORT}"; then
					echo -e "${INFOCOLOR}Process found on port ${CURRENT_REMOTE_PORT}. Exiting loop.${NOCOLOR}"
					break
				else
					echo -e "${INFOCOLOR}Process not found on port ${CURRENT_REMOTE_PORT}.${NOCOLOR}"
				fi
			
				# Erhöhe den Versuchszähler
				ATTEMPT=$((ATTEMPT + 1))
			
				# Warte eine Sekunde vor dem nächsten Versuch, falls es noch Versuche gibt
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

            INPUT_CMD_REMOTE_EXTENSION="nc ${REMOTE_HOST#*@} ${CURRENT_REMOTE_PORT}"
            FULL_CMD="${FULL_CMD} | ${INPUT_CMD_REMOTE_EXTENSION} &"
        else
            FULL_CMD="${FULL_CMD} | ${OUTPUT_CMD} &"
        fi
		
		echo -e "${INFOCOLOR}${FULL_CMD}${NOCOLOR}"
		eval ${FULL_CMD}
    done
}


################
# Script Start #
################
set_colors
option_analysis "$@"
input_analysis
size_calculation
if [ $REMOTE -eq 1 ]; then
    is_ssh_socket_alive
    if [ $? -ne 0 ]; then
        #echo -e "${WARNCOLOR}Not yet implemented, please support at https://github.com/roemer2201/ddpar${NOCOLOR}"
        #echo -e "${WARNCOLOR}This script will continue to run, but will end up in an undefined state.${NOCOLOR}"
		# connect_ssh seems finished, warnings above removed
        connect_ssh
        # check_commands_availability, auf remote ausführen
        # Variablen übergeben, zB. $COMPRESSION usw.
        
        # Determine the type of the output file
    fi
else
    # local Output analysis
    check_commands_availability
fi
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
        # Wait for all jobs to finish
        wait
        ;;
    "backup")
        if [[ "${OUTPUT_FILE_TYPE}" != *"directory"* ]]; then
            echo -e "${ERRORCOLOR}Fehler: Ungültiger Ausgabe-Typ ${OUTPUT_FILE_TYPE}. Erforderlich: directory.${NOCOLOR}"
            # Hier kannst du den Code für den Fehlerfall des Ausgabe-Typs einfügen
            exit 1
        fi
        # Freier Speicher im Zielpfad analysieren
        FREE_SPACE=$(df -P -B 1 "${OUTPUT}" | awk 'NR==2 {print $4}')
        if [ -z "$FORCE" ] && (( INPUT_SIZE > FREE_SPACE )); then
            echo -e "${ERRORCOLOR}Fehler: Eingabegröße (${INPUT_SIZE}) überschreitet den verfügbaren Speicherplatz (${FREE_SPACE}).${NOCOLOR}"
            exit 1
        fi
	if [ ! -z "$FORCE" ] && (( INPUT_SIZE > FREE_SPACE )); then
            echo -e "${WARNCOLOR}Warnung: Eingabegröße (${INPUT_SIZE}) überschreitet den verfügbaren Speicherplatz (${FREE_SPACE}). Mit aktiver Komprimierung koennte es dennoch passen.${NOCOLOR}"
	fi
        
        echo -e "${SUCCESSCOLOR}Führe die Backup-Aktion durch.${NOCOLOR}"

        # generate further spinoff variables
        INPUT_FILE_NAME=$(basename "${INPUT}")
        OUTPUT_FILE_NAME=${INPUT_FILE_NAME}
        OUTPUT_FILE="${OUTPUT}/${OUTPUT_FILE_NAME}-"
        METADATA_FILE="${OUTPUT_FILE}metadata.txt"
        
        # Write metadata file
        if [ -f ${METADATA_FILE} ]; then
            echo "Metadatafile already exists, copying it to ${METADATA_FILE}.old"
            cp -p ${METADATA_FILE} ${METADATA_FILE}.old
            cat /dev/null > ${METADATA_FILE}
        fi

        echo "NUM_JOBS=${NUM_JOBS}" >> ${METADATA_FILE}
        echo "FILE_NAME=${INPUT_FILE_NAME}" >> ${METADATA_FILE}
        echo "BLOCKSIZEBYTES=${BLOCKSIZEBYTES}" >> ${METADATA_FILE}
        echo "INPUT_SIZE=${INPUT_SIZE}" >> ${METADATA_FILE}
        echo "INPUT_FILE_NAME=${INPUT_FILE_NAME}" >> ${METADATA_FILE}
        echo "FILE_TYPE=${INPUT_FILE_TYPE}" >> ${METADATA_FILE}
        
        # Write to metadata file
        echo "SPLIT_SIZE=${SPLIT_SIZE}" >> ${METADATA_FILE}
        
        echo -e "${INFOCOLOR}Starte die Prozesse ...${NOCOLOR}"
        for ((PART_NUM=0; PART_NUM<${NUM_JOBS}; PART_NUM++)); do

        # Build individual subcommands and concatinate, if enabled
        START=$((PART_NUM * SPLIT_SIZE))
        INPUT_CMD="dd if=${INPUT} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) skip=$((START / ${BLOCKSIZEBYTES}))"
        FULL_CMD="${INPUT_CMD}"
        if [ $CHECKSUM -eq 1 ]; then
          CHECKSUM_CMD="tee >(sha256sum > ${OUTPUT_FILE}${PART_NUM}.sha256)"
          FULL_CMD="${FULL_CMD} | $CHECKSUM_CMD"
        fi
        if [ $COMPRESSION -eq 1 ]; then
            if [ $PART_NUM -eq 0 ]; then
                #echo "Compression is enabled with \$COMPRESSION_LEVEL ${COMPRESSION_LEVEL}"
                # Append compression and its level to metadata file
                echo "COMPRESSION=${COMPRESSION}" >> ${METADATA_FILE}
                echo "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}" >> ${METADATA_FILE}
            fi
            COMPRESSION_CMD="gzip -${COMPRESSION_LEVEL} > ${OUTPUT_FILE}${PART_NUM}.gz"
            FULL_CMD="${FULL_CMD} | $COMPRESSION_CMD &"
        else
            OUTPUT_CMD="dd of=${OUTPUT_FILE}${PART_NUM}.part bs=${BLOCKSIZEBYTES}"
            FULL_CMD="${FULL_CMD} | $OUTPUT_CMD &"
        fi
        echo "${INFOCOLOR}${FULL_CMD}${NOCOLOR}"
        eval ${FULL_CMD}
        done
        
        
        ## Run `dd` in parallel to copy each split file and compress the output with gzip
        ## The following lines were used in the past, when the full command was not dynamically build
        #for ((PART_NUM=0; PART_NUM<${NUM_JOBS}; PART_NUM++)); do
        #  START=$((PART_NUM * SPLIT_SIZE))
        #  echo "dd if=${INPUT} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) skip=$((START / ${BLOCKSIZEBYTES})) | tee >(sha256sum > ${OUTPUT_FILE}${PART_NUM}.sha256) | gzip > ${OUTPUT_FILE}${PART_NUM}.gz &"
        #  dd if=${INPUT} bs=${BLOCKSIZEBYTES} count=$((SPLIT_SIZE / ${BLOCKSIZEBYTES})) skip=$((START / ${BLOCKSIZEBYTES})) | tee >(sha256sum > ${OUTPUT_FILE}${PART_NUM}.sha256) | gzip > ${OUTPUT_FILE}${PART_NUM}.gz &
        #done

        # Wait for all jobs to finish
        wait
        ;;
    *)
        echo "Ungültiger Modus: $MODE. Gültige Angaben: clone|backup"
        ;;
esac

if [ $REMOTE -eq 1 ]; then
	close_ssh_connection
	if [ $? -eq 0 ]; then
		echo -e "${SUCCESSCOLOR}SSH-Verbindung zu ${REMOTE_HOST} erfolgreich gertrennt.${NOCOLOR}"
	fi
fi

exit ${INTERNAL_EXITCODE}
