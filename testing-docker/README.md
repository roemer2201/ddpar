# ddpar – Docker-Testumgebung

Diese Umgebung startet **zwei Container**, die als **Quelle** (`source`) und
**Ziel** (`target`) agieren, um die ddpar-Skripte – insbesondere die
Remote-Funktionen über **SSH + netcat** – ohne echte Hardware zu testen.

Beide Container basieren auf demselben Image und enthalten alle von den
Skripten benötigten Werkzeuge (`dd`, `nc`, `ss`, `df`, `tee`, `blockdev`,
`stat`, `gzip`, `sha256sum`, `file`, `ssh`, `sshpass`). Der gemeinsame, ins
Image gebackene SSH-Key erlaubt **passwortloses SSH** zwischen beiden Hosts.

```
  ┌────────────────┐        SSH (Steuerung)         ┌────────────────┐
  │   source       │ ─────────────────────────────► │   target       │
  │  (ddpar.sh)    │   netcat (Datentransfer)        │  (Empfänger)   │
  │  /data/source.img ───────────────────────────►  │  /backup, ...  │
  └────────────────┘                                 └────────────────┘
```

Die Skripte werden read-only aus dem Repo-Root nach `/opt/ddpar` eingebunden.
Änderungen an den Skripten wirken sofort, ein Rebuild ist dafür nicht nötig.

---

## Voraussetzungen

- Docker mit Compose-Plugin (`docker compose`)
- Ausführung aus dem Ordner `testing-docker/`

---

## Container starten

```bash
cd testing-docker
docker compose up -d --build
```

Status prüfen:

```bash
docker compose ps
```

SSH-Verbindung von `source` nach `target` testen (sollte ohne Passwort
durchlaufen):

```bash
docker compose exec source ssh -o StrictHostKeyChecking=no root@target hostname
# Erwartete Ausgabe: target
```

Eine Shell im Quell-Container öffnen:

```bash
docker compose exec source bash
```

In dieser Shell liegt das Arbeitsverzeichnis bereits auf `/opt/ddpar`, sodass
die Skripte direkt als `./ddpar.sh` usw. aufgerufen werden können.

Verfügbare Pfade in den Containern:

| Pfad | Bedeutung |
|---|---|
| `/opt/ddpar` | Die ddpar-Skripte (read-only) |
| `/data/source.img` | Testdatei (nur auf `source`, Default 64 MiB) |
| `/backup` | Ziel für Backups (`.part`/`.gz`/Metadaten) |
| `/restore` | Ziel für Restores |
| `/clone_dest` | Ziel für File-Clones |

---

## Automatisierter Remote-Test (`run-remote-tests.sh`)

Für einen schnellen End-to-End-Check nach Code-Änderungen gibt es ein
Orchestrierungs-Skript, das die Container startet, die Remote-Szenarien
`source` → `target` durchführt und die Integrität per SHA256 prüft:

```bash
cd testing-docker
./run-remote-tests.sh              # baut Image, startet Container, testet, räumt auf
./run-remote-tests.sh --no-build   # ohne Rebuild (Skripte sind read-only gemountet)
./run-remote-tests.sh --keep       # Container nach dem Lauf zum Nachsehen laufen lassen
```

Geprüft werden (alles über SSH + netcat, Modus `n`, unkomprimiert):

1. **Remote-Clone** (Datei) `source` → `target`, Vergleich Original ↔ Klon
2. **Remote-Backup** `source` → `target` und anschließendes **Remote-Restore**
   `target` → `source`, Vergleich Original ↔ Wiederhergestellt
3. **Remote-Check** (lokale Quelle ↔ Remote-Backup)

Exitcode `0` = alle Szenarien bestanden, `1` = mindestens ein Fehler. Das Skript
ist ein **manuelles** Werkzeug und nicht Teil der GitHub-Actions-CI (die den
Remote-Pfad gegen `localhost` testet, siehe [`../tests/`](../tests/)).

---

## Testszenarien (manuell)

Alle Kommandos werden **im `source`-Container** ausgeführt
(`docker compose exec source bash`). Der Remote-Host ist `root@target`.

### Lokal (nur auf `source`)

