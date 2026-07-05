# TESTING

Dieses Dokument enthält Beispiel-Kommandos zum manuellen Testen aller implementierten Funktionen von ddpar.

> **Automatisierte Tests:** Es gibt eine bats-Suite unter [`tests/`](tests/), die
> zusammen mit ShellCheck in der CI läuft (`.github/workflows/ci.yml`):
> CLI-Verhalten und Datei-`backup → check → restore`-Roundtrip (schneller Job) sowie
> Blockgerät- (Loop-Devices) und Remote-Tests (SSH+netcat, Modus `n`) im
> Integration-Job. Lokal: `make check` bzw. `make test-integration` (root/SSH nötig).
> Details in [`tests/README.md`](tests/README.md). Die hier dokumentierten Szenarien
> (echtes Zwei-Host-Remote, Kompression, Modi `l`/`c`) ergänzen das über das
> Docker-Harness unter [`testing-docker/`](testing-docker/).

---

## Voraussetzungen

### Variablen definieren

Die folgenden Variablen in der Shell setzen und in allen Kommandos verwenden:

```bash
# Lokal – Quelllaufwerk (Block Device)
SOURCE_DEV=/dev/sdb

# Lokal – Ziellaufwerk für Clone (Block Device, mindestens so groß wie SOURCE_DEV)
DEST_DEV=/dev/sdc

# Lokal – Testdatei (wird unter "Testdaten erstellen" angelegt)
SOURCE_FILE=/tmp/ddpar_test.img

# Lokal – Zielverzeichnis für File-Clone
DEST_DIR=/tmp/ddpar_clone_dest

# Lokal – Backup-Verzeichnis
BACKUP_DIR=/mnt/backup

# Remote – SSH-Verbindung
REMOTE_HOST=user@192.168.1.100

# Remote – Ziellaufwerk auf dem Remote-Host (Block Device)
REMOTE_DEST_DEV=/dev/sdb

# Remote – Zielverzeichnis für File-Clone auf dem Remote-Host
REMOTE_DEST_DIR=/tmp/ddpar_clone_dest

# Remote – Backup-Verzeichnis auf dem Remote-Host
REMOTE_BACKUP_DIR=/tmp/ddpar_backup
```

### Testdaten erstellen

Eine 64 MiB große Testdatei anlegen (beliebige Größen sind möglich, ein nicht
verteilbarer Rest wird vom letzten Teil übertragen):

```bash
dd if=/dev/urandom of=$SOURCE_FILE bs=1M count=64
```

Zielverzeichnisse anlegen:

```bash
mkdir -p $DEST_DIR
mkdir -p $BACKUP_DIR
```

---

## 1. Lokale Tests – unkomprimiert

### 1.1 Clone – Block Device

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $DEST_DEV -m clone
```

> **Hinweis:** `$DEST_DEV` muss mindestens so groß sein wie `$SOURCE_DEV`.

### 1.2 Clone – Datei

```bash
./ddpar.sh -i $SOURCE_FILE -o $DEST_DIR -m clone
```

> **Hinweis:** Der Output `-o` muss ein vorhandenes Verzeichnis sein. Das geklonte
> File wird dort als `ddpar_test.img` abgelegt.

### 1.3 Backup – Block Device

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $BACKUP_DIR -m backup
```

Erzeugte Dateien: `$BACKUP_DIR/sdb-0.part` … `sdb-3.part` + `sdb-metadata.txt`

### 1.4 Backup – Datei

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup
```

Erzeugte Dateien: `$BACKUP_DIR/ddpar_test.img-0.part` … + `ddpar_test.img-metadata.txt`

### 1.5 Restore – Block Device

```bash
sudo ./ddpar-restore.sh -i $BACKUP_DIR/sdb -o $DEST_DEV
```

> **Hinweis:** Erfordert ein vorher erstelltes Backup aus Test 1.3.
> Der Parameter `-i` ist der Basispfad **ohne** das abschließende `-`.

### 1.6 Restore – Datei

```bash
./ddpar-restore.sh -i $BACKUP_DIR/ddpar_test.img -o $DEST_DIR/ddpar_test.img
```

> **Hinweis:** Erfordert ein vorher erstelltes Backup aus Test 1.4.

---

## 2. Lokale Tests – komprimiert (gzip)

### 2.1 Backup – Block Device (gzip)

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $BACKUP_DIR -m backup -c
```

