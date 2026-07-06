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

# Stub-Verzeichnis mit ping/nc, deren Verhalten pro NIC bzw. Source-IP über
# Marker-Dateien gesteuert wird: existiert $TMP/reachable.<nic>, ist das Ziel
# über diese NIC per ping erreichbar; $TMP/tcp.<src-ip> analog für nc -s.
make_net_stubs() {
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/ping" <<STUB
#!/bin/bash
# Argument nach -I ist die NIC
while [ \$# -gt 0 ]; do
  [ "\$1" = "-I" ] && nic="\$2"
  shift
done
[ -e "$TMP/reachable.\$nic" ]
STUB
  cat > "$TMP/stubbin/nc" <<STUB
#!/bin/bash
# Argument nach -s ist die Source-IP
while [ \$# -gt 0 ]; do
  [ "\$1" = "-s" ] && src="\$2"
  shift
done
[ -e "$TMP/tcp.\$src" ]
STUB
  chmod +x "$TMP/stubbin/ping" "$TMP/stubbin/nc"
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
