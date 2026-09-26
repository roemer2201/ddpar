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

@test "Refused clone returns failure without changing the existing file" {
  printf 'source' > "${TMP}/source.bin"
  printf 'existing' > "${TMP}/target.bin"

  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/target.bin" -j 1 -b 1
  [ "${status}" -ne 0 ]
  [ "$(cat "${TMP}/target.bin")" = 'existing' ]
}

@test "Forced clone removes the old suffix and check rejects extra bytes" {
  printf 'source' > "${TMP}/source.bin"
  printf 'existing and longer' > "${TMP}/target.bin"

  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/target.bin" -j 1 -b 1 -f
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source.bin" "${TMP}/target.bin"

  printf 'extra' >> "${TMP}/target.bin"
  vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source.bin" -d "${TMP}/target.bin" -j 1 -B 1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Zieldatei hat"* ]]
}

@test "Restore rejects a short backup part before opening the target" {
  printf '12345678901234567890' > "${TMP}/source.bin"
  mkdir -p "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/backup" -m backup -j 2 -b 4
  [ "${status}" -eq 0 ]
  truncate -s 1 "${TMP}/backup/source.bin-1.part"

  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source.bin" -o "${TMP}/target.bin" -y
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"statt der erwarteten"* ]]
  [ ! -e "${TMP}/target.bin" ]
}

@test "Check compares despite different metadata and source file types" {
  printf 'original source data' > "${TMP}/source.bin"
  mkdir -p "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/backup" -m backup -s -j 2 -b 4
  [ "${status}" -eq 0 ]
  sed -i 's/^FILE_TYPE=.*/FILE_TYPE=block special (8\/0)/' "${TMP}/backup/source.bin-metadata.txt"
  printf 'changed' > "${TMP}/source.bin"

  vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source.bin" -b "${TMP}/backup/source.bin"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAILED"* ]]
}

@test "Backup name with spaces works on repeated backup and restore" {
  printf 'original source data' > "${TMP}/source.bin"
  mkdir -p "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/backup" -m backup -j 2 -b 4 -n 'with space'
  [ "${status}" -eq 0 ]
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/backup" -m backup -j 2 -b 4 -n 'with space'
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^NUM_JOBS=' "${TMP}/backup/with space-metadata.txt")" -eq 1 ]

  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/with space" -o "${TMP}/target.bin" -y
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source.bin" "${TMP}/target.bin"
}

@test "Literal command substitution in a directory name is not executed" {
  printf 'source' > "${TMP}/source.bin"
  mkdir -p "${TMP}/out\$(touch injected)"
  cd "${TMP}"

  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/out\$(touch injected)" -j 1 -b 1
  [ "${status}" -eq 0 ]
  [ ! -e "${TMP}/injected" ]
  cmp "${TMP}/source.bin" "${TMP}/out\$(touch injected)/source.bin"
}

@test "Restore akzeptiert aeltere Metadaten ohne INPUT_SIZE" {
  make_testfile "${TMP}/source.bin" 1
  mkdir -p "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source.bin" -o "${TMP}/backup" -m backup -j 2 -b 4096
  [ "${status}" -eq 0 ]
  sed -i '/^INPUT_SIZE=/d' "${TMP}/backup/source.bin-metadata.txt"

  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source.bin" -o "${TMP}/target.bin" -y
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source.bin" "${TMP}/target.bin"
}