Erzeugte Dateien: `$BACKUP_DIR/sdb-0.gz` … `sdb-3.gz` + `sdb-metadata.txt`

### 2.2 Backup – Datei (gzip)

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -c
```

### 2.3 Restore – Block Device (gzip)

```bash
sudo ./ddpar-restore.sh -i $BACKUP_DIR/sdb -o $DEST_DEV
```

> **Hinweis:** Erfordert ein vorher erstelltes komprimiertes Backup aus Test 2.1.
> Das Skript erkennt die Komprimierung automatisch über die Metadaten.

### 2.4 Restore – Datei (gzip)

```bash
./ddpar-restore.sh -i $BACKUP_DIR/ddpar_test.img -o $DEST_DIR/ddpar_test.img
```

> **Hinweis:** Erfordert ein vorher erstelltes komprimiertes Backup aus Test 2.2.

---

## 3. Prüfung (ddpar-check.sh)

> **Hinweis:** Die Tests 3.1 und 3.2 setzen ein vorhandenes Backup voraus.
> Der Clone-Check ohne Backup-Metadaten folgt in Test 3.3.

### 3.1 Quelle gegen Backup prüfen (Source ↔ Backup)

Block Device:
```bash
sudo ./ddpar-check.sh -b $BACKUP_DIR/sdb -s $SOURCE_DEV
```

Datei:
```bash
./ddpar-check.sh -b $BACKUP_DIR/ddpar_test.img -s $SOURCE_FILE
```

### 3.2 Backup gegen Ziel prüfen (Backup ↔ Destination)

Block Device:
```bash
sudo ./ddpar-check.sh -b $BACKUP_DIR/sdb -d $DEST_DEV
```

Datei:
```bash
./ddpar-check.sh -b $BACKUP_DIR/ddpar_test.img -d $DEST_DIR/ddpar_test.img
```

### 3.3 Clone prüfen (Source ↔ Destination, ohne Backup-Metadaten)

Da beim Clone keine Metadatendatei existiert, müssen Jobs (und ggf.
Blockgröße) wie beim Clone-Vorgang angegeben werden:

Block Device:
```bash
sudo ./ddpar-check.sh -s $SOURCE_DEV -d $DEST_DEV -j 4
```

Datei:
```bash
./ddpar-check.sh -s $SOURCE_FILE -d $DEST_DIR/ddpar_test.img -j 4
```

---

## 4. Remote Tests – SSH + Netcat

> **Voraussetzung:** SSH-Zugang zu `$REMOTE_HOST` muss eingerichtet sein
> (passwortlos per Key oder interaktiv per Passwort).
> `nc` (netcat) und `ss` müssen auf dem Remote-Host verfügbar sein.

### 4.1 Remote Clone – Block Device, unkomprimiert (Modus n)

Modus `n`: SSH-Verbindungsaufbau verschlüsselt, Dateiübertragung über Netcat unverschlüsselt.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r n -R $REMOTE_HOST
```

### 4.2 Remote Clone – Datei, unkomprimiert (Modus n)

> **Abweichung:** `-o` ist hier ein Verzeichnis auf dem Remote-Host.

```bash
./ddpar.sh -i $SOURCE_FILE -o $REMOTE_DEST_DIR -m clone -r n -R $REMOTE_HOST
```

### 4.3 Remote Clone – Block Device, vollständig verschlüsselt (Modus l)

Modus `l`: Gesamte Übertragung läuft durch den SSH-Tunnel.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r l -R $REMOTE_HOST
```

### 4.4 Remote Clone – Block Device, lokale Kompression (Modus n + -c)

Daten werden lokal mit gzip komprimiert, dann per Netcat übertragen und remote dekomprimiert.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r n -c -R $REMOTE_HOST
```

### 4.5 Remote Clone – Block Device, remote Kompression (Modus c)

Kompression findet auf der Remote-Seite statt.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r c -R $REMOTE_HOST
```

### 4.6 Remote Backup – Block Device, unkomprimiert (Modus n)

Die Split-Teile werden per Netcat zum `$REMOTE_HOST` übertragen und dort als
`*.part`-Dateien abgelegt. Die Übertragung ist unkomprimiert und ohne Prüfsumme
(`-c`/`-s` werden auf dem Remote-Pfad nicht angewendet).

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_BACKUP_DIR -m backup -r n -R $REMOTE_HOST
```

