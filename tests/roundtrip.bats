#!/usr/bin/env bats
#
# End-to-End-Tests des Kern-Ablaufs auf Datei-Basis (keine Blockgeräte, kein sudo):
#   backup -> check -> restore  und  Vergleich Original == Wiederhergestellt.
#
# Block-Device- und Remote-Pfade (SSH/netcat) werden hier bewusst NICHT getestet,
# dafür existiert das Docker-Harness unter testing-docker/ (siehe TESTING.md).

load helpers

@test "Backup -> Restore (unkomprimiert) stellt die Daten bitgenau wieder her" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]
  [ -f "$TMP/backup/quelle.bin-0.part" ]
  [ -f "$TMP/backup/quelle.bin-metadata.txt" ]

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/quelle.bin" -o "$TMP/restore.bin" -y
  [ "$status" -eq 0 ]

  cmp -s "$TMP/quelle.bin" "$TMP/restore.bin"
}

@test "Backup -> Restore (komprimiert, -c) stellt die Daten bitgenau wieder her" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -c -s
  [ "$status" -eq 0 ]
  [ -f "$TMP/backup/quelle.bin-0.gz" ]

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/quelle.bin" -o "$TMP/restore.bin" -y
  [ "$status" -eq 0 ]

  cmp -s "$TMP/quelle.bin" "$TMP/restore.bin"
}

@test "check bestätigt ein konsistentes Backup gegen die Quelle" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]

  vrun "$REPO_ROOT/ddpar-check.sh" -s "$TMP/quelle.bin" -b "$TMP/backup/quelle.bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" != *"FAILED"* ]]
}

@test "check erkennt ein manipuliertes Backup" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]

  # Quelle nach dem Backup verändern -> Prüfsummen dürfen nicht mehr passen
  printf 'tampered' | dd of="$TMP/quelle.bin" bs=1 seek=0 conv=notrunc status=none

  vrun "$REPO_ROOT/ddpar-check.sh" -s "$TMP/quelle.bin" -b "$TMP/backup/quelle.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
}
