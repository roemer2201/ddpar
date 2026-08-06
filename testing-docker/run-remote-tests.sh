#!/bin/bash
#
# run-remote-tests.sh - Automatisierter Remote-Test im Zwei-Container-Harness.
#
# Baut/startet die Container "source" und "target", führt die Remote-Szenarien
# (SSH + netcat, Modus n) von source -> target aus und prüft die Integrität per
# SHA256. Liefert einen Exitcode (0 = alles bestanden, 1 = mindestens ein Fehler).
#
# Dies ist ein MANUELLES Werkzeug (nicht Teil der GitHub-Actions-CI), gedacht zum
# Nachtesten nach Code-Änderungen an den ddpar-Skripten. Die Skripte werden
# read-only aus dem Repo-Root in die Container gemountet, ein Rebuild ist nach
# Skriptänderungen also nicht nötig (--no-build nutzen).
#
# Verwendung:
#   ./run-remote-tests.sh [--no-build] [--keep] [--verbose] [-h]
#
#   --no-build   Vorhandenes Image verwenden, nicht neu bauen
#   --keep       Container nach dem Lauf nicht herunterfahren (zum Nachsehen)
#   --verbose    ddpar-Kommando-Output live ausgeben (statt nur bei Fehler)
#   -h, --help   Diese Hilfe anzeigen

set -euo pipefail

SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")"

BUILD=1
KEEP=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --keep)     KEEP=1 ;;
    --verbose)  VERBOSE=1 ;;
    -h|--help)
      sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

DC="docker compose"
RC=0