> **Voraussetzung:** `$REMOTE_BACKUP_DIR` muss auf dem Remote-Host als Verzeichnis
> existieren.
> Erzeugte Dateien auf dem Remote-Host: `$REMOTE_BACKUP_DIR/sdb-0.part` …
> `sdb-3.part` + `sdb-metadata.txt`.

### 4.7 Remote Backup – Datei, unkomprimiert (Modus n)

```bash
./ddpar.sh -i $SOURCE_FILE -o $REMOTE_BACKUP_DIR -m backup -r n -R $REMOTE_HOST
```

> Erzeugte Dateien auf dem Remote-Host:
> `$REMOTE_BACKUP_DIR/ddpar_test.img-0.part` … + `ddpar_test.img-metadata.txt`.

#### Test ohne echten Remote-Host (Fake-`ssh`-Stub)

Ist kein SSH-Server verfügbar, lässt sich der Remote-Backup-Codepfad mit einem
`ssh`-Stub im `PATH` validieren (prüft Befehlsaufbau und sequentielle Ports,
überträgt aber keine echten Daten):

```bash
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/ssh <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"-O check"*) exit 1;;   # kein bestehender Socket
  *"-O exit"*)  exit 0;;
esac
cmd="${@: -1}"
case "$cmd" in
  *"file -b"*)   echo "directory"; exit 0;;
  *"ss -tuln"*)  exit 0;;  # Verifikationsschleife: Prozess läuft
  *"ss -tln"*)   exit 1;;  # Portprüfung: Port frei
  *"nohup"*)     exit 0;;  # Empfänger-Start im Hintergrund
  *"command -v"*) exit 0;;
  *) exit 0;;
esac
STUB
chmod +x /tmp/fakebin/ssh

PATH="/tmp/fakebin:$PATH" ./ddpar.sh -i $SOURCE_FILE -o /tmp/ddpar_backup \
  -m backup -r n -R localhost -j 4 -b 1048576
```

Erwartung: pro Teil eine Zeile `REMOTE COMMAND: nc -N -l <PORT> | dd of=…-N.part`
mit aufsteigenden Ports sowie lokal `dd if=… | nc localhost <PORT> &`.

### 4.8 Remote Restore – Block Device, unkomprimiert (Modus n)

Die Backup-Teile liegen auf dem `$REMOTE_HOST`; das Zielgerät `-o` ist **lokal**.
Der Remote-Host sendet die Teile per Netcat, lokal werden sie empfangen und
geschrieben. Nur unkomprimiert (komprimierte Backups werden remote abgelehnt).
Der `-i`-Basispfad ist der Pfad **auf dem Remote-Host** ohne abschließendes `-`.

```bash
sudo ./ddpar-restore.sh -i $REMOTE_BACKUP_DIR/sdb -o $DEST_DEV -r n -R $REMOTE_HOST
```

> **Voraussetzung:** Ein vorher erstelltes Remote-Backup aus Test 4.6.
> Die Metadaten werden automatisch vom `$REMOTE_HOST` gelesen.

### 4.9 Remote Restore – Datei, unkomprimiert (Modus n)

```bash
./ddpar-restore.sh -i $REMOTE_BACKUP_DIR/ddpar_test.img -o $DEST_DIR/ddpar_test.img -r n -R $REMOTE_HOST
```

> **Voraussetzung:** Ein vorher erstelltes Remote-Backup aus Test 4.7.

#### Test ohne echten Remote-Host (Fake-`ssh`-Stub)

Wie bei Test 4.6/4.7 lässt sich auch der Remote-Restore-Codepfad ohne SSH-Server
mit einem `ssh`-Stub im `PATH` validieren. Der Stub muss zusätzlich beim
`cat …metadata.txt` gültige Metadaten liefern:

