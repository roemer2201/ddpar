#!/usr/bin/env bats
#
# Multi-NIC Stufe 1: detect_local_nics (1a) und check_nic_remote_reachability (1b).
# Die Funktionen werden über den Source-Guard (DDPAR_SOURCE_ONLY=1) aus
# ddpar.sh geladen. detect_local_nics liest den sysfs-Baum aus
# DDPAR_SYSFS_NET, sodass die Tests unabhängig von den echten NICs des
# Testrechners laufen; ping/nc werden über PATH-Stubs ersetzt.

load helpers

# Legt eine Fake-NIC im nachgebauten sysfs-Baum an.
# Aufruf: make_fake_nic <name> <carrier 0|1> <speed|->
#         speed "-" legt keine speed-Datei an (z.B. WLAN/virtio)
make_fake_nic() {
  local name="$1" carrier="$2" speed="$3"
  mkdir -p "$TMP/sysnet/$name"
  echo "$carrier" > "$TMP/sysnet/$name/carrier"
  if [ "$speed" != "-" ]; then
    echo "$speed" > "$TMP/sysnet/$name/speed"
  fi
}

# Führt eine Funktion aus ddpar.sh in einer frischen Bash aus.
# Aufruf: run_ddpar_fn "<bash-code nach dem Sourcen>"
run_ddpar_fn() {
  vrun env DDPAR_SOURCE_ONLY=1 DDPAR_SYSFS_NET="$TMP/sysnet" \
    bash -c "source '$REPO_ROOT/ddpar.sh'; $1"
}

# --- 1a: detect_local_nics ---

@test "detect_local_nics listet NICs mit Carrier absteigend nach Geschwindigkeit" {
  make_fake_nic eth0 1 1000
  make_fake_nic eth1 1 10000
  make_fake_nic eth2 1 100
  run_ddpar_fn 'detect_local_nics; printf "%s\n" "${LOCAL_NICS[@]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 aktive(s) Netzwerk-Interface(s) gefunden"* ]]
  # Reihenfolge: schnellste zuerst
  [[ "$output" == *$'eth1\neth0\neth2'* ]]
}

@test "detect_local_nics überspringt lo und NICs ohne Carrier" {
  mkdir -p "$TMP/sysnet/lo"
  make_fake_nic eth0 1 1000
  make_fake_nic eth1 0 10000
  run_ddpar_fn 'detect_local_nics; echo "COUNT=${#LOCAL_NICS[@]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=1"* ]]
  [[ "$output" != *"eth1:"* ]]
}

@test "detect_local_nics behandelt unbekannte Geschwindigkeit als 0 und sortiert sie zuletzt" {
  make_fake_nic wlan0 1 -
  make_fake_nic eth0 1 100
  run_ddpar_fn 'detect_local_nics; printf "%s=%s\n" "${LOCAL_NICS[0]}" "${LOCAL_NIC_SPEEDS[0]}" "${LOCAL_NICS[1]}" "${LOCAL_NIC_SPEEDS[1]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eth0=100"* ]]
  [[ "$output" == *"wlan0=0"* ]]
}

@test "detect_local_nics scheitert ohne aktive Interfaces mit Code 1" {
  mkdir -p "$TMP/sysnet/lo"
  make_fake_nic eth0 0 1000
  run_ddpar_fn 'detect_local_nics'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Keine aktiven Netzwerk-Interfaces"* ]]
}

# --- 1b: check_nic_remote_reachability ---

# Stub-Verzeichnis mit ping/nc, deren Verhalten über Marker-Dateien gesteuert
# wird: existiert $TMP/reachable.<nic>, ist jedes Ziel über diese NIC per ping
# erreichbar; $TMP/reachable.<nic>.<ziel> nur das konkrete Ziel (für die
# paargenauen Link-Auswahl-Tests). $TMP/tcp.<src-ip> bzw.
# $TMP/tcp.<src-ip>.<ziel> analog für die nc-TCP-Probe.
make_net_stubs() {
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/ping" <<STUB
#!/bin/bash
# Argument nach -I ist die NIC, letztes Argument das Ziel
while [ \$# -gt 0 ]; do
  [ "\$1" = "-I" ] && nic="\$2"
  target="\$1"
  shift
done
[ -e "$TMP/reachable.\$nic" ] || [ -e "$TMP/reachable.\$nic.\$target" ]
STUB
  cat > "$TMP/stubbin/nc" <<STUB
#!/bin/bash
# Argument nach -s ist die Source-IP, vorletztes Argument das Ziel (danach Port)
while [ \$# -gt 0 ]; do
  [ "\$1" = "-s" ] && src="\$2"
  target="\$prev"
  prev="\$1"
  shift
done
[ -e "$TMP/tcp.\$src" ] || [ -e "$TMP/tcp.\$src.\$target" ]
STUB
  chmod +x "$TMP/stubbin/ping" "$TMP/stubbin/nc"
}

# Legt einen ssh-Stub an, der auf das NIC-Inventar-Kommando (Stufe 2a) die
# übergebenen Inventarzeilen ("<speed> <nic> <ip>") ausgibt.
# Aufruf: make_ssh_inventory_stub $'1000 eth0 192.168.1.100\n10000 eth1 10.0.0.5'
make_ssh_inventory_stub() {
  local inventory="$1"
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/ssh" <<STUB
#!/bin/bash
cmd="\${@: -1}"
case "\$cmd" in
  *"/sys/class/net"*) printf '%s\n' "$inventory"; exit 0;;
  *) exit 0;;
esac
STUB
  chmod +x "$TMP/stubbin/ssh"
}

