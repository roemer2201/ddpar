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
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* \
    && install -d -m 0700 /root/.ssh \
    && install -d /run/sshd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
