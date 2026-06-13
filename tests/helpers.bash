# Gemeinsame Helfer für die bats-Testsuite.
# Wird von den .bats-Dateien via `load helpers` eingebunden.

setup() {
  # Wurzel des Repos (ein Verzeichnis über tests/)
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # Isoliertes Arbeitsverzeichnis pro Test
  TMP="$(mktemp -d)"
}

teardown() {
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
