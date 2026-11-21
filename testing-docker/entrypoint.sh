#!/bin/bash
# Set up per-container SSH identities and the source fixture, then start sshd.
# Version: 1.0.1 (2026-11-19)
set -eu

# Share only the public user key. Rename atomically so the peer never sees
# a partial record when the two containers start at the same time.
ssh-keygen -A
identity=/root/.ssh/id_ed25519
if [ ! -f "${identity}" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "${identity}"
fi
install -m 0644 "${identity}.pub" /run/ddpar-public/key.tmp
mv -f /run/ddpar-public/key.tmp /run/ddpar-public/key
sshd_options=(-o AuthorizedKeysFile=/run/ddpar-peer/key -o KbdInteractiveAuthentication=no)
if [ -n "${ROOT_PASSWORD:-}" ]; then
  printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
  sshd_options+=(-o PermitRootLogin=yes -o PasswordAuthentication=yes)
else
  sshd_options+=(-o PermitRootLogin=prohibit-password -o PasswordAuthentication=no)
fi
unset ROOT_PASSWORD

# Arbeitsverzeichnisse, die von den Testszenarien verwendet werden
mkdir -p /data /backup /restore /clone_dest

# Nur der Source-Host braucht eine Testdatei zum Klonen/Sichern
if [ "${DDPAR_ROLE:-}" = "source" ]; then
  if [ ! -f /data/source.img ]; then
    echo "[entrypoint] Erzeuge Testdatei /data/source.img (${TEST_SIZE_MB:-64} MiB)"
    dd if=/dev/urandom of=/data/source.img bs=1M count="${TEST_SIZE_MB:-64}" status=none
  fi
fi

echo "[entrypoint] Rolle '${DDPAR_ROLE:-host}' bereit. Starte sshd ..."
exec /usr/sbin/sshd -D -e "${sshd_options[@]}"
