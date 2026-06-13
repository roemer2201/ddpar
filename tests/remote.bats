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
# Abgedeckt wird der unkomprimierte netcat-Pfad (Modus n): Clone (Datei),
# Backup (Datei) und Restore (Datei).

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