```bash
# Backup einer Datei
./ddpar.sh -i /data/source.img -o /backup -m backup

# Mit Prüfsummen (-s) und/oder Kompression (-c)
./ddpar.sh -i /data/source.img -o /backup -m backup -s -c

# Restore (erfordert vorheriges Backup)
./ddpar-restore.sh -i /backup/source.img -o /restore/source.img

# Clone einer Datei in ein Verzeichnis
./ddpar.sh -i /data/source.img -o /clone_dest -m clone

# Prüfung Quelle <-> Backup
./ddpar-check.sh -s /data/source.img -b /backup/source.img
```

### Remote (`source` → `target`, netcat, Modus `n`)

```bash
# Remote-Backup: Split-Teile landen als /backup/source.img-*.part auf target
./ddpar.sh -i /data/source.img -o /backup -m backup -r n -R root@target

# Remote-Clone einer Datei in ein Verzeichnis auf target
./ddpar.sh -i /data/source.img -o /clone_dest -m clone -r n -R root@target

# Remote-Restore: Backup liegt auf target, Ziel ist lokal auf source
./ddpar-restore.sh -i /backup/source.img -o /restore/source.img -r n -R root@target

# Remote-Check: lokale Quelle gegen Remote-Backup (nur Hash-Vergleich)
./ddpar-check.sh -s /data/source.img -b /backup/source.img -r n -R root@target
```

Ergebnisse auf dem Ziel ansehen:

```bash
docker compose exec target ls -l /backup
```

> **Hinweis:** Remote-Transfer ist aktuell nur **unkomprimiert** implementiert
> (siehe `README.md` im Repo-Root). `-c`/`-s` greifen auf dem Remote-Pfad nicht.

---

## Container anpassen

### Über Umgebungsvariablen (ohne Rebuild)

Variablen können beim Start gesetzt werden, z.B.:

```bash
# Größere Testdatei (muss durch NUM_JOBS × Blocksize teilbar sein)
TEST_SIZE_MB=256 docker compose up -d --build

# Anderes Root-Passwort (für sshpass-/Passwort-Tests)
ROOT_PASSWORD=geheim docker compose up -d
```

| Variable | Default | Wirkung |
|---|---|---|
| `TEST_SIZE_MB` | `64` | Größe von `/data/source.img` (MiB) |
| `ROOT_PASSWORD` | `ddpar` | Root-Passwort in beiden Containern |

Beim Ändern von `TEST_SIZE_MB` die alte Testdatei vorher entfernen, damit sie
neu erzeugt wird:

```bash
docker compose exec source rm -f /data/source.img
docker compose restart source
```

### Werkzeuge / Pakete ergänzen

Zusätzliche Pakete in der `Dockerfile` in der `apt-get install`-Liste ergänzen
und neu bauen:

```bash
docker compose build --no-cache
docker compose up -d
```

### Hostnamen / weitere Hosts

Die Service-Namen (`source`, `target`) dienen gleichzeitig als Hostnamen im
Compose-Netzwerk. Für einen dritten Host einen weiteren Service nach demselben
Muster in `docker-compose.yml` ergänzen (gleiches `image: ddpar-test`,
eigene `DDPAR_ROLE`/`hostname`).

### Block-Device-Tests (optional, benötigt Privilegien)

Standardmäßig wird mit Dateien getestet. Für echte Block-Device-Tests muss in
`docker-compose.yml` bei den Services `privileged: true` aktiviert und neu
gestartet werden. Anschließend im Container ein Loop-Device anlegen:

```bash
# Im source- bzw. target-Container
dd if=/dev/zero of=/data/disk.img bs=1M count=64
losetup -fP /data/disk.img
losetup -a                      # zeigt z.B. /dev/loop0

# Danach z.B. als Quelle/Ziel verwenden:
./ddpar.sh -i /dev/loop0 -o /backup -m backup
```

---

## Aufräumen

```bash
# Container stoppen und entfernen
docker compose down

# Zusätzlich das gebaute Image entfernen
docker compose down --rmi local
```

Da die Daten (`/data`, `/backup`, …) nur im Container liegen, werden sie mit
`docker compose down` verworfen. Für persistente Daten bei Bedarf Volumes oder
Bind-Mounts in `docker-compose.yml` ergänzen.
