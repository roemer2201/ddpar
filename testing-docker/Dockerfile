FROM debian:bookworm-slim

# Alle von den ddpar-Skripten benötigten Werkzeuge:
#   ddpar.sh / restore / check: dd, nc, df, tee, blockdev, stat, ss, gzip,
#   sha256sum, file, awk, sed, grep, ssh, sshpass, which
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server \
      openssh-client \
      sshpass \
      netcat-openbsd \
      iproute2 \
      util-linux \
      coreutils \
      file \
      gzip \
      procps \
      grep \
      sed \
      gawk \
      debianutils \
    && rm -rf /var/lib/apt/lists/*

# SSH: Root-Login per Key und Passwort erlauben (nur Testumgebung!).
# Ein fester Schlüssel wird ins Image gebacken; da beide Container (source und
# target) aus diesem Image starten, teilen sie sich den Key und koennen sich
# gegenseitig passwortlos per SSH erreichen.
RUN mkdir -p /var/run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 \
    && cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys \
    && chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_ed25519

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
