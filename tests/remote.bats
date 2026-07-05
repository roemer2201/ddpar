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
# Abgedeckt werden die netcat-Pfade: unkomprimiert (Modus n) sowie komprimiert
# mit lokaler Kompression (Modus n + -c) und Remote-Kompression (Modus c),
# jeweils Clone/Backup/Restore (Datei) und der Remote-Check.

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

@test "Remote Clone Datei komprimierter Transfer (-r n -c) ist bitgenau" {
  require_remote_support

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rdest"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rdest" -m clone -r n -c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/rdest/src.bin"
}

@test "Remote Backup komprimiert, lokale Kompression (-r n -c) -> Restore (-r n)" {
  require_remote_support

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -r n -c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [ -f "$TMP/rbackup/src.bin-0.gz" ]
  grep -q "^COMPRESSION=1$" "$TMP/rbackup/src.bin-metadata.txt"

  # Remote-Check des komprimierten Backups (Hashes via SSH, gzip -dc remote)
  run "$REPO_ROOT/ddpar-check.sh" -s "$TMP/src.bin" -b "$TMP/rbackup/src.bin" -r n -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISMATCH"* ]]

  # Restore mit lokaler Dekompression
  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r n -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}

@test "Remote Backup komprimiert, remote Kompression (-r c) -> Restore (-r c)" {
  require_remote_support

  make_testfile "$TMP/src.bin"
  mkdir -p "$TMP/rbackup"

  run "$REPO_ROOT/ddpar.sh" -i "$TMP/src.bin" -o "$TMP/rbackup" -m backup -r c -R "$REMOTE_TEST_HOST"
  remote_teardown
  [ "$status" -eq 0 ]
  [ -f "$TMP/rbackup/src.bin-0.gz" ]
  grep -q "^COMPRESSION=1$" "$TMP/rbackup/src.bin-metadata.txt"

  # Restore mit remote Dekompression
  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/rbackup/src.bin" -o "$TMP/restored.bin" -r c -R "$REMOTE_TEST_HOST" -y
  remote_teardown
  [ "$status" -eq 0 ]

  cmp "$TMP/src.bin" "$TMP/restored.bin"
}
