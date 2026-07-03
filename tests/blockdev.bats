#!/usr/bin/env bats
#
# Blockgerät-Tests über Loop-Devices (losetup). Benötigen root.
# Ohne root/losetup werden alle Tests übersprungen (skip), damit `make test`
# auch für unprivilegierte Entwickler grün bleibt. In der CI läuft diese Datei
# in einem eigenen Job mit sudo.

load helpers

@test "Clone Blockgerät -> Blockgerät (lokal) ist bitgenau" {
  require_block_support

  local src dst
  src="$(loop_setup "$TMP/src.img")"
  dst="$(loop_setup "$TMP/dst.img")"
  dd if=/dev/urandom of="$src" bs=1M count=8 status=none

  run "$REPO_ROOT/ddpar.sh" -i "$src" -o "$dst" -m clone
  [ "$status" -eq 0 ]

  cmp "$src" "$dst"
}

@test "Backup -> Restore Blockgerät (lokal) ist bitgenau" {
  require_block_support

  local src dst
  src="$(loop_setup "$TMP/src.img")"
  dst="$(loop_setup "$TMP/dst.img")"
  dd if=/dev/urandom of="$src" bs=1M count=8 status=none
  mkdir -p "$TMP/backup"

  local base
  base="$(basename "$src")"   # z.B. loop3

  run "$REPO_ROOT/ddpar.sh" -i "$src" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]
  [ -f "$TMP/backup/${base}-0.part" ]

  run "$REPO_ROOT/ddpar-restore.sh" -i "$TMP/backup/${base}" -o "$dst" -y
  [ "$status" -eq 0 ]

  cmp "$src" "$dst"
}

@test "check bestätigt ein Blockgerät-Backup gegen die Quelle" {
  require_block_support

  local src
  src="$(loop_setup "$TMP/src.img")"
  dd if=/dev/urandom of="$src" bs=1M count=8 status=none
  mkdir -p "$TMP/backup"

  local base
  base="$(basename "$src")"

  run "$REPO_ROOT/ddpar.sh" -i "$src" -o "$TMP/backup" -m backup -s
  [ "$status" -eq 0 ]

  run "$REPO_ROOT/ddpar-check.sh" -b "$TMP/backup/${base}" -s "$src"
  [[ "$output" == *"OK"* ]]
  [[ "$output" != *"FAILED"* ]]
}
