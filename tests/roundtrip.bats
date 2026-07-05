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

@test "Backup -> Restore mit nicht glatt teilbarer Größe ist bitgenau" {
  # 8 MiB + 12345 Bytes: weder durch NUM_JOBS (4) noch durch die Blockgröße
  # (1 MiB) teilbar — der letzte Teil überträgt den Rest (part_bytes).
  make_testfile "$TMP/quelle.bin"
  dd if=/dev/urandom bs=1 count=12345 status=none >> "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]

  vrun "$REPO_ROOT/ddpar-check.sh" -s "$TMP/quelle.bin" -b "$TMP/backup/quelle.bin"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAILED"* ]]

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/quelle.bin" -o "$TMP/wieder.bin" -y
  [ "$status" -eq 0 ]
  cmp "$TMP/quelle.bin" "$TMP/wieder.bin"
}

@test "Clone Datei mit nicht glatt teilbarer Größe ist bitgenau" {
  make_testfile "$TMP/quelle.bin" 4
  dd if=/dev/urandom bs=1 count=999 status=none >> "$TMP/quelle.bin"
  : > "$TMP/ziel.bin"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/ziel.bin" -f
  [ "$status" -eq 0 ]
  cmp "$TMP/quelle.bin" "$TMP/ziel.bin"
}

@test "Backup mit eigenem Basisnamen (-n) und Restore daraus" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup -s -n eigenname
  [ "$status" -eq 0 ]
  [ -f "$TMP/backup/eigenname-0.part" ]
  [ -f "$TMP/backup/eigenname-metadata.txt" ]
  grep -q "^FILE_NAME=eigenname$" "$TMP/backup/eigenname-metadata.txt"

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/eigenname" -o "$TMP/restore.bin" -y
  [ "$status" -eq 0 ]
  cmp -s "$TMP/quelle.bin" "$TMP/restore.bin"
}

@test "ddpar.sh -n mit Schrägstrich im Namen scheitert" {
  vrun "$REPO_ROOT/ddpar.sh" -i /etc/hostname -o "$TMP" -m backup -n "foo/bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Ungültiger Basisname"* ]]
}

@test "ddpar.sh mit nicht existierender Eingabe scheitert früh" {
  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/gibtsnicht.bin" -o "$TMP" -m backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"existiert nicht"* ]]
}

@test "Restore in ein Verzeichnis nutzt den Basename aus den Metadaten" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup" "$TMP/ziel"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup
  [ "$status" -eq 0 ]

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/quelle.bin" -o "$TMP/ziel" -y
  [ "$status" -eq 0 ]
  cmp -s "$TMP/quelle.bin" "$TMP/ziel/quelle.bin"
}

@test "Restore mit -P überspringt die fallocate-Reservierung" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup
  [ "$status" -eq 0 ]

  vrun "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/quelle.bin" -o "$TMP/restore.bin" -y -P
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vorab-Reservierung"* ]]
  cmp -s "$TMP/quelle.bin" "$TMP/restore.bin"
}

@test "check gegen ein Backup ohne sha256-Dateien scheitert mit klarer Meldung" {
  make_testfile "$TMP/quelle.bin"
  mkdir -p "$TMP/backup"

  # Backup bewusst OHNE -s erstellen
  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/backup" -m backup
  [ "$status" -eq 0 ]

  vrun "$REPO_ROOT/ddpar-check.sh" -s "$TMP/quelle.bin" -b "$TMP/backup/quelle.bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ohne Checksummen"* ]]
}

@test "Clone mit -s erzeugt Checksummen; ddpar-check -b/-d bestätigt und erkennt Manipulation" {
  make_testfile "$TMP/quelle.bin" 4
  : > "$TMP/ziel.bin"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/ziel.bin" -f -s -n "$TMP/clonesums"
  [ "$status" -eq 0 ]
  [ -f "$TMP/clonesums-0.sha256" ]
  [ -f "$TMP/clonesums-metadata.txt" ]
  cmp -s "$TMP/quelle.bin" "$TMP/ziel.bin"

  vrun "$REPO_ROOT/ddpar-check.sh" -b "$TMP/clonesums" -d "$TMP/ziel.bin"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAILED"* ]]

  # Ziel manipulieren -> Prüfung muss fehlschlagen
  printf 'tampered' | dd of="$TMP/ziel.bin" bs=1 seek=0 conv=notrunc status=none
  vrun "$REPO_ROOT/ddpar-check.sh" -b "$TMP/clonesums" -d "$TMP/ziel.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "Clone mit -s ohne -n nutzt den Basename der Quelle im aktuellen Verzeichnis" {
  make_testfile "$TMP/quelle.bin" 4
  : > "$TMP/ziel.bin"

  cd "$TMP"
  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/ziel.bin" -f -s
  [ "$status" -eq 0 ]
  [ -f "$TMP/quelle.bin-0.sha256" ]
  [ -f "$TMP/quelle.bin-metadata.txt" ]
}

@test "Lokaler Clone mit -c warnt und klont trotzdem bitgenau" {
  make_testfile "$TMP/quelle.bin" 4
  : > "$TMP/ziel.bin"

  vrun "$REPO_ROOT/ddpar.sh" -i "$TMP/quelle.bin" -o "$TMP/ziel.bin" -f -c
  [ "$status" -eq 0 ]
  [[ "$output" == *"keine Wirkung"* ]]
  cmp -s "$TMP/quelle.bin" "$TMP/ziel.bin"
}