# Wie run_ddpar_fn, aber mit ping/nc-Stubs im PATH.
run_ddpar_fn_stubbed() {
  vrun env DDPAR_SOURCE_ONLY=1 DDPAR_SYSFS_NET="$TMP/sysnet" \
    PATH="$TMP/stubbin:$PATH" \
    bash -c "source '$REPO_ROOT/ddpar.sh'; $1"
}

@test "check_nic_remote_reachability findet die schnellste erreichbare NIC" {
  make_fake_nic eth0 1 1000
  make_fake_nic eth1 1 10000
  make_net_stubs
  touch "$TMP/reachable.eth0"   # nur die langsame NIC erreicht das Ziel
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; detect_local_nics >/dev/null; check_nic_remote_reachability; echo "FASTEST=$FASTEST_REACHABLE_NIC"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eth1 (10000 Mbit/s): ziel nicht erreichbar"* ]]
  [[ "$output" == *"eth0 (1000 Mbit/s): ziel erreichbar"* ]]
  [[ "$output" == *"FASTEST=eth0"* ]]
}

@test "check_nic_remote_reachability prüft schnellste NIC zuerst und wählt sie bei Erfolg" {
  make_fake_nic eth0 1 1000
  make_fake_nic eth1 1 10000
  make_net_stubs
  touch "$TMP/reachable.eth0" "$TMP/reachable.eth1"
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; detect_local_nics >/dev/null; check_nic_remote_reachability; printf "%s\n" "${REACHABLE_NICS[@]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'eth1\neth0'* ]]
  [[ "$output" == *"Schnellste erreichbare NIC: eth1 (10000 Mbit/s)"* ]]
}

@test "check_nic_remote_reachability scheitert, wenn keine NIC das Ziel erreicht" {
  make_fake_nic eth0 1 1000
  make_net_stubs
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; detect_local_nics >/dev/null; check_nic_remote_reachability'
  [ "$status" -eq 1 ]
  [[ "$output" == *"über keine NIC direkt erreichbar"* ]]
}

@test "check_nic_remote_reachability scheitert ohne vorheriges detect_local_nics" {
  run_ddpar_fn 'REMOTE_HOST=user@ziel; check_nic_remote_reachability'
  [ "$status" -eq 1 ]
  [[ "$output" == *"detect_local_nics muss zuerst laufen"* ]]
}

@test "check_nic_remote_reachability scheitert ohne REMOTE_HOST" {
  make_fake_nic eth0 1 1000
  run_ddpar_fn 'detect_local_nics >/dev/null; check_nic_remote_reachability'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Kein Remote-Host angegeben"* ]]
}

# --- 2a: exchange_remote_nic_info ---

@test "exchange_remote_nic_info sortiert das Remote-Inventar absteigend nach Geschwindigkeit" {
  make_ssh_inventory_stub $'1000 eth0 192.168.1.100\n10000 eth1 10.0.0.5'
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; exchange_remote_nic_info; printf "%s\n" "${REMOTE_NICS[@]}"; echo "IP0=${REMOTE_NIC_IPS[0]} SPEED0=${REMOTE_NIC_SPEEDS[0]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remote-Ziel meldet 2 aktive(s) Netzwerk-Interface(s)"* ]]
  [[ "$output" == *$'eth1\neth0'* ]]
  [[ "$output" == *"IP0=10.0.0.5 SPEED0=10000"* ]]
}

@test "exchange_remote_nic_info behandelt fehlende IP und unbekannte Geschwindigkeit" {
  make_ssh_inventory_stub $'0 tap0\n2500 eth0 172.16.0.2'
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; exchange_remote_nic_info'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eth0: 2500 Mbit/s, IPv4: 172.16.0.2"* ]]
  [[ "$output" == *"tap0: 0 Mbit/s, IPv4: keine"* ]]
}

@test "exchange_remote_nic_info scheitert bei leerem Inventar" {
  make_ssh_inventory_stub ''
  run_ddpar_fn_stubbed 'REMOTE_HOST=user@ziel; exchange_remote_nic_info'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Remote-NIC-Inventar konnte nicht ermittelt werden"* ]]
}

# --- 2b: select_transfer_link ---

