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
  echo "n: Standardeinstellung, No encryption, Verbindungsaufbau verschlüsselt (SSH),"
  echo "   Datenübertragung unverschlüsselt über netcat (nur in vertrauenswürdigen Netzen verwenden!)"
  echo "l: GEPLANT, noch nicht implementiert: Übertragung vollständig verschlüsselt"
  echo "c: GEPLANT, noch nicht implementiert: Kompression auf der Remote-Maschine"
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
        # Bisher ist nur Modus "n" (netcat, Datenkanal unverschlüsselt)
        # implementiert. "l" (verschlüsselt) und "c" (Remote-Kompression)
        # sind geplant — hier ehrlich warnen statt still zurückzufallen.
        if [[ ${OPTARG} =~ [lc] ]]; then
          echo -e "${WARNCOLOR}[WARN] Remote-Modus '${OPTARG}' ist noch nicht implementiert. Es wird 'n' verwendet: Datenübertragung unverschlüsselt über netcat.${NOCOLOR}"
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

function detect_local_nics {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Multi-NIC Stufe 1a: Ermittelt alle lokalen Netzwerk-Interfaces mit
	# aktivem Link (Carrier) samt Link-Geschwindigkeit und primärer
	# IPv4-Adresse. Ergebnis in globalen Arrays, absteigend nach
	# Geschwindigkeit sortiert (schnellste NIC zuerst):
	#   LOCAL_NICS[i]        Interface-Name (z.B. eth0)
	#   LOCAL_NIC_SPEEDS[i]  Link-Geschwindigkeit in Mbit/s (0 = unbekannt)
	#   LOCAL_NIC_IPS[i]     primäre IPv4-Adresse (leer = keine)
	# DDPAR_SYSFS_NET erlaubt Tests mit einem nachgebauten sysfs-Baum.
	local sysfs_net="${DDPAR_SYSFS_NET:-/sys/class/net}"
	LOCAL_NICS=()
	LOCAL_NIC_SPEEDS=()
	LOCAL_NIC_IPS=()

	local nic_path nic speed nic_ip
	local unsorted=()
	for nic_path in "${sysfs_net}"/*; do
		[ -e "${nic_path}" ] || continue
		nic=$(basename "${nic_path}")
		# Loopback ist für Remote-Übertragungen irrelevant
		[ "${nic}" = "lo" ] && continue
		# Nur Interfaces mit aktivem Link berücksichtigen (carrier == 1;
		# bei heruntergefahrenen Interfaces schlägt das Lesen fehl)
		[ "$(cat "${nic_path}/carrier" 2>/dev/null)" = "1" ] || continue
		# Link-Geschwindigkeit in Mbit/s; -1 oder unlesbar (z.B. WLAN,
		# virtio) wird als 0 = unbekannt behandelt und zuletzt einsortiert
		speed=$(cat "${nic_path}/speed" 2>/dev/null)
		if ! [[ "${speed}" =~ ^[0-9]+$ ]]; then
			speed=0
		fi
		# Primäre IPv4-Adresse (für Source-Binding der Erreichbarkeitsprüfung)
		nic_ip=$(ip -4 -o addr show dev "${nic}" scope global 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')
		unsorted+=("${speed} ${nic} ${nic_ip}")
	done

	if [ ${#unsorted[@]} -eq 0 ]; then
		echo -e "${WARNCOLOR}[WARN] Keine aktiven Netzwerk-Interfaces gefunden.${NOCOLOR}"
		return 1
	fi

	# Absteigend nach Geschwindigkeit sortieren (schnellste zuerst)
	while read -r speed nic nic_ip; do
		LOCAL_NICS+=("${nic}")
		LOCAL_NIC_SPEEDS+=("${speed}")
		LOCAL_NIC_IPS+=("${nic_ip}")
	done < <(printf '%s\n' "${unsorted[@]}" | sort -rn -k1,1)

	echo -e "${INFOCOLOR}${#LOCAL_NICS[@]} aktive(s) Netzwerk-Interface(s) gefunden:${NOCOLOR}"
	local i
	for i in "${!LOCAL_NICS[@]}"; do
		echo -e "${INFOCOLOR}  ${LOCAL_NICS[$i]}: ${LOCAL_NIC_SPEEDS[$i]} Mbit/s, IPv4: ${LOCAL_NIC_IPS[$i]:-keine}${NOCOLOR}"
	done
	return 0
}

function nic_can_reach_remote {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Prüft, ob das Ziel $3 über das Interface $1 (primäre IPv4 $2) erreichbar
	# ist. Zuerst ICMP mit Interface-Binding (ping -I); falls ICMP gefiltert
	# wird oder ping fehlt, TCP-Probe auf den SSH-Port 22 mit Source-IP-Binding.
	local nic=$1
	local src_ip=$2
	local target=$3

	if command -v ping > /dev/null 2>&1; then
		if ping -c 1 -W 2 -I "${nic}" "${target}" > /dev/null 2>&1; then
			return 0
		fi
	fi
	if [ -n "${src_ip}" ]; then
		if nc -z -w 2 -s "${src_ip}" "${target}" 22 > /dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

function check_nic_remote_reachability {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Multi-NIC Stufe 1b: Prüft von der schnellsten NIC abwärts, ob das
	# Remote-Ziel (REMOTE_HOST, ohne user@-Prefix) über das jeweilige
	# Interface erreichbar ist. Erwartet, dass detect_local_nics vorher
	# gelaufen ist. Ergebnis in globalen Arrays, absteigend nach
	# Geschwindigkeit sortiert:
	#   REACHABLE_NICS[i]/REACHABLE_NIC_SPEEDS[i]/REACHABLE_NIC_IPS[i]
	# FASTEST_REACHABLE_NIC enthält die schnellste erreichbare NIC.
	local remote_addr=${REMOTE_HOST#*@}
	REACHABLE_NICS=()
	REACHABLE_NIC_SPEEDS=()
	REACHABLE_NIC_IPS=()
	FASTEST_REACHABLE_NIC=""

	if [ -z "${remote_addr}" ]; then
		echo -e "${ERRORCOLOR}Fehler: Kein Remote-Host angegeben.${NOCOLOR}"
		return 1
	fi
	if [ ${#LOCAL_NICS[@]} -eq 0 ]; then
		echo -e "${ERRORCOLOR}Fehler: Keine lokalen NICs bekannt. detect_local_nics muss zuerst laufen.${NOCOLOR}"
		return 1
	fi

	echo -e "${INFOCOLOR}Prüfe Erreichbarkeit von ${remote_addr} je Interface (schnellste zuerst):${NOCOLOR}"
	local i nic speed nic_ip
	for i in "${!LOCAL_NICS[@]}"; do
		nic=${LOCAL_NICS[$i]}
		speed=${LOCAL_NIC_SPEEDS[$i]}
		nic_ip=${LOCAL_NIC_IPS[$i]}
		if nic_can_reach_remote "${nic}" "${nic_ip}" "${remote_addr}"; then
			echo -e "${SUCCESSCOLOR}  ${nic} (${speed} Mbit/s): ${remote_addr} erreichbar${NOCOLOR}"
			REACHABLE_NICS+=("${nic}")
			REACHABLE_NIC_SPEEDS+=("${speed}")
			REACHABLE_NIC_IPS+=("${nic_ip}")
		else
			echo -e "${INFOCOLOR}  ${nic} (${speed} Mbit/s): ${remote_addr} nicht erreichbar${NOCOLOR}"
		fi
	done

	if [ ${#REACHABLE_NICS[@]} -eq 0 ]; then
		echo -e "${WARNCOLOR}[WARN] ${remote_addr} ist über keine NIC direkt erreichbar.${NOCOLOR}"
		return 1
	fi
	FASTEST_REACHABLE_NIC="${REACHABLE_NICS[0]}"
	echo -e "${SUCCESSCOLOR}Schnellste erreichbare NIC: ${FASTEST_REACHABLE_NIC} (${REACHABLE_NIC_SPEEDS[0]} Mbit/s)${NOCOLOR}"
	return 0
}

function exchange_remote_nic_info {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Multi-NIC Stufe 2a: Fragt über die bestehende SSH-Verbindung ab, wie
	# viele NICs das Remote-Ziel hat und mit welcher Geschwindigkeit. Das
	# Remote-Kommando ist POSIX-kompatibel (Remote-Shell kann dash sein) und
	# nutzt dieselbe sysfs-Logik wie detect_local_nics. Ergebnis in globalen
	# Arrays, absteigend nach Geschwindigkeit sortiert:
	#   REMOTE_NICS[i]/REMOTE_NIC_SPEEDS[i]/REMOTE_NIC_IPS[i]
	REMOTE_NICS=()
	REMOTE_NIC_SPEEDS=()
	REMOTE_NIC_IPS=()

	local inventory_cmd='for n in /sys/class/net/*; do i=$(basename "$n"); [ "$i" = "lo" ] && continue; [ "$(cat "$n/carrier" 2>/dev/null)" = "1" ] || continue; s=$(cat "$n/speed" 2>/dev/null); case "$s" in ""|*[!0-9]*) s=0;; esac; a=$(ip -4 -o addr show dev "$i" scope global 2>/dev/null | head -n1 | tr -s " " | cut -d" " -f4 | cut -d/ -f1); echo "$s $i $a"; done'
	local inventory
	inventory=$(execute_remote_command "${inventory_cmd}")
	if [ -z "${inventory}" ]; then
		echo -e "${WARNCOLOR}[WARN] Remote-NIC-Inventar konnte nicht ermittelt werden.${NOCOLOR}"
		return 1
	fi

	local speed nic nic_ip
	while read -r speed nic nic_ip; do
		[ -n "${nic}" ] || continue
		# Defensive Prüfung, falls die Remote-Seite Unerwartetes liefert
		case "${speed}" in ''|*[!0-9]*) speed=0;; esac
		REMOTE_NICS+=("${nic}")
		REMOTE_NIC_SPEEDS+=("${speed}")
		REMOTE_NIC_IPS+=("${nic_ip}")
	done < <(printf '%s\n' "${inventory}" | sort -rn -k1,1)

	if [ ${#REMOTE_NICS[@]} -eq 0 ]; then
		echo -e "${WARNCOLOR}[WARN] Remote-NIC-Inventar konnte nicht ermittelt werden.${NOCOLOR}"
		return 1
	fi

	echo -e "${INFOCOLOR}Remote-Ziel meldet ${#REMOTE_NICS[@]} aktive(s) Netzwerk-Interface(s):${NOCOLOR}"
	local i
	for i in "${!REMOTE_NICS[@]}"; do
		echo -e "${INFOCOLOR}  ${REMOTE_NICS[$i]}: ${REMOTE_NIC_SPEEDS[$i]} Mbit/s, IPv4: ${REMOTE_NIC_IPS[$i]:-keine}${NOCOLOR}"
	done
	return 0
}

function select_transfer_link {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Multi-NIC Stufe 2b: Wählt aus den erreichbaren lokalen NICs (Stufe 1b)
	# und dem Remote-Inventar (Stufe 2a) das Paar mit der höchsten effektiven
	# Geschwindigkeit min(lokal, remote), dessen Remote-IP über die lokale
	# NIC tatsächlich erreichbar ist. Unbekannte Geschwindigkeiten (0) werden
	# zuletzt probiert. Ergebnis:
	#   SELECTED_LOCAL_NIC/SELECTED_LOCAL_IP     gewählte lokale Seite
	#   SELECTED_REMOTE_NIC/SELECTED_REMOTE_IP   gewählte Remote-Seite
	#   SELECTED_LINK_SPEED                      effektive Geschwindigkeit (Mbit/s)
	# Rückgabe 1 (und leere SELECTED_*-Variablen): keine optimierte Auswahl
	# möglich, der Datenkanal nutzt dann die SSH-Adresse (remote_transfer_addr).
	SELECTED_LOCAL_NIC=""
	SELECTED_LOCAL_IP=""
	SELECTED_REMOTE_NIC=""
	SELECTED_REMOTE_IP=""
	SELECTED_LINK_SPEED=""

	if [ ${#REACHABLE_NICS[@]} -eq 0 ] || [ ${#REMOTE_NICS[@]} -eq 0 ]; then
		echo -e "${WARNCOLOR}[WARN] Keine Link-Auswahl möglich: lokale Erreichbarkeitsprüfung oder Remote-Inventar fehlt.${NOCOLOR}"
		return 1
	fi

	# Kandidatenpaare (lokale NIC, Remote-NIC) mit effektiver Geschwindigkeit
	local i j eff
	local candidates=()
	for i in "${!REACHABLE_NICS[@]}"; do
		for j in "${!REMOTE_NICS[@]}"; do
			# Remote-NICs ohne IPv4-Adresse sind kein netcat-Ziel
			[ -n "${REMOTE_NIC_IPS[$j]}" ] || continue
			eff=$(( REACHABLE_NIC_SPEEDS[i] < REMOTE_NIC_SPEEDS[j] ? REACHABLE_NIC_SPEEDS[i] : REMOTE_NIC_SPEEDS[j] ))
			candidates+=("${eff} ${i} ${j}")
		done
	done
	if [ ${#candidates[@]} -eq 0 ]; then
		echo -e "${WARNCOLOR}[WARN] Keine Link-Auswahl möglich: Remote-Ziel meldet keine IPv4-Adressen.${NOCOLOR}"
		return 1
	fi

	echo -e "${INFOCOLOR}Prüfe Link-Kandidaten (höchste effektive Geschwindigkeit zuerst):${NOCOLOR}"
	# Stabiler Sort (-s): bei gleicher effektiver Geschwindigkeit (z.B.
	# unbekannt = 0) bleibt die Erzeugungsreihenfolge erhalten, d.h. die
	# jeweils schnellere lokale bzw. Remote-NIC wird zuerst probiert.
	local local_nic local_ip remote_nic remote_ip
	while read -r eff i j; do
		local_nic=${REACHABLE_NICS[$i]}
		local_ip=${REACHABLE_NIC_IPS[$i]}
		remote_nic=${REMOTE_NICS[$j]}
		remote_ip=${REMOTE_NIC_IPS[$j]}
		if nic_can_reach_remote "${local_nic}" "${local_ip}" "${remote_ip}"; then
			echo -e "${SUCCESSCOLOR}  ${local_nic} → ${remote_ip} (${remote_nic}): erreichbar, effektiv ${eff} Mbit/s${NOCOLOR}"
			SELECTED_LOCAL_NIC=${local_nic}
			SELECTED_LOCAL_IP=${local_ip}
			SELECTED_REMOTE_NIC=${remote_nic}
			SELECTED_REMOTE_IP=${remote_ip}
			SELECTED_LINK_SPEED=${eff}
			break
		else
			echo -e "${INFOCOLOR}  ${local_nic} → ${remote_ip} (${remote_nic}): nicht erreichbar${NOCOLOR}"
		fi
	done < <(printf '%s\n' "${candidates[@]}" | sort -srn -k1,1)

	if [ -z "${SELECTED_REMOTE_IP}" ]; then
		echo -e "${WARNCOLOR}[WARN] Kein Link-Kandidat erreichbar.${NOCOLOR}"
		return 1
	fi
	echo -e "${SUCCESSCOLOR}Link-Auswahl: ${SELECTED_LOCAL_NIC} → ${SELECTED_REMOTE_IP} (${SELECTED_REMOTE_NIC}), effektiv ${SELECTED_LINK_SPEED} Mbit/s${NOCOLOR}"
	return 0
}

function remote_transfer_addr {
	# Zieladresse für den netcat-Datenkanal: die von select_transfer_link
	# gewählte Remote-IP; ohne Auswahl die SSH-Adresse aus REMOTE_HOST.
	echo "${SELECTED_REMOTE_IP:-${REMOTE_HOST#*@}}"
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

function run_clone_parts {
	[ "$DEBUG" -eq 1 ] && echo -e "${DEBUGCOLOR}[DEBUG] Funktion ${FUNCNAME[0]} aufgerufen${NOCOLOR}" >&2
	# Startet die parallelen dd-Teil-Prozesse eines Clone-Vorgangs.
	# $1 = Ausgabeziel (Datei oder Blockgerät); bei REMOTE=1 wird pro Teil
	# ein nc-Listener auf dem Remote-Host eingerichtet.
	# ToDo: Checksum/Kompression für Clone analog zum Backup-Modus umsetzen.
	local output_target=$1
	local PART_NUM START COUNT_BYTES
	local dd_in dd_out

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
			if ! setup_remote_listener "dd of=\"${output_target}\" bs=${BLOCKSIZEBYTES} oflag=seek_bytes seek=${START} conv=notrunc"; then
				echo -e "${ERRORCOLOR}Remote-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				return 1
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc $(remote_transfer_addr) ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc "$(remote_transfer_addr)" "${CURRENT_REMOTE_PORT}" &
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
	OUTPUT_FILE_NAME=${INPUT_FILE_NAME}
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
	append_metadata "FILE_NAME=${INPUT_FILE_NAME}"
	append_metadata "BLOCKSIZEBYTES=${BLOCKSIZEBYTES}"
	append_metadata "INPUT_SIZE=${INPUT_SIZE}"
	append_metadata "INPUT_FILE_NAME=${INPUT_FILE_NAME}"
	append_metadata "FILE_TYPE=${INPUT_FILE_TYPE}"
	append_metadata "SPLIT_SIZE=${SPLIT_SIZE}"

	if [ $COMPRESSION -eq 1 ] && [ $REMOTE -ne 1 ]; then
		append_metadata "COMPRESSION=${COMPRESSION}"
		append_metadata "COMPRESSION_LEVEL=${COMPRESSION_LEVEL}"
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

		if [ $REMOTE -eq 1 ]; then
			# Remote netcat backup, unkomprimiert, ohne Checksumme. Die
			# Empfängerseite läuft auf dem Remote-Host (String via SSH).
			if ! setup_remote_listener "dd of=\"${PART_BASE}.part\" bs=${BLOCKSIZEBYTES}"; then
				echo -e "${ERRORCOLOR}Remote-Backup-Empfänger für Teil ${PART_NUM} konnte nicht gestartet werden.${NOCOLOR}"
				break
			fi
			echo -e "${INFOCOLOR}${dd_in[*]} | nc $(remote_transfer_addr) ${CURRENT_REMOTE_PORT}${NOCOLOR}"
			"${dd_in[@]}" | nc "$(remote_transfer_addr)" "${CURRENT_REMOTE_PORT}" &
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
# Test-Hook: Mit DDPAR_SOURCE_ONLY=1 gesourct werden nur die Funktionen
# geladen, der Hauptteil läuft nicht (für Unit-Tests, siehe tests/nics.bats).
if [ "${DDPAR_SOURCE_ONLY:-0}" -eq 1 ]; then
	return 0 2>/dev/null || exit 0
fi
trap cleanup_on_signal INT TERM
set_colors
option_analysis "$@"
input_analysis
size_calculation
if [ $REMOTE -eq 1 ]; then
    # Multi-NIC (Stufe 1): lokale Interfaces samt Geschwindigkeit ermitteln
    # und die Erreichbarkeit des Remote-Ziels je NIC prüfen (schnellste
    # zuerst). Das Ergebnis (REACHABLE_NICS) ist die Grundlage für die
    # Link-Auswahl in Stufe 2 nach dem SSH-Aufbau.
    if detect_local_nics; then
        if ! check_nic_remote_reachability; then
            echo -e "${WARNCOLOR}[WARN] NIC-Erreichbarkeitsprüfung ohne Ergebnis, es wird das Standard-Routing verwendet.${NOCOLOR}"
        fi
    fi
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
    # Multi-NIC (Stufe 2): Remote-NIC-Inventar über die SSH-Verbindung
    # abfragen und den Link mit der höchsten effektiven Geschwindigkeit
    # wählen. Der netcat-Datenkanal verbindet sich dann mit der gewählten
    # Remote-IP (remote_transfer_addr); ohne erfolgreiche Auswahl bleibt es
    # bei der SSH-Adresse aus REMOTE_HOST.
    if [ ${#REACHABLE_NICS[@]} -gt 0 ]; then
        if exchange_remote_nic_info; then
            if ! select_transfer_link; then
                echo -e "${WARNCOLOR}[WARN] Keine optimierte Link-Auswahl möglich, netcat nutzt die SSH-Adresse ${REMOTE_HOST#*@}.${NOCOLOR}"
            fi
        fi
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