info() { echo "==> $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RC=1; }
vshow() { [ "$VERBOSE" -eq 1 ] && echo "$1" | sed 's/^/    /' || true; }

# shellcheck disable=SC2317  # Funktionsrumpf wird via trap aufgerufen
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    info "Container laufen weiter (--keep). Aufräumen mit: $DC down -v"
  else
    info "Räume auf ($DC down -v) ..."
    $DC down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Befehl im jeweiligen Container ausführen (Login-Shell für vollständigen PATH).
src() { $DC exec -T source bash -lc "$1"; }
tgt() { $DC exec -T target bash -lc "$1"; }

# --- Container bauen/starten ---

if [ "$BUILD" -eq 1 ]; then
  info "Baue Image ..."
  $DC build source
fi
info "Starte Container ..."
$DC up -d

# --- Auf SSH source -> target warten ---

info "Warte auf SSH-Verbindung source -> target ..."
ssh_ready=0
for _ in $(seq 1 30); do
  if src 'ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@target true' 2>/dev/null; then
    ssh_ready=1
    break
  fi
  sleep 1
done
if [ "$ssh_ready" -ne 1 ]; then
  fail "SSH source -> target nicht erreichbar"
  exit 1
fi
pass "SSH source -> target steht"

# Preflight: benötigte Befehle auf dem target sichtbar (nicht-interaktiver PATH)?
if ! src 'ssh -o StrictHostKeyChecking=no root@target "command -v ss nc dd tee df stat >/dev/null"'; then
  fail "Auf target fehlen benötigte Befehle im SSH-PATH (ss/nc/dd/tee/df/stat)"
  exit 1
fi

# --- Vorbereitung ---

# Zielverzeichnisse auf target und Restore-Verzeichnis auf source leeren.
src 'ssh -o StrictHostKeyChecking=no root@target "mkdir -p /clone_dest /backup; rm -f /clone_dest/* /backup/* 2>/dev/null || true"'
src 'mkdir -p /restore; rm -f /restore/* 2>/dev/null || true'

SRC_IMG=/data/source.img
if ! src "test -f $SRC_IMG"; then
  fail "Testdatei $SRC_IMG fehlt auf source"
  exit 1
fi
SRC_HASH="$(src "sha256sum $SRC_IMG" | awk '{print $1}')"
info "Quelle: $SRC_IMG  sha256=$SRC_HASH"

# --- Szenario 1: Remote-Clone (Datei) source -> target ---

info "Szenario 1: Remote-Clone (Datei) source -> target"
if out="$(src "./ddpar.sh -i $SRC_IMG -o /clone_dest -m clone -r n -R root@target" 2>&1)"; then
  vshow "$out"
  tgt 'sync' || true
  sleep 1
  DST_HASH="$(tgt 'sha256sum /clone_dest/source.img 2>/dev/null' | awk '{print $1}')"
  if [ -n "$DST_HASH" ] && [ "$SRC_HASH" = "$DST_HASH" ]; then
    pass "Remote-Clone bitgenau (sha256=$DST_HASH)"
  else
    fail "Remote-Clone weicht ab (src=$SRC_HASH dst=${DST_HASH:-<leer>})"
  fi
else
  vshow "$out"
  fail "Remote-Clone-Kommando schlug fehl"
  echo "$out" | tail -15 | sed 's/^/    /'
fi

# --- Szenario 2: Remote-Backup + Remote-Restore (Datei) ---

info "Szenario 2: Remote-Backup (source -> target) + Remote-Restore (target -> source)"
if out="$(src "./ddpar.sh -i $SRC_IMG -o /backup -m backup -r n -R root@target" 2>&1)"; then
  vshow "$out"
  if tgt 'test -f /backup/source.img-0.part && test -f /backup/source.img-metadata.txt'; then
    pass "Remote-Backup: Split-Teile + Metadaten auf target vorhanden"
  else
    fail "Remote-Backup: erwartete Dateien auf target fehlen"
  fi

  if out2="$(src "./ddpar-restore.sh -i /backup/source.img -o /restore/source.img -r n -R root@target -y" 2>&1)"; then
    vshow "$out2"
    sleep 1
    RES_HASH="$(src 'sha256sum /restore/source.img 2>/dev/null' | awk '{print $1}')"
    if [ -n "$RES_HASH" ] && [ "$SRC_HASH" = "$RES_HASH" ]; then
      pass "Remote-Restore bitgenau (sha256=$RES_HASH)"
    else
      fail "Remote-Restore weicht ab (src=$SRC_HASH restore=${RES_HASH:-<leer>})"
    fi
  else
    vshow "$out2"
    fail "Remote-Restore-Kommando schlug fehl"
    echo "$out2" | tail -15 | sed 's/^/    /'
  fi
else
  vshow "$out"
  fail "Remote-Backup-Kommando schlug fehl"
  echo "$out" | tail -15 | sed 's/^/    /'
fi

# --- Szenario 3: Remote-Check (lokale Quelle <-> Remote-Backup) ---

info "Szenario 3: Remote-Check (Quelle <-> Remote-Backup auf target)"
check_out="$(src "./ddpar-check.sh -s $SRC_IMG -b /backup/source.img -r n -R root@target" 2>&1 || true)"
vshow "$check_out"
if echo "$check_out" | grep -q "OK" && ! echo "$check_out" | grep -q "FAILED"; then
  pass "Remote-Check bestätigt Übereinstimmung"
else
  fail "Remote-Check meldet keine Übereinstimmung"
  echo "$check_out" | tail -15 | sed 's/^/    /'
fi

# --- Szenario 4: Remote-Backup/-Restore/-Check mit lokaler [De]Kompression ---

info "Szenario 4: Remote-Backup komprimiert (-c, Kompression lokal auf source)"
src 'ssh -o StrictHostKeyChecking=no root@target "mkdir -p /backup_gz; rm -f /backup_gz/* 2>/dev/null || true"'
src 'rm -f /restore/source-gz.img 2>/dev/null || true'

if out="$(src "./ddpar.sh -i $SRC_IMG -o /backup_gz -m backup -c -r n -R root@target" 2>&1)"; then
  vshow "$out"
  # Komprimiert wird lokal, auf target landen .gz-Teile (kein gzip auf target noetig)
  if tgt 'test -f /backup_gz/source.img-0.gz && ! test -f /backup_gz/source.img-0.part' \
     && tgt 'grep -q "^COMPRESSION=1" /backup_gz/source.img-metadata.txt'; then
    pass "Remote-Backup (-c): .gz-Teile + COMPRESSION=1 in den Metadaten auf target"
  else
    fail "Remote-Backup (-c): erwartete .gz-Teile/Metadaten auf target fehlen"
  fi

  if out2="$(src "./ddpar-restore.sh -i /backup_gz/source.img -o /restore/source-gz.img -r n -R root@target -y" 2>&1)"; then
    vshow "$out2"
    sleep 1
    RES_HASH="$(src 'sha256sum /restore/source-gz.img 2>/dev/null' | awk '{print $1}')"
    if [ -n "$RES_HASH" ] && [ "$SRC_HASH" = "$RES_HASH" ]; then
      pass "Remote-Restore (komprimiert, lokale Dekompression) bitgenau (sha256=$RES_HASH)"
    else
      fail "Remote-Restore (komprimiert) weicht ab (src=$SRC_HASH restore=${RES_HASH:-<leer>})"
    fi
  else
    vshow "$out2"
    fail "Remote-Restore-Kommando (komprimiert) schlug fehl"
    echo "$out2" | tail -15 | sed 's/^/    /'
  fi

  check_gz_out="$(src "./ddpar-check.sh -s $SRC_IMG -b /backup_gz/source.img -r n -R root@target" 2>&1 || true)"
  vshow "$check_gz_out"
  if echo "$check_gz_out" | grep -q "OK" && ! echo "$check_gz_out" | grep -q "MISMATCH"; then
    pass "Remote-Check des komprimierten Backups bestätigt Übereinstimmung"
  else
    fail "Remote-Check des komprimierten Backups meldet keine Übereinstimmung"
    echo "$check_gz_out" | tail -15 | sed 's/^/    /'
  fi
else
  vshow "$out"
  fail "Remote-Backup-Kommando (-c) schlug fehl"
  echo "$out" | tail -15 | sed 's/^/    /'
fi

# --- Szenario 5: Remote-[De]Kompression (-r c) ---

info "Szenario 5: Remote-Backup komprimiert (-r c, Kompression auf target)"
src 'ssh -o StrictHostKeyChecking=no root@target "mkdir -p /backup_rc; rm -f /backup_rc/* 2>/dev/null || true"'
src 'rm -f /restore/source-rc.img 2>/dev/null || true'

if out="$(src "./ddpar.sh -i $SRC_IMG -o /backup_rc -m backup -c -r c -R root@target" 2>&1)"; then
  vshow "$out"
  # Ueber netcat gehen die Rohdaten, gzip laeuft auf target und schreibt die .gz-Teile
  if tgt 'test -f /backup_rc/source.img-0.gz && ! test -f /backup_rc/source.img-0.part' \
     && tgt 'grep -q "^COMPRESSION=1" /backup_rc/source.img-metadata.txt'; then
    pass "Remote-Backup (-r c): .gz-Teile + COMPRESSION=1 in den Metadaten auf target"
  else
    fail "Remote-Backup (-r c): erwartete .gz-Teile/Metadaten auf target fehlen"
  fi

  if out2="$(src "./ddpar-restore.sh -i /backup_rc/source.img -o /restore/source-rc.img -r c -R root@target -y" 2>&1)"; then
    vshow "$out2"
    sleep 1
    RES_HASH="$(src 'sha256sum /restore/source-rc.img 2>/dev/null' | awk '{print $1}')"
    if [ -n "$RES_HASH" ] && [ "$SRC_HASH" = "$RES_HASH" ]; then
      pass "Remote-Restore (remote decompression) bitgenau (sha256=$RES_HASH)"
    else
      fail "Remote-Restore (-r c) weicht ab (src=$SRC_HASH restore=${RES_HASH:-<leer>})"
    fi
  else
    vshow "$out2"
    fail "Remote-Restore-Kommando (-r c) schlug fehl"
    echo "$out2" | tail -15 | sed 's/^/    /'
  fi

  check_rc_out="$(src "./ddpar-check.sh -s $SRC_IMG -b /backup_rc/source.img -r c -R root@target" 2>&1 || true)"
  vshow "$check_rc_out"
  if echo "$check_rc_out" | grep -q "OK" && ! echo "$check_rc_out" | grep -q "MISMATCH"; then
    pass "Remote-Check (-r c, Hashing auf target) bestätigt Übereinstimmung"
  else
    fail "Remote-Check (-r c) meldet keine Übereinstimmung"
    echo "$check_rc_out" | tail -15 | sed 's/^/    /'
  fi

  # Die .gz-Teile sind unabhaengig davon, wo komprimiert wurde: Restore mit
  # lokaler Dekompression (-r n) muss dieselben Daten liefern.
  src 'rm -f /restore/source-rc-n.img 2>/dev/null || true'
  if out3="$(src "./ddpar-restore.sh -i /backup_rc/source.img -o /restore/source-rc-n.img -r n -R root@target -y" 2>&1)"; then
    vshow "$out3"
    sleep 1
    RES_HASH="$(src 'sha256sum /restore/source-rc-n.img 2>/dev/null' | awk '{print $1}')"
    if [ -n "$RES_HASH" ] && [ "$SRC_HASH" = "$RES_HASH" ]; then
      pass "Mit -r c erzeugtes Backup ist auch mit -r n wiederherstellbar"
    else
      fail "Restore (-r n) eines -r c-Backups weicht ab (src=$SRC_HASH restore=${RES_HASH:-<leer>})"
    fi
  else
    vshow "$out3"
    fail "Restore-Kommando (-r n) eines -r c-Backups schlug fehl"
    echo "$out3" | tail -15 | sed 's/^/    /'
  fi
else
  vshow "$out"
  fail "Remote-Backup-Kommando (-r c) schlug fehl"
  echo "$out" | tail -15 | sed 's/^/    /'
fi

# --- Szenario 6: Remote-Clone komprimiert (-r c -c) ---

info "Szenario 6: Remote-Clone komprimiert (lokal gzip, target dekomprimiert)"
src 'ssh -o StrictHostKeyChecking=no root@target "mkdir -p /clone_dest_gz; rm -f /clone_dest_gz/* 2>/dev/null || true"'

if out="$(src "./ddpar.sh -i $SRC_IMG -o /clone_dest_gz -m clone -c -r c -R root@target" 2>&1)"; then
  vshow "$out"
  tgt 'sync' || true
  sleep 1
  DST_HASH="$(tgt 'sha256sum /clone_dest_gz/source.img 2>/dev/null' | awk '{print $1}')"
  if [ -n "$DST_HASH" ] && [ "$SRC_HASH" = "$DST_HASH" ]; then
    pass "Remote-Clone (-r c -c) bitgenau (sha256=$DST_HASH)"
  else
    fail "Remote-Clone (-r c -c) weicht ab (src=$SRC_HASH dst=${DST_HASH:-<leer>})"
  fi
else
  vshow "$out"
  fail "Remote-Clone-Kommando (-r c -c) schlug fehl"
  echo "$out" | tail -15 | sed 's/^/    /'
fi

# --- Zusammenfassung ---

echo
if [ "$RC" -eq 0 ]; then
  info "Ergebnis: ALLE Remote-Szenarien bestanden."
else
  info "Ergebnis: Mindestens ein Remote-Szenario ist FEHLGESCHLAGEN."
fi
exit "$RC"
