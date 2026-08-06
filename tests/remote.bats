#!/usr/bin/env bats
#
# Remote-Tests über SSH + netcat. Verwenden standardmäßig "localhost" als
# Remote-Host (über DDPAR_REMOTE_TEST_HOST überschreibbar, z.B. für das
# Docker-Harness).
#
# Voraussetzung: passwortlose SSH-Verbindung zum Testhost sowie nc/ss/dd dort.
# Ist das nicht gegeben, werden die Tests übersprungen (skip), damit `make test`
# für normale Entwickler grün bleibt. In der CI richtet ein eigener Job
# SSH-zu-localhost ein und führt diese Datei aus.
#
# Abgedeckt wird der netcat-Pfad: Clone (Datei), Backup (Datei) und Restore
# (Datei), jeweils unkomprimiert, mit lokaler [De]Kompression (Modus n + -c)
# sowie mit [De]Kompression auf der Gegenseite (Modus c + -c).

load helpers

remote_teardown() {
  # ddpar nutzt einen festen SSH-Control-Socket; nach (Teil-)Abbrüchen schließen.
  ssh -S /tmp/ssh_socket_ddpar -O exit "$REMOTE_TEST_HOST" 2>/dev/null || true
  rm -f /tmp/ssh_socket_ddpar
}

@test "Remote Clone Datei (-r n) ist bitgenau" {
  require_remote_support

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rdest"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rdest" -m clone -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/rdest/src.bin"
}

@test "Remote Clone mit -r ohne Modusangabe nutzt Modus n" {
  require_remote_support

  make_testfile "$TMP/src.bin" 2
  mkdir -p "$TMP/rdest"

  # "-r" ohne Modus darf die folgende Option (-R) nicht verschlucken
  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rdest" -m clone -r -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOTE COMMAND"* ]]

  cmp "$TMP/src.bin" "$TMP/rdest/src.bin"
}

@test "Remote Backup -> Remote Restore Datei (-r n) ist bitgenau" {
  require_remote_support

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [ -f "$TMP/rbackup/src.bin-0.part" ]
  [ -f "$TMP/rbackup/src.bin-metadata.txt" ]

  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r n -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}

@test "Remote Backup -> Remote Restore Datei (-r n -c, lokale [De]Kompression) ist bitgenau" {
  require_remote_support
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  # Nicht glatt teilbare Größe, damit auch der Rest-Teil (part_bytes) mitgeprüft wird
  make_testfile "$TMP/src.bin"
  truncate -s +12345 "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  # Komprimiert wird lokal, auf der Gegenseite landen .gz-Teile
  [ -f "$TMP/rbackup/src.bin-0.gz" ]
  [ ! -f "$TMP/rbackup/src.bin-0.part" ]
  grep -q "^COMPRESSION=1" "$TMP/rbackup/src.bin-metadata.txt"
  grep -q "^COMPRESSION_LEVEL=" "$TMP/rbackup/src.bin-metadata.txt"

  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r n -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}

@test "Remote check bestätigt ein komprimiertes Remote-Backup gegen die Quelle" {
  require_remote_support
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  run "$REPO_ROOT/ddpar-check.sh" -s "$TMP/src.bin" -b "$TMP/rbackup/src.bin" -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prüfung erfolgreich"* ]]
}

@test "Remote check erkennt ein manipuliertes komprimiertes Remote-Backup" {
  require_remote_support
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  # Quelle nachträglich verändern -> die Hashes dürfen nicht mehr passen
  printf 'XXXXXXXX' | dd of="$TMP/src.bin" bs=1 seek=1000 conv=notrunc status=none

  run "$REPO_ROOT/ddpar-check.sh" -s "$TMP/src.bin" -b "$TMP/rbackup/src.bin" -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}

# --- Modus c: [De]Kompression auf der Remote-Maschine ---

@test "Remote Backup -> Remote Restore Datei (-r c -c, Remote-[De]Kompression) ist bitgenau" {
  require_remote_support
  require_remote_gzip

  # Nicht glatt teilbare Größe, damit auch der Rest-Teil (part_bytes) mitgeprüft wird
  make_testfile "$TMP/src.bin"
  truncate -s +12345 "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  # Über netcat gehen die Rohdaten, komprimiert wird auf der Gegenseite
  [[ "$output" == *"gzip -6 > "* ]]
  [ -f "$TMP/rbackup/src.bin-0.gz" ]
  [ ! -f "$TMP/rbackup/src.bin-0.part" ]
  grep -q "^COMPRESSION=1" "$TMP/rbackup/src.bin-metadata.txt"

  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r c -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote decompression"* ]]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}

@test "Ein mit -r c erzeugtes Backup lässt sich mit -r n wiederherstellen" {
  require_remote_support
  require_remote_gzip
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  # Die .gz-Teile sind unabhängig davon, wo komprimiert wurde -> Restore mit
  # lokaler Dekompression muss dieselben Daten liefern
  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r n -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}

@test "Remote Clone Datei mit Kompression (-r c -c) ist bitgenau" {
  require_remote_support
  require_remote_gzip
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  make_testfile "$TMP/src.bin"
  truncate -s +7777 "$TMP/src.bin"
  mkdir -p "$TMP/rdest"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rdest" -m clone -c -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  # Lokal komprimiert, die Gegenseite dekomprimiert vor dem Schreiben
  [[ "$output" == *"gzip -dc | dd of="* ]]

  cmp "$TMP/src.bin" "$TMP/rdest/src.bin"
}

@test "Remote Clone mit -c ohne Modus c warnt und klont unkomprimiert" {
  require_remote_support
  command -v gzip >/dev/null 2>&1 || skip "gzip nicht verfügbar"

  make_testfile "$TMP/src.bin" 2
  mkdir -p "$TMP/rdest"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rdest" -m clone -c -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kompression (-c) ist im Clone-Modus nur mit Remote-Modus 'c'"* ]]

  cmp "$TMP/src.bin" "$TMP/rdest/src.bin"
}

@test "Remote check (-r c) bestätigt ein komprimiertes Remote-Backup gegen die Quelle" {
  require_remote_support
  require_remote_gzip

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  run "$REPO_ROOT/ddpar-check.sh" -s "$TMP/src.bin" -b "$TMP/rbackup/src.bin" -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prüfung erfolgreich"* ]]
}

@test "Remote check (-r c) erkennt ein manipuliertes komprimiertes Remote-Backup" {
  require_remote_support
  require_remote_gzip

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -c -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  printf 'XXXXXXXX' | dd of="$TMP/src.bin" bs=1 seek=1000 conv=notrunc status=none

  run "$REPO_ROOT/ddpar-check.sh" -s "$TMP/src.bin" -b "$TMP/rbackup/src.bin" -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}