```bash
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/ssh <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"-O check"*) exit 1;;
  *"-O exit"*)  exit 0;;
esac
cmd="${@: -1}"
case "$cmd" in
  *metadata.txt*)
    printf 'NUM_JOBS=4\nFILE_NAME=in.img\nBLOCKSIZEBYTES=1048576\nINPUT_SIZE=4194304\nINPUT_FILE_NAME=in.img\nFILE_TYPE=data\nSPLIT_SIZE=1048576\n'
    exit 0;;
  *"ss -tuln"*) exit 0;;   # Sender-Listener läuft
  *"ss -tln"*)  exit 1;;   # Port frei
  *"nohup"*)    exit 0;;   # Remote-Sender im Hintergrund
  *true)        exit 0;;
  *) exit 0;;
esac
STUB
chmod +x /tmp/fakebin/ssh

echo "y" | PATH="/tmp/fakebin:$PATH" ./ddpar-restore.sh \
  -i /tmp/ddpar_backup/in.img -o /tmp/restore_out.img -r n -R localhost
```

Erwartung: pro Teil `REMOTE COMMAND: dd if=…-N.part … | nc -N -l <PORT>` (Remote
sendet) und lokal `nc localhost <PORT> | dd of=… seek=N count=1` mit aufsteigenden
Ports und Offsets.

### 4.10 Remote Check – Quelle gegen Remote-Backup (Source ↔ Backup)

> **Hinweis:** Der Remote-Check überträgt **keine** Nutzdaten über netcat – die
> SHA256-Hashes werden je Segment lokal bzw. per SSH auf dem Remote-Host berechnet
> und nur verglichen. Nur unkomprimierte Remote-Backups werden unterstützt; die
> `-b`-Seite liegt auf dem Remote-Host.

```bash
./ddpar-check.sh -s $SOURCE_FILE -b $REMOTE_BACKUP_DIR/ddpar_test.img -r n -R $REMOTE_HOST
```

> **Voraussetzung:** Remote-Backup aus Test 4.6/4.7.
> Erwartung: `Segment N: OK (<hash>)` pro Segment, sonst `MISMATCH`.

### 4.11 Remote Check – Remote-Backup gegen lokales Ziel (Backup ↔ Destination)

```bash
sudo ./ddpar-check.sh -b $REMOTE_BACKUP_DIR/sdb -d $DEST_DEV -r n -R $REMOTE_HOST
```

> **Voraussetzung:** Lokaler Remote-Restore aus Test 4.8 nach `$DEST_DEV`.

### 4.12 Remote Check – Clone (Source ↔ Remote-Destination)

Für einen Remote-Clone (Test 4.1/4.2): das geklonte Ziel liegt auf dem Remote-Host.

```bash
sudo ./ddpar-check.sh -s $SOURCE_DEV -d $REMOTE_DEST_DEV -r n -R $REMOTE_HOST -j 4 -B 1048576
```

> **Abweichung:** Ohne `-b` gibt es keine Metadaten; `-j`/`-B` müssen zum
> ursprünglichen Clone-Aufruf passen.

#### Test ohne echten Remote-Host (Fake-`ssh`-Stub)

Da der Check nur Hashes vergleicht, kann ein `ssh`-Stub das Remote-Kommando lokal
ausführen (Remote == localhost), wodurch echte Hashes über reale Dateien berechnet
werden:

```bash
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/ssh <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"-O check"*) exit 1;;
  *"-O exit"*)  exit 0;;
esac
cmd="${@: -1}"   # Remote-Kommando lokal ausführen
bash -c "$cmd"
STUB
chmod +x /tmp/fakebin/ssh

# Backup-Check gegen ein lokal erzeugtes "Remote"-Backup
PATH="/tmp/fakebin:$PATH" ./ddpar-check.sh \
  -s /tmp/ddpartest/in.img -b /tmp/ddpar_backup/in.img -r n -R localhost
```

---

## 5. Zusatzoptionen

Die folgenden Optionen können mit den meisten Szenarien oben kombiniert werden.

### 5.1 Checksummen aktivieren (-s)

Beim Backup wird pro Teil eine SHA256-Checksumme erstellt:

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -s
```

### 5.2 Anzahl der Jobs anpassen (-j)

> Die Eingabegröße muss nicht durch die Anzahl der Jobs teilbar sein — ein
> Rest wird vom letzten Teil übertragen.

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -j 2
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -j 8
```

### 5.3 Blockgröße anpassen (-b)

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -b 4194304
```

### 5.4 Debug-Modus (-d)

> **Achtung:** Im Debug-Modus werden Passwörter im Klartext ausgegeben.

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -d
```

### 5.5 Force-Modus (-f)

Überschreibt vorhandene Dateien oder ignoriert Speicherplatz-Warnungen:

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -f
```
