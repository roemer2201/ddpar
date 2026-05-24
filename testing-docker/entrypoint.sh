#!/bin/bash
set -e

# Frische SSH-Host-Keys fuer diese Container-Instanz erzeugen
ssh-keygen -A >/dev/null 2>&1 || true

# Root-Passwort setzen (fuer optionale sshpass-/Passwort-Tests)
echo "root:${ROOT_PASSWORD:-ddpar}" | chpasswd

# Arbeitsverzeichnisse, die von den Testszenarien verwendet werden
mkdir -p /data /backup /restore /clone_dest

# Nur der Source-Host braucht eine Testdatei zum Klonen/Sichern
if [ "${DDPAR_ROLE}" = "source" ]; then
  if [ ! -f /data/source.img ]; then
    echo "[entrypoint] Erzeuge Testdatei /data/source.img (${TEST_SIZE_MB:-64} MiB)"
    dd if=/dev/urandom of=/data/source.img bs=1M count="${TEST_SIZE_MB:-64}" status=none
  fi
fi

echo "[entrypoint] Rolle '${DDPAR_ROLE:-host}' bereit. Starte sshd ..."
exec /usr/sbin/sshd -D -e
