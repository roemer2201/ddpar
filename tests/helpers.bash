# Gemeinsame Helfer für die bats-Testsuite.
# Wird von den .bats-Dateien via `load helpers` eingebunden.

setup() {
  # Wurzel des Repos (ein Verzeichnis über tests/)
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # Isoliertes Arbeitsverzeichnis pro Test
  TMP="$(mktemp -d)"
}

teardown() {
  # Eventuell angelegte Loop-Devices wieder lösen (siehe loop_setup)
  if [ -n "$TMP" ] && [ -f "$TMP/.loopdevs" ]; then
    while read -r dev; do
      [ -n "$dev" ] && losetup -d "$dev" 2>/dev/null || true
    done < "$TMP/.loopdevs"
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
}

# Erzeugt eine Testdatei mit Zufallsdaten.
# Größe so gewählt, dass sie glatt durch NUM_JOBS (4) * BLOCKSIZE (1 MiB) teilbar ist,
# damit size_calculation in ddpar.sh nicht abbricht.
# Aufruf: make_testfile <pfad> [mebibytes]
make_testfile() {
  local path="$1"
  local mib="${2:-8}"
  dd if=/dev/urandom of="$path" bs=1M count="$mib" status=none
}

# --- Blockgerät-Helfer (Loop-Devices) ---

# Überspringt den Test, wenn keine Loop-Devices angelegt werden können
# (kein root oder losetup nicht verfügbar).
require_block_support() {
  [ "$(id -u)" -eq 0 ] || skip "benötigt root für losetup"
  command -v losetup >/dev/null 2>&1 || skip "losetup nicht verfügbar"
  # In manchen Containern ist /dev/loop-control nicht nutzbar
  losetup -f >/dev/null 2>&1 || skip "Loop-Devices nicht nutzbar"
}

# Legt eine Backing-Datei an und hängt sie als Loop-Device ein.
# Gibt den Device-Pfad (z.B. /dev/loop3) auf stdout aus.
# Aufruf: dev=$(loop_setup <backing-datei> [mebibytes])
loop_setup() {
  local img="$1"
  local mib="${2:-8}"
  dd if=/dev/zero of="$img" bs=1M count="$mib" status=none
  local dev
  dev="$(losetup --find --show "$img")"
  echo "$dev" >> "$TMP/.loopdevs"
  echo "$dev"
}

# --- Remote-Helfer (SSH zu localhost) ---

# REMOTE_HOST für die Remote-Tests. Über Umgebungsvariable überschreibbar,
# damit z.B. das Docker-Harness einen echten Host setzen kann.
REMOTE_TEST_HOST="${DDPAR_REMOTE_TEST_HOST:-localhost}"

# Überspringt den Test, wenn keine passwortlose SSH-Verbindung zum Testhost
# möglich ist.
require_remote_support() {
  command -v ssh >/dev/null 2>&1 || skip "ssh-Client nicht verfügbar"
  command -v nc  >/dev/null 2>&1 || skip "nc nicht verfügbar"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "$REMOTE_TEST_HOST" true 2>/dev/null \
      || skip "keine passwortlose SSH-Verbindung zu $REMOTE_TEST_HOST"
}