# Setzt die Ergebnis-Arrays von Stufe 1b und 2a direkt, um die Auswahllogik
# isoliert zu testen: lokal eth1 (10G, 10.0.0.6) und eth0 (1G, 192.168.1.6),
# remote eth1 (10G, 10.0.0.5) und eth0 (1G, 192.168.1.100).
SELECT_FIXTURE='REACHABLE_NICS=(eth1 eth0); REACHABLE_NIC_SPEEDS=(10000 1000); REACHABLE_NIC_IPS=(10.0.0.6 192.168.1.6);
REMOTE_NICS=(eth1 eth0); REMOTE_NIC_SPEEDS=(10000 1000); REMOTE_NIC_IPS=(10.0.0.5 192.168.1.100);
REMOTE_HOST=user@192.168.1.100;'

@test "select_transfer_link wählt das Paar mit der höchsten effektiven Geschwindigkeit" {
  make_net_stubs
  touch "$TMP/reachable.eth1.10.0.0.5" "$TMP/reachable.eth0.192.168.1.100"
  run_ddpar_fn_stubbed "$SELECT_FIXTURE"'select_transfer_link; echo "SEL=$SELECTED_LOCAL_NIC>$SELECTED_REMOTE_IP@$SELECTED_LINK_SPEED"; echo "ADDR=$(remote_transfer_addr)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Link-Auswahl: eth1 → 10.0.0.5 (eth1), effektiv 10000 Mbit/s"* ]]
  [[ "$output" == *"SEL=eth1>10.0.0.5@10000"* ]]
  [[ "$output" == *"ADDR=10.0.0.5"* ]]
}

@test "select_transfer_link weicht auf den nächsten Kandidaten aus, wenn der schnellste Link nicht erreichbar ist" {
  make_net_stubs
  # nur der 1G-Pfad (lokal eth0 -> remote eth0) ist erreichbar
  touch "$TMP/reachable.eth0.192.168.1.100"
  run_ddpar_fn_stubbed "$SELECT_FIXTURE"'select_transfer_link; echo "SEL=$SELECTED_LOCAL_NIC>$SELECTED_REMOTE_IP@$SELECTED_LINK_SPEED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eth1 → 10.0.0.5 (eth1): nicht erreichbar"* ]]
  [[ "$output" == *"SEL=eth0>192.168.1.100@1000"* ]]
}

@test "select_transfer_link bevorzugt bei unbekannter lokaler Geschwindigkeit die schnellste Remote-NIC" {
  make_net_stubs
  # lokale Geschwindigkeit unbekannt (0): alle Kandidaten haben effektiv 0,
  # der stabile Sort muss die schnellere Remote-NIC (10G) zuerst probieren
  touch "$TMP/reachable.eth0"
  run_ddpar_fn_stubbed 'REACHABLE_NICS=(eth0); REACHABLE_NIC_SPEEDS=(0); REACHABLE_NIC_IPS=(192.168.1.6);
    REMOTE_NICS=(eth1 eth0); REMOTE_NIC_SPEEDS=(10000 1000); REMOTE_NIC_IPS=(10.0.0.5 192.168.1.100);
    REMOTE_HOST=user@192.168.1.100; select_transfer_link; echo "SEL=$SELECTED_REMOTE_IP"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SEL=10.0.0.5"* ]]
}

@test "select_transfer_link scheitert, wenn kein Kandidat erreichbar ist" {
  make_net_stubs
  run_ddpar_fn_stubbed "$SELECT_FIXTURE"'select_transfer_link; echo "rc=$?"; echo "ADDR=$(remote_transfer_addr)"'
  [[ "$output" == *"Kein Link-Kandidat erreichbar"* ]]
  [[ "$output" == *"rc=1"* ]]
  # ohne Auswahl fällt der Datenkanal auf die SSH-Adresse zurück
  [[ "$output" == *"ADDR=192.168.1.100"* ]]
}

@test "select_transfer_link scheitert ohne Remote-Inventar" {
  run_ddpar_fn 'REACHABLE_NICS=(eth0); REACHABLE_NIC_SPEEDS=(1000); REACHABLE_NIC_IPS=(192.168.1.6); REMOTE_HOST=user@ziel; select_transfer_link; echo "rc=$?"; echo "ADDR=$(remote_transfer_addr)"'
  [[ "$output" == *"lokale Erreichbarkeitsprüfung oder Remote-Inventar fehlt"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ADDR=ziel"* ]]
}

@test "select_transfer_link scheitert, wenn das Remote-Ziel keine IPv4-Adressen meldet" {
  run_ddpar_fn 'REACHABLE_NICS=(eth0); REACHABLE_NIC_SPEEDS=(1000); REACHABLE_NIC_IPS=(192.168.1.6);
    REMOTE_NICS=(eth0); REMOTE_NIC_SPEEDS=(1000); REMOTE_NIC_IPS=("");
    REMOTE_HOST=user@ziel; select_transfer_link; echo "rc=$?"'
  [[ "$output" == *"meldet keine IPv4-Adressen"* ]]
  [[ "$output" == *"rc=1"* ]]
}
